# In-VPC data-generator EC2

> [← Hands-on guide](README.md) · [Workshop README](../README.md) · defined in [terraform/ec2.tf](terraform/ec2.tf)

An optional EC2 instance that runs the workshop's data generators **from inside the
Aurora VPC**, so you don't depend on your laptop's network or allowlist a rotating
public IP.

## Why

Running the generators from a laptop has two recurring problems:

- The laptop's public IP rotates, so `clickpipes_ingress_cidrs` needs constant edits.
- Many networks intermittently block/throttle outbound `5432`, so the CDC generator
  times out mid-demo.

From inside the VPC, Aurora's **writer endpoint resolves to its private IP**, which is
already allowed by the `aurora_ingress_vpc` security-group rule (VPC CIDR on 5432).
Kinesis is reached through the instance's IAM role. No public-IP allowlisting, no flaky
home network.

```text
            ┌─────────────────────── your AWS account / VPC ───────────────────────┐
            │                                                                       │
  laptop ✗  │   EC2 "generator"  ──(private IP, 5432, TLS verify-full)──▶  Aurora   │
 (flaky)    │     │                                                                 │
            │     └──(IAM role, HTTPS)──▶  Kinesis stream                           │
            │     ▲                                                                 │
            └─────┼─────────────────────────────────────────────────────────────────┘
                  │
        you ──────┘  AWS Systems Manager Session Manager  (no SSH key, no open port)
```

## What it is (Terraform)

Defined in [terraform/ec2.tf](terraform/ec2.tf), gated behind `enable_generator_ec2`
(default `false`). When enabled it creates:

- An **EC2 instance** (`${name_prefix}-generator`, Amazon Linux 2023, `t3.small` by
  default) in the Aurora VPC, in a public subnet with a public IP for outbound only.
- An **egress-only security group** — no inbound ports at all (Session Manager needs none).
- An **IAM role / instance profile** with:
  - `AmazonSSMManagedInstanceCore` (Session Manager access),
  - `kinesis:PutRecords` (+ describe/list) on the workshop stream,
  - read access to two **SSM SecureString** parameters holding the DB passwords.
- Two **SSM Parameter Store SecureStrings**: `/${name_prefix}/aurora_master_password`
  and `/${name_prefix}/clickpipes_user_password`.

## What happens at boot

1. **cloud-init** runs [terraform/templates/ec2_user_data.sh.tftpl](terraform/templates/ec2_user_data.sh.tftpl):
   writes non-secret config to `/etc/ch-workshop.env`, installs `git`, clones the repo to
   `/opt/ch-workshop`, and hands off to the bootstrap script.
2. **[scripts/ec2_bootstrap.sh](scripts/ec2_bootstrap.sh)** (as root):
   1. installs `uv` to `/usr/local/bin`;
   2. `uv sync` in `/opt/ch-workshop/hands-on`;
   3. reads the two passwords from SSM (via the instance role);
   4. downloads the AWS RDS CA bundle to `sql/aurora/global-bundle.pem` (it's
      gitignored, so not in the clone) for the default `verify-full` TLS;
   5. applies the Aurora migrations (`mock_data/run_migrations.py`);
   6. seeds Aurora once (`mock_data/seed_rds.py`), guarded by `/opt/ch-workshop/.seeded`;
   7. installs and starts a systemd service, **`ch-generators.service`**, that runs
      `mock_data/run_generators.py` (Postgres CDC + Kinesis) continuously with
      `Restart=always`.

Secrets are passed to the scripts as real environment variables (and to the service via
a root-only `EnvironmentFile`), never written to a `.env` — so DB passwords containing
`$` are handled correctly.

## Connecting (Session Manager — no SSH key, no open port)

