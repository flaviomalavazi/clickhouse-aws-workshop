# Terraform — ClickHouse Cloud + AWS ingestion

> [← Hands-on guide](../README.md) · [Workshop README](../../README.md) · related: [Generator EC2](../EC2_GENERATOR.md)

Provisions, in one stack:

- `clickhouse.tf` — a **ClickHouse Cloud** service (`clickhouse_service`).
- `aurora.tf` — an **Aurora PostgreSQL** cluster with logical replication enabled
  (the CDC source).
- `kinesis.tf` — an **Amazon Kinesis** stream + the IAM role ClickPipes assumes.
- `clickpipes.tf` — the two **ClickPipes** (`clickhouse_clickpipe`): Postgres CDC
  and Kinesis. Both are gated behind `enable_*_clickpipe` flags.
- `privatelink.tf` — **AWS PrivateLink** path for the Postgres pipe: an internal
  NLB + VPC endpoint service in front of Aurora, plus the ClickPipes
  `clickhouse_clickpipes_reverse_private_endpoint`. ClickPipes reaches Aurora
  privately instead of over the public internet.
- `ec2.tf` — **optional in-VPC generator EC2** (gated by `enable_generator_ec2`):
  self-bootstraps (clone repo → migrate → seed → run generators as a systemd
  service), connects to Aurora over its private IP, writes to Kinesis via an
  instance role, and is reachable by SSM Session Manager (no SSH/keys). DB
  passwords are passed via SSM SecureString parameters. See `../EC2_GENERATOR.md`.

## Providers

| Provider | Version | Auth |
|----------|---------|------|
| `ClickHouse/clickhouse` | `>= 3.17.3, < 4.0` | `CLICKHOUSE_ORG_ID`, `CLICKHOUSE_CLOUD_API_KEY`, `CLICKHOUSE_CLOUD_API_SECRET` |
| `hashicorp/aws` | `~> 6.51` | `AWS_PROFILE` / access keys |

The `clickhouse_clickpipe` resource (Postgres CDC + Kinesis sources) is GA from
provider **3.14+**.

## Two-phase apply

1. `enable_postgres_clickpipe = false`, `enable_kinesis_clickpipe = false` →
   `terraform apply` to create the service, Aurora, Kinesis, and IAM.
2. Bootstrap Aurora (`cd ../mock_data && uv run run_migrations.py`, which runs
   `../sql/aurora/*.sql`) and start the producers.
3. Flip both flags to `true` → `terraform apply` to create the pipes.

Why: the Postgres pipe needs the `clickpipes_pub` publication and
`clickpipes_user` to exist first; both pipes are happier when their sources are
already emitting data.

Step 2 can be done from your laptop **or** by the in-VPC generator EC2: set
`enable_generator_ec2 = true` and `repo_url = "<public git url>"`, apply, and it
runs the migrations, seed, and generators for you (`../EC2_GENERATOR.md`). Manage
it between demos with `../scripts/generator_ec2.sh {start|stop|status}`.

## Notes / gotchas

- **`tier` is omitted** on `clickhouse_service` (correct for new ClickHouse Cloud
  tiers). If your org is on legacy tiers, add `tier = "production"`.
- **Logical replication** (`rds.logical_replication = 1`) is a *static* Aurora
  parameter — the cluster reboots once when the parameter group is attached.
- **Postgres pipe uses PrivateLink** (`privatelink.tf`): an internal NLB fronts
  the Aurora writer's private IP, exposed via a VPC endpoint service that's
  allow-listed to the ClickPipes account (`var.clickpipes_account_id`,
  `072088201116`). The pipe connects to the reverse private endpoint's DNS name,
  so ClickPipes static NAT IPs are **not** needed.
  Docs: https://clickhouse.com/docs/integrations/clickpipes/aws-privatelink
- **`clickpipes_ingress_cidrs`** now only needs your laptop `/32` for seeding
  Aurora over its public endpoint — not the ClickPipes NAT IPs.
- **Aurora stays public** (`publicly_accessible = true`) so laptop seeding works.
  The NLB still targets the writer's *private* IP, so ClickPipes traffic is
  private. (The alternative VPC-resource PrivateLink path requires a private
  cluster and in-VPC seeding.)
- **NLB target IP**: discovered from the Aurora instance ENI's private IP. It can
  change on failover/replacement — re-run `terraform apply` to re-resolve.
- **Kinesis IAM**: the role name must start with `ClickHouseAccessRole-`; its
  trust policy already references `clickhouse_service.workshop.iam_role`.
- Connect the Postgres pipe to the **writer** (logical replication runs only on
  the primary) — the NLB targets the writer's private IP.

## Useful commands

```bash
terraform fmt -recursive
terraform validate
terraform output
```
