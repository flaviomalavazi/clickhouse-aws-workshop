# Mock data + Aurora migrations

A small uv project: one migration runner plus three data generators.

| Script | Target | What it does |
|--------|--------|--------------|
| `run_migrations.py` | Aurora PostgreSQL | Runs the `../sql/aurora/*.sql` migrations (schema, `clickpipes_user`, publication). |
| `seed_rds.py` | Aurora PostgreSQL | One-off bulk insert of customers + orders (the CDC initial snapshot). |
| `simulate_cdc.py` | Aurora PostgreSQL | Continuous INSERT / UPDATE / DELETE so the Postgres ClickPipe has live CDC traffic. |
| `kinesis_producer.py` | Amazon Kinesis | Continuous append-only clickstream events as JSON. |
| `run_generators.py` | both of the above | Runs `simulate_cdc.py` + `kinesis_producer.py` together until Ctrl-C (one terminal). |

These scripts belong to the single uv project rooted at `hands-on/`
(`hands-on/pyproject.toml`) — there is no separate project in this folder.

## Setup

```bash
cd hands-on                     # the uv project root
cp .env.example .env            # then fill in values from `terraform output`
uv sync                         # creates the venv from pyproject.toml

# The AWS RDS CA bundle is gitignored — download it once per clone so the
# default PGSSLMODE=verify-full TLS to Aurora can validate the server cert:
curl -fsSL https://truststore.pki.rds.amazonaws.com/global/global-bundle.pem \
  -o sql/aurora/global-bundle.pem
```

> Don't want to download it? Set `PGSSLMODE=require` in `.env` to encrypt without
> certificate verification (less secure).

## Run

```bash
# 1) run the Aurora migrations (schema, clickpipes_user, publication)
uv run mock_data/run_migrations.py        # add --dry-run to test connectivity only

# 2) initial load into Aurora (before creating the Postgres ClickPipe)
uv run mock_data/seed_rds.py

# 3) live traffic for both pipes in ONE terminal (Ctrl-C stops both)
uv run mock_data/run_generators.py
#    ...or tune the rates:
uv run mock_data/run_generators.py --cdc-sleep 1.0 --kinesis-rate 20

#    ...or run them separately in their own terminals instead:
uv run mock_data/simulate_cdc.py --sleep 1.0       # live CDC traffic
uv run mock_data/kinesis_producer.py --rate 20     # live Kinesis events
```

`uv run` discovers the project by walking up, so the same commands also work
from inside `mock_data/` (drop the `mock_data/` prefix).

`run_migrations.py` substitutes `__CLICKPIPES_USER_PASSWORD__` in the SQL with
`CLICKPIPES_USER_PASSWORD` from your `.env`.

`config.py` reads everything from environment variables / `.env`. AWS credentials
for `kinesis_producer.py` come from your usual `AWS_PROFILE` or access keys.

## Resilience (built for flaky networks / long demos)

- **Preflight + auto-reconnect**: `simulate_cdc.py` waits (with exponential backoff)
  until Aurora is reachable, and if the connection drops mid-run it reconnects and
  resumes instead of crashing. Real SQL/programming errors still surface loudly.
- `kinesis_producer.py` skips a batch and retries on a transient AWS/network error
  rather than exiting.
- `run_generators.py` shuts both children down cleanly on Ctrl-C, and if one exits
  on its own it stops the other (so a half-running demo fails loudly).
- TLS to Aurora defaults to `PGSSLMODE=verify-full` against `sql/aurora/global-bundle.pem`
  (the public endpoint's cert is validated); set `PGSSLMODE=require` to skip verification.
