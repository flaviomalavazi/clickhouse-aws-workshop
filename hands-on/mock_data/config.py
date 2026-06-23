"""Shared configuration, loaded from environment variables (.env supported).

Copy ../.env.example to ../.env and fill in the values, or export them in your
shell. terraform outputs give you the endpoints/names you need.
"""
from __future__ import annotations

import os

from dotenv import load_dotenv

# Load ../.env (repo root) then ./.env if present.
load_dotenv(dotenv_path=os.path.join(os.path.dirname(__file__), "..", ".env"))
load_dotenv()


def _require(name: str) -> str:
    val = os.getenv(name)
    if not val:
        raise SystemExit(
            f"Missing required env var {name!r}. "
            f"Set it in ../.env (see ../.env.example) or export it."
        )
    return val


# --- Aurora PostgreSQL (target of seed_rds.py / simulate_cdc.py) ---
PG_HOST = os.getenv("PGHOST", "")
PG_PORT = int(os.getenv("PGPORT", "5432"))
PG_DB = os.getenv("PGDATABASE", "appdb")
PG_USER = os.getenv("PGUSER", "postgres")
PG_PASSWORD = os.getenv("PGPASSWORD", "")

# Password for the dedicated clickpipes_user role created by run_migrations.py
# (must match var.clickpipes_user_password in terraform.tfvars).
CLICKPIPES_USER_PASSWORD = os.getenv("CLICKPIPES_USER_PASSWORD", "")

# TLS: the seed/migration scripts hit the PUBLIC Aurora endpoint, so we verify
# the server certificate by default (verify-full = CA + hostname check) against
# the AWS RDS CA bundle shipped in sql/aurora/. Override with PGSSLMODE (e.g.
# "require" to encrypt without verifying) or PGSSLROOTCERT (custom CA path).
# Note: ClickPipes does NOT use this — it reaches Aurora over PrivateLink.
PG_SSLMODE = os.getenv("PGSSLMODE", "verify-full")
_DEFAULT_CA = os.path.join(os.path.dirname(__file__), "..", "sql", "aurora", "global-bundle.pem")
PG_SSLROOTCERT = os.getenv("PGSSLROOTCERT") or (_DEFAULT_CA if os.path.exists(_DEFAULT_CA) else "")


def pg_conninfo() -> str:
    from psycopg.conninfo import make_conninfo

    host = PG_HOST or _require("PGHOST")
    pw = PG_PASSWORD or _require("PGPASSWORD")

    params: dict[str, object] = {
        "host": host,
        "port": PG_PORT,
        "dbname": PG_DB,
        "user": PG_USER,
        "password": pw,
        "sslmode": PG_SSLMODE,
    }
    if PG_SSLMODE.startswith("verify-") and not PG_SSLROOTCERT:
        raise SystemExit(
            f"PGSSLMODE={PG_SSLMODE} needs a CA bundle, but none was found. "
            "Expected sql/aurora/global-bundle.pem, or set PGSSLROOTCERT, "
            "or set PGSSLMODE=require to skip certificate verification."
        )
    if PG_SSLROOTCERT:
        # abspath resolves the leading '..'; make_conninfo handles quoting/escaping
        # the path safely (e.g. if it ever contains spaces).
        params["sslrootcert"] = os.path.abspath(PG_SSLROOTCERT)

    return make_conninfo(**params)


# --- Amazon Kinesis (target of kinesis_producer.py) ---
AWS_REGION = os.getenv("AWS_REGION", "us-east-1")
KINESIS_STREAM_NAME = os.getenv("KINESIS_STREAM_NAME", "ch-aws-workshop-events")

# --- Generator knobs ---
SEED_CUSTOMERS = int(os.getenv("SEED_CUSTOMERS", "500"))
SEED_ORDERS = int(os.getenv("SEED_ORDERS", "2000"))
