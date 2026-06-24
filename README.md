# ClickHouse × AWS — Technical Workshop

Materials for the workshop with the AWS Solutions Architecture team: the theory
(deck) and the hands-on lab, designed to interleave.

## What's inside

| Piece | What it is |
|-------|------------|
| `deck/` | Theory deck (33 slides): the technology, ClickHouse Cloud, AWS integrations, ClickStack, and Langfuse/LLMOps. (Slides are a `.pptx`, gitignored.) |
| `hands-on/` | The practical project: Terraform (ClickHouse Cloud + Aurora CDC + Kinesis + ClickPipes, with **AWS PrivateLink** and an optional in-VPC **generator EC2**) — or a **CloudFormation** alternative for the AWS half — plus SQL (incremental MV + AggregatingMergeTree) and Python data generators. |

## Where to start — guides in this repo

**New here? Start with [`hands-on/README.md`](hands-on/README.md)** — it has the full
prerequisites, architecture, phased run order, and teardown. The other guides go
deeper on a specific piece:

| Guide | What it covers | Read it when… |
|-------|----------------|----------------|
| [hands-on/README.md](hands-on/README.md) | The whole lab end-to-end: prerequisites, architecture diagram, the two-phase `terraform apply`, modeling in ClickHouse, teardown. | …you're setting up the workshop or want the big picture. **Start here.** |
| [hands-on/terraform/README.md](hands-on/terraform/README.md) | The infrastructure (**source of truth**): ClickHouse Cloud service, Aurora (CDC source), Kinesis, both ClickPipes, **PrivateLink**, and the optional **generator EC2**. Providers, two-phase apply, gotchas. | …you're applying/editing Terraform or debugging the infra. |
| [hands-on/cloudformation/README.md](hands-on/cloudformation/README.md) | The **no-Terraform** alternative: a CloudFormation template for the **AWS half** (Aurora + Kinesis + ClickPipes IAM role + optional generator EC2), using ClickPipes **static-IP allow-listing** instead of PrivateLink. ClickHouse service + ClickPipes created manually. | …you can't/won't use Terraform but want the AWS infra. |
| [hands-on/mock_data/README.md](hands-on/mock_data/README.md) | The Python project: the Aurora migration runner and the data generators (seed, live CDC, Kinesis), the combined `run_generators.py`, and resilience behavior. | …you're seeding/streaming data or tuning generation rates. |
| [hands-on/EC2_GENERATOR.md](hands-on/EC2_GENERATOR.md) | The optional in-VPC EC2 that self-bootstraps and runs the generators (reaching Aurora over its private IP). How to connect via SSM, check the service, and stop/start to save cost. | …you want the generators running without your laptop/network, or need to manage that instance. |
| [hands-on/agentic-data-stack/README.md](hands-on/agentic-data-stack/README.md) | The Agentic Data Stack lab — a chat UI over ClickHouse via MCP, with built-in LLM observability. | …you reach the agentic-stack lab. |
| [hands-on/langfuse/README.md](hands-on/langfuse/README.md) | The Langfuse observability / LLMOps lab (delivered from a dedicated repo). | …you reach the afternoon Langfuse session. |

## How the deck and hands-on interleave

| Deck section (morning) | Lab |
|------------------------|-----|
| ClickHouse Cloud → Ingestion (Flink · S3 · BigQuery · ClickPipes) | [`hands-on/terraform/clickpipes.tf`](hands-on/terraform/clickpipes.tf) (Aurora CDC + Kinesis) |
| Compute-storage / compute-compute separation | [`hands-on/terraform/clickhouse.tf`](hands-on/terraform/clickhouse.tf) |
| Hands-on: Ingesting from RDS and Kinesis | Lab 1 — `terraform/` + `sql/aurora/01_setup.sql` + `mock_data/` |
| Hands-on: Incremental MV + AggregatingMergeTree | Lab 2 — `sql/clickhouse/01_materialized_views.sql`, `sql/clickhouse/02_demo_queries.sql` |
| Hands-on: Agentic Data Stack (and how to observe it) | Lab 4 — [`hands-on/agentic-data-stack/`](hands-on/agentic-data-stack/) |
| Afternoon: Langfuse — Observability / Prompts / Experiments | [`hands-on/langfuse/`](hands-on/langfuse/) |

Head to [`hands-on/README.md`](hands-on/README.md) for the complete run order.
