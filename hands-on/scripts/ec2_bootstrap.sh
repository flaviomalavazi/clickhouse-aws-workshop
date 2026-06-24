#!/bin/bash
# ec2_bootstrap.sh — runs on the generator EC2 (invoked by user_data as root).
#
# Idempotent: install uv -> uv sync -> fetch DB secrets (SSM or Secrets Manager,
# selected by SECRETS_SOURCE) -> apply Aurora migrations -> seed once -> install
# & start the always-on generators service.
#
# Secrets handling: the DB passwords (which may contain '$') are kept as shell
# variables and passed to the Python scripts as REAL environment variables. We do
# NOT write a .env file — python-dotenv would try to interpolate '$...' in values.
# config.py reads os.getenv() directly, and load_dotenv() does not override real
# env vars, so plain environment variables are the safe path.
set -euxo pipefail

# Non-secret config from user_data (REPO_URL, AWS_REGION, PG_HOST, ... — no '$').
set -a
# shellcheck disable=SC1091
. /etc/ch-workshop.env
set +a

HANDS_ON="$CLONE_DIR/hands-on"

# 1. Install uv to a stable system path so the systemd unit can reference it.
if [ ! -x /usr/local/bin/uv ]; then
  curl -LsSf https://astral.sh/uv/install.sh | env UV_INSTALL_DIR=/usr/local/bin sh
fi
export PATH="/usr/local/bin:$PATH"
export HOME=/root

cd "$HANDS_ON"

# 2. Create the venv + install deps (pins Python via .python-version; gives us boto3).
uv sync

# 3. Read the two DB passwords via the venv's boto3 (uses the instance role).
#    SECRETS_SOURCE selects the backend so the SAME bootstrap serves both deploy
#    paths:
#      - Terraform      -> SSM Parameter Store SecureString  (default; var unset)
#      - CloudFormation -> AWS Secrets Manager (SECRETS_SOURCE=secretsmanager),
#                          because CFN cannot create SSM SecureString parameters.
#    The SSM_PG_PASSWORD / SSM_CLICKPIPES_PASSWORD values are the identifiers: an
#    SSM parameter NAME for ssm, or a secret ID/ARN for secretsmanager.
#    Command substitution keeps the value literal — no re-expansion.
SECRETS_SOURCE="${SECRETS_SOURCE:-ssm}"
read_secret() {
  uv run python - "$SECRETS_SOURCE" "$1" <<'PY'
import os, sys, boto3
source, ident = sys.argv[1], sys.argv[2]
region = os.environ["AWS_REGION"]
if source == "secretsmanager":
    sm = boto3.client("secretsmanager", region_name=region)
    print(sm.get_secret_value(SecretId=ident)["SecretString"], end="")
elif source == "ssm":
    ssm = boto3.client("ssm", region_name=region)
    print(ssm.get_parameter(Name=ident, WithDecryption=True)["Parameter"]["Value"], end="")
else:
    sys.exit(f"Unknown SECRETS_SOURCE={source!r} (expected 'ssm' or 'secretsmanager')")
PY
}
PG_PASSWORD="$(read_secret "$SSM_PG_PASSWORD")"
CLICKPIPES_PASSWORD="$(read_secret "$SSM_CLICKPIPES_PASSWORD")"

# 4. Export the connection env. Double-quoting a variable does NOT re-expand '$'
#    inside its value, so passwords with '$' survive intact.
export PGHOST="$PG_HOST" PGPORT=5432 PGDATABASE="$PG_DATABASE" PGUSER="$PG_USER"
export PGPASSWORD="$PG_PASSWORD" CLICKPIPES_USER_PASSWORD="$CLICKPIPES_PASSWORD"
export PGSSLMODE=verify-full
# AWS_REGION and KINESIS_STREAM_NAME were exported from /etc/ch-workshop.env above.

# 4b. Download the AWS RDS CA bundle — it's gitignored, so it's not in the clone.
#     config.py expects it here for the default PGSSLMODE=verify-full TLS to Aurora.
curl -fsSL https://truststore.pki.rds.amazonaws.com/global/global-bundle.pem \
  -o "$HANDS_ON/sql/aurora/global-bundle.pem"

# 5. Apply Aurora migrations (idempotent SQL).
uv run mock_data/run_migrations.py

# 6. Seed once — guarded so a re-run / restart doesn't double-insert.
if [ ! -f "$CLONE_DIR/.seeded" ]; then
  uv run mock_data/seed_rds.py
  touch "$CLONE_DIR/.seeded"
fi

# 7. Runtime EnvironmentFile for the service. printf writes values literally, and
#    systemd reads EnvironmentFile values literally too (no '$' interpolation),
#    so secrets are safe here as well. Root-only.
umask 077
{
  printf 'PGHOST=%s\n' "$PG_HOST"
  printf 'PGPORT=5432\n'
  printf 'PGDATABASE=%s\n' "$PG_DATABASE"
  printf 'PGUSER=%s\n' "$PG_USER"
  printf 'PGPASSWORD=%s\n' "$PG_PASSWORD"
  printf 'CLICKPIPES_USER_PASSWORD=%s\n' "$CLICKPIPES_PASSWORD"
  printf 'PGSSLMODE=verify-full\n'
  printf 'AWS_REGION=%s\n' "$AWS_REGION"
  printf 'KINESIS_STREAM_NAME=%s\n' "$KINESIS_STREAM_NAME"
} > /etc/ch-workshop-runtime.env
umask 022

# 8. Install + (re)start the always-on generators service. CDC_SLEEP/KINESIS_RATE
#    are baked in as literals (no '$' in ExecStart).
cat > /etc/systemd/system/ch-generators.service <<UNIT
[Unit]
Description=ClickHouse workshop data generators (Postgres CDC + Kinesis)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
# PYTHONUNBUFFERED so the generators' stdout streams to journald in real time
# (otherwise Python block-buffers stdout when it's not a TTY and logs look "stuck").
Environment=HOME=/root PYTHONUNBUFFERED=1
EnvironmentFile=/etc/ch-workshop-runtime.env
WorkingDirectory=$HANDS_ON
ExecStart=/usr/local/bin/uv run mock_data/run_generators.py --cdc-sleep $CDC_SLEEP --kinesis-rate $KINESIS_RATE
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
UNIT

systemctl daemon-reload
systemctl enable --now ch-generators.service

echo "Bootstrap complete — generators running under systemd (ch-generators.service)."
