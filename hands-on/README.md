# ClickHouse + AWS Workshop — Hands-on

> **Workshop:** [top-level README](../README.md) · **also in this folder:** [Terraform](terraform/README.md) · [Generators & migrations](mock_data/README.md) · [Generator EC2](EC2_GENERATOR.md) · [Agentic stack](agentic-data-stack/README.md) · [Langfuse](langfuse/README.md)

End-to-end lab environment for the ClickHouse + AWS workshop. You provision a
**ClickHouse Cloud** service with Terraform, ingest from **Aurora PostgreSQL
(CDC)** and **Amazon Kinesis** via **ClickPipes**, build an **Incremental
Materialized View + AggregatingMergeTree**, and finish on the **Agentic Data
Stack** observed with **Langfuse**.

> The morning slides introduce each concept; this folder is where you do it.
> See **"How each lab maps to the deck"** below.

## Architecture

```text
                    AWS                                  ClickHouse Cloud
   ┌─────────────────────────────────┐         ┌──────────────────────────────────┐
   │  Aurora PostgreSQL (OLTP)        │         │  raw.customers  raw.orders        │
   │   customers / orders   ──CDC──▶  │ ClickPipe (Postgres CDC) │ (ReplacingMergeTree)│
   │                                  │         │                                   │
   │  Amazon Kinesis (clickstream) ─▶ │ ClickPipe (Kinesis)      │  raw.events_raw   │
   └─────────────────────────────────┘         │        │  (MergeTree, append)     │
                                                │        ▼                          │
                                                │  Incremental MV                   │
                                                │        ▼                          │
                                                │  marts.events_by_minute           │
                                                │   (AggregatingMergeTree)          │
                                                └──────────────────────────────────┘
                                                          │  SQL / MCP
                                                          ▼
                                        Agentic Data Stack (LibreChat + MCP) → Langfuse
```

## Repo layout

`hands-on/` is the **uv project root** — one `pyproject.toml` and `.venv` cover
every Python script in the repo.

```text
hands-on/
├── pyproject.toml        # the uv project (all Python deps for the repo)
├── .python-version       # pinned Python for uv
├── .env.example          # copy to .env; read by every script
├── EC2_GENERATOR.md      # optional in-VPC EC2 that self-runs the generators
├── terraform/            # ClickHouse Cloud + Aurora + Kinesis + ClickPipes + PrivateLink + (optional) generator EC2
├── sql/
│   ├── aurora/                    # PostgreSQL migrations (run by mock_data/run_migrations.py)
│   │   ├── 01_setup.sql           #   schema, clickpipes_user, publication
│   │   └── global-bundle.pem      #   AWS RDS CA bundle (gitignored — download it, see Setup)
│   └── clickhouse/                # run in the ClickHouse SQL console
│       ├── 01_materialized_views.sql  # incremental MV + AggregatingMergeTree
│       └── 02_demo_queries.sql        # demo queries (streaming + CDC + unified join)
├── mock_data/            # Python scripts: run_migrations.py, seed_rds.py, simulate_cdc.py, kinesis_producer.py, run_generators.py
├── scripts/              # ec2_bootstrap.sh (runs on the EC2), generator_ec2.sh (start/stop the EC2 from your laptop)
├── agentic-data-stack/   # Lab 4: run the agentic stack, observe it
└── langfuse/             # Lab 5 (afternoon): Langfuse workshop pointer
```

## Prerequisites

- **Terraform** >= 1.11 (write-only args)
- **AWS account** + credentials (`AWS_PROFILE` or access keys)
- **ClickHouse Cloud** organization + an **API key** (Organization → API keys)
- **uv** for the Python generators and the Aurora migration runner

```bash
export CLICKHOUSE_ORG_ID="<org-uuid>"
export CLICKHOUSE_CLOUD_API_KEY="<key-id>"
export CLICKHOUSE_CLOUD_API_SECRET="<key-secret>"
export AWS_PROFILE="<your-profile>"   # or AWS_ACCESS_KEY_ID / AWS_SECRET_ACCESS_KEY
```

## Run order (the whole lab)

The Terraform applies in **two phases** so the ClickPipes are created only once
their sources exist and have data.

### Phase 1 — infrastructure
```bash
cd terraform
cp terraform.tfvars.example terraform.tfvars   # fill in passwords + region
terraform init
terraform apply        # enable_*_clickpipe stay false for now
terraform output       # grab aurora_writer_endpoint, kinesis_stream_name, etc.
```