Prerequisites on your machine: the AWS CLI and the
[Session Manager plugin](https://docs.aws.amazon.com/systems-manager/latest/userguide/session-manager-working-with-install-plugin.html).

```bash
cd hands-on/terraform

# Convenience: Terraform prints the exact command.
eval "$(terraform output -raw generator_ec2_ssm_command)"

# ...or by hand (use your aws_region, default us-east-1):
aws ssm start-session \
  --target "$(terraform output -raw generator_ec2_instance_id)" \
  --region us-east-1
```

You land in a shell on the instance (as `ssm-user`; use `sudo -i` for root).

> Prefer real SSH? You can tunnel SSH over SSM with an `AWS-StartSSHSession` document,
> but it's not required to inspect anything below.

## Checking that the generators are running

```bash
sudo -i

# Service health + recent logs
systemctl status ch-generators
journalctl -u ch-generators -f          # live: "NN mutations applied" / "sent NN events"

# First-boot / bootstrap output (clone, uv sync, migrations, seed)
cat /var/log/cloud-init-output.log

# Where things live
ls "/opt/ch-workshop/hands-on"
cat /etc/ch-workshop.env                 # non-secret config
```

Verify data is actually flowing:

```bash
cd "/opt/ch-workshop/hands-on"
# Connectivity + row counts (uses the same env as the service)
sudo env $(grep -v '^#' /etc/ch-workshop-runtime.env | xargs) /usr/local/bin/uv run \
  python -c "import db; c=db.connect_with_retry(); print(c.execute('select count(*) from orders').fetchone())"
```

Kinesis side: check the stream's `IncomingRecords` metric in CloudWatch, or the
ClickHouse `raw.*` tables once the ClickPipes are enabled.

## Managing the service

```bash
sudo systemctl restart ch-generators     # restart the generators
sudo systemctl stop ch-generators        # pause data generation
sudo systemctl disable --now ch-generators

# Re-run the whole bootstrap (migrations are idempotent; seeding is skipped if
# /opt/ch-workshop/.seeded exists — delete it to force a re-seed):
sudo bash "/opt/ch-workshop/hands-on/scripts/ec2_bootstrap.sh"
```

## Troubleshooting

| Symptom | Likely cause / fix |
|---|---|
| cloud-init log shows a clone error | `repo_url`/`repo_branch` wrong, or repo not public. Fix the var and `terraform apply` (the instance is replaced). |
| `AccessDenied` reading SSM params | The role's `kms:Decrypt` on `alias/aws/ssm` or `ssm:GetParameter` is missing — re-apply. |
| Migrations/seed time out | Aurora not reachable. Confirm `aurora_ingress_vpc` allows the VPC CIDR on 5432 and the EC2 is in the same VPC. |
| `ch-generators` crash-looping | `journalctl -u ch-generators -e`. The generators self-reconnect on blips; systemd restarts on hard exits. A `SyntaxError`/auth error is a real bug, not a network blip. |

## Teardown / cost

The instance runs ~24/7 (a `t3.small`). Between demos, **stop** it instead of
destroying — you keep only the small EBS charge, and on start the generators
auto-resume (the service is `enabled`):

```bash
hands-on/scripts/generator_ec2.sh stop      # power off to save cost
hands-on/scripts/generator_ec2.sh start     # power on + resume generators
hands-on/scripts/generator_ec2.sh status    # instance + service status
```

(The script reads the instance id/region from `terraform output`; override with
`INSTANCE_ID`/`AWS_REGION` env vars.)

To remove everything, set `enable_generator_ec2 = false` and `terraform apply` —
the SSM SecureString parameters and IAM role are destroyed with it.

## Run order with the EC2

1. Apply base infra (Aurora, Kinesis, PrivateLink) with the pipe toggles `false`.
2. Set `enable_generator_ec2 = true` and `repo_url = "<public git url>"` → `terraform apply`.
   The EC2 migrates, seeds, and starts generating. (Laptop seeding is no longer needed;
   `clickpipes_ingress_cidrs` becomes optional.)
3. Set `enable_postgres_clickpipe = true` and `enable_kinesis_clickpipe = true` →
   `terraform apply` to create the pipes against the now-live data.