### Phase 2a — bootstrap Aurora + seed data
```bash
cd ..                          # hands-on/ — the uv project root
cp .env.example .env           # fill from `terraform output`
uv sync                        # one venv for all the Python scripts

# Download the AWS RDS CA bundle (gitignored — needed for the default
# PGSSLMODE=verify-full TLS to Aurora). One-time, per clone:
curl -fsSL https://truststore.pki.rds.amazonaws.com/global/global-bundle.pem \
  -o sql/aurora/global-bundle.pem

# Bootstrap schema, role, and publication on Aurora (runs sql/aurora/*.sql)
uv run mock_data/run_migrations.py

# Seed, then start live traffic for BOTH pipes in one terminal (Ctrl-C stops both)
uv run mock_data/seed_rds.py
uv run mock_data/run_generators.py                # CDC + Kinesis, runs until stopped
```

> Prefer separate terminals? Run `uv run mock_data/simulate_cdc.py` and
> `uv run mock_data/kinesis_producer.py` individually instead.

**Don't want to run generators from your laptop?** Set `enable_generator_ec2 = true`
and `repo_url` in `terraform.tfvars`, then `terraform apply`. An in-VPC EC2 clones
the repo, runs the migrations + seed, and runs the generators as a systemd service —
reaching Aurora over its **private** IP (no laptop network, no IP allowlisting).
See **[EC2_GENERATOR.md](EC2_GENERATOR.md)**. Stop/start it between demos to save
cost with `scripts/generator_ec2.sh {stop|start|status}`.

### Phase 2b — create the ClickPipes
```bash
cd ../terraform
# set enable_postgres_clickpipe = true and enable_kinesis_clickpipe = true
terraform apply
```

### Phase 3 — model + query in ClickHouse
```bash
# In the ClickHouse Cloud SQL console:
#   run sql/clickhouse/01_materialized_views.sql   (incremental MV + AggregatingMergeTree)
#   run sql/clickhouse/02_demo_queries.sql         (streaming, CDC, and the unified join)
```

### Phase 4 — agentic + observability
- `agentic-data-stack/README.md` — run LibreChat + MCP over your service.
- `langfuse/README.md` — the afternoon Langfuse workshop.

## How each lab maps to the deck

| Deck section (morning) | Hands-on artefact |
|------------------------|-------------------|
| ClickHouse Cloud → **Data ingestion** (Flink / S3 / **ClickPipes**) | `terraform/clickpipes.tf`, `terraform/aurora.tf`, `terraform/kinesis.tf` |
| **Compute-storage / compute-compute separation** | `terraform/clickhouse.tf` (autoscaling envelope); discuss warehouses while queries run |
| **BigQuery (migrations)** | Slides + `docs note`: BigQuery snapshot ClickPipe / GCS-Parquet path (no lab infra) |
| Hands-on: **Ingesting from RDS and Kinesis** | Phases 1–2 above |
| Hands-on: **Incremental MV + AggregatingMergeTree** | `sql/clickhouse/01_materialized_views.sql`, `sql/clickhouse/02_demo_queries.sql` |
| Hands-on: **Agentic Data Stack (and how to observe it)** | `agentic-data-stack/` |
| Afternoon: **Langfuse — Observability / Prompts / Experiments** | `langfuse/` |

## Teardown

```bash
cd terraform
terraform destroy
```
Stops both ClickPipes, the ClickHouse service, the Aurora cluster, and the
Kinesis stream. (Stop the Python producers first.)

## Cost & safety notes

- The default `ip_access_list` opens the ClickHouse endpoint to `0.0.0.0/0` for a
  throwaway workshop — **tighten it** for anything beyond the lab.
- **ClickPipes reaches Aurora privately over AWS PrivateLink** (`terraform/privatelink.tf`),
  so ClickPipes static NAT IPs are **not** needed. `clickpipes_ingress_cidrs` only
  needs your laptop `/32` if you seed Aurora from your laptop over its public endpoint.
- Aurora is `publicly_accessible = true` only so laptop seeding works; the in-VPC
  generator EC2 avoids that entirely (private IP). TLS to Aurora defaults to
  `verify-full` against the RDS CA bundle.
- The optional generator EC2 runs ~24/7 — **stop it between demos** with
  `scripts/generator_ec2.sh stop` (you keep only the small EBS charge).
- Run `terraform destroy` at the end of the day to avoid lingering charges.
