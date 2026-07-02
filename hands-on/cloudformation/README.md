# CloudFormation — the AWS half, without Terraform

> [← Hands-on guide](../README.md) · [Workshop README](../../README.md) · source of truth: [Terraform](../terraform/README.md) · related: [Generator EC2](../EC2_GENERATOR.md) · agent-guided: [AGENT_GUIDE.md](../../AGENT_GUIDE.md)

A single, self-contained CloudFormation template that builds the **same AWS
resources** as the Terraform stack, for attendees who can't or won't use
Terraform. **Terraform (`../terraform/`) remains the source of truth**; this
template mirrors its AWS half.

> **Want an AI to walk you through it?** Hand your agent (e.g. Claude Code)
> [AGENT_GUIDE.md](../../AGENT_GUIDE.md) — an interactive, pair-programming runbook where
> the agent explains each action, asks before running it, and has you fill in your
> own secrets. This README is the reference; that guide is the guided walkthrough.

## What's the same, what's different

This template creates these AWS resources **in your account** (so they're billable
— see [Teardown](#teardown)):

- **Aurora PostgreSQL** cluster + writer instance (the CDC source), with logical
  replication enabled via a cluster parameter group, plus a DB subnet group and a
  security group whose 5432 ingress is the ClickPipes static IPs.
- **Amazon Kinesis** stream (the streaming source).
- The **IAM role ClickPipes assumes** to read Kinesis (name prefixed
  `ClickHouseAccessRole-`, trust = your ClickHouse service's IAM principal).
- An **optional in-VPC generator EC2** (`EnableGeneratorEc2=true`) and its IAM
  role/instance profile, security group, and **two Secrets Manager secrets** holding
  the DB passwords for the instance to read at boot.

**The one intended difference vs Terraform — connectivity.** Terraform reaches
Aurora from ClickPipes over **PrivateLink** (an internal NLB + VPC endpoint
service + a ClickPipes reverse private endpoint). CloudFormation instead makes
Aurora reachable by **allow-listing ClickPipes' static egress IPs** on the Aurora
security group. Aurora stays `PubliclyAccessible: true` and ClickPipes connects
over the public internet from those known IPs.

**Out of scope (cannot be expressed in CloudFormation).** The ClickHouse Cloud
**service** and the **ClickPipes** themselves are ClickHouse-provider resources,
not AWS resources. You create them **manually in the ClickHouse console / ClickPipes
UI** — see [Manual ClickHouse + ClickPipes steps](#manual-clickhouse--clickpipes-steps),
wired from this stack's outputs.

| Terraform file | Here |
| --- | --- |
| `aurora.tf` | Aurora cluster, instance, param group, subnet group, SG |
| `kinesis.tf` | Kinesis stream + ClickPipes IAM role |
| `ec2.tf` | optional generator EC2 — but DB passwords in **Secrets Manager**, not SSM SecureString (CFN can't create SSM SecureString) |
| `privatelink.tf` | **omitted** — replaced by static-IP allow-listing |
| `clickhouse.tf`, `clickpipes.tf` | **omitted** — created manually in the console/UI |

## Files

```
cloudformation/
├── template.yaml            # the whole AWS stack (Transform: AWS::LanguageExtensions)
├── parameters.example.json  # copy, fill in, pass to `aws cloudformation deploy`
└── README.md                # this file
```

## Prerequisites

- **AWS CLI v2**, authenticated (`AWS_PROFILE` or access keys), and permissions to
  create RDS, Kinesis, IAM, EC2, and Secrets Manager resources.
- A **VPC** (the region's default VPC is fine) and **≥2 subnets in different AZs**.
  CloudFormation can't auto-discover the default VPC the way Terraform's data
  sources do, so you pass `VpcId` + `SubnetIds` explicitly (the console shows
  dropdowns). Use **public** subnets — ClickPipes reaches Aurora over the public
  endpoint, and the generator EC2 needs outbound via an internet gateway (there's
  no NAT).
- A **ClickHouse Cloud service** created **first** — you need its IAM principal ARN
  for the Kinesis role trust (step 1 below).

## Manual ClickHouse Service creation

CloudFormation will be built on the AWS side but it needs the ClickHouse Service's IAM role:

1. **Create the ClickHouse Cloud service** in the console (do this _before_ deploy
   — or before re-deploying with the principal). Copy its **IAM principal ARN**
   ("Service role ID (IAM)") and pass it as `ClickHouseIamPrincipalArn`.

## Parameters to fill in

Copy `parameters.example.json` to `parameters.json` and edit it. Every parameter
also has an inline description in `template.yaml` (shown as help text in the
console). These are the ones you must set:

| Parameter | What to put | Notes |
| --- | --- | --- |
| `VpcId` | Your VPC ID (the default VPC is fine) | Console shows a dropdown |
| `SubnetIds` | ≥2 subnet IDs in different AZs, **comma-separated** | Use **public** subnets (default-VPC subnets are) |
| `AuroraMasterPassword` | A strong Aurora admin password | 8+ chars; avoid `/ @ "` and spaces (RDS rule). Hidden (`NoEcho`) |
| `ClickpipesUserPassword` | A strong password for the `clickpipes_user` role | You re-enter this in the ClickPipes UI (step 3). Hidden (`NoEcho`) |
| `ClickHouseIamPrincipalArn` | Your ClickHouse service's **IAM principal ARN** | From the Cloud console ("Service role ID (IAM)"). Needed for the Kinesis pipe — see step 1 |
| `EnableGeneratorEc2` | `true` | you want an in-VPC EC2 to seed + run the generators for you |
| `RepoUrl` | [https://github.com/flaviomalavazi/clickhouse-aws-workshop](https://github.com/flaviomalavazi/clickhouse-aws-workshop) | **required when `EnableGeneratorEc2=true`** — the public git URL of this repo |

Everything else has a working default — leave it unless you have a reason to change it:

| Parameter | Default | Change it when… |
| --- | --- | --- |
| `NamePrefix` | `ch-aws-workshop` | you want a different name prefix (or two stacks in one account/region) |
| `AuroraEngineVersion` | `17.7` | you need a specific Aurora PostgreSQL 17 version |
| `AuroraInstanceClass` | `db.t4g.medium` | you want a bigger/smaller writer |
| `AuroraDatabaseName` | `appdb` | you want a different DB name |
| `AuroraMasterUsername` | `postgres` | you want a different admin user |
| `KinesisStreamMode` | `ON_DEMAND` | you prefer `PROVISIONED` capacity |
| `KinesisShardCount` | `1` | only used when `KinesisStreamMode=PROVISIONED` |
| `ClickPipesIngressCidrsOverride` | _(empty)_ | **only if the baked static IPs drifted** — the deploy region's IPs are auto-selected otherwise (see below) |
| `SeedIngressCidrs` | _(empty)_ | you seed Aurora **from your laptop** — set your `<ip>/32` |
| `RepoBranch` | `main` | the EC2 should check out a different branch |
| `Ec2InstanceType` | `t4g.micro` | you want a different generator instance size |
| `GeneratorCdcSleep` | `0.1` | you want faster/slower simulated CDC mutations (seconds) |
| `GeneratorKinesisRate` | `1000` | you want a different Kinesis events/sec rate |
| `Al2023Ami` | AL2023 SSM alias | leave it — resolves the latest AL2023 AMI at deploy time |

## Region & the static-IP Mapping

The baked `ClickPipesEgressIps` Mapping now covers **all AWS regions** in the
ClickPipes docs. `FindInMap` keys on `AWS::Region`, so **whatever region you deploy
the stack into, the correct ClickPipes static IPs are allow-listed automatically** —
no override needed. A region not in the Mapping falls back to the **us-east-2** list
(via the `FindInMap` `DefaultValue`), mirroring ClickPipes' own default.

**So for the common case you set nothing** — just `--region <your-region>` on the
deploy. `ClickPipesIngressCidrsOverride` remains available as a manual escape hatch.

> **Static IPs drift.** ClickPipes occasionally changes its egress IPs, and the
> docs note **date-based caveats** (some regions' IPs only apply to services
> created after a cut-off date). A static Mapping can't express that, so the baked
> lists are correct for **new** services as of the verified date in the template
> comment (re-sync periodically). If a pipe can't connect, re-check the docs and set
> `ClickPipesIngressCidrsOverride` — it always wins over the baked Mapping.
>
> Source of truth for the IPs:
> <https://clickhouse.com/docs/integrations/clickpipes#list-of-static-ips>

## Deploy

```bash
cd hands-on/cloudformation
cp parameters.example.json parameters.json   # then edit: VPC, subnets, passwords, CH principal ARN

# (optional but recommended) validate first
aws cloudformation validate-template --template-body file://template.yaml
cfn-lint template.yaml         # if installed

# inspect the change set without executing (confirms Fn::ForEach expanded the
# per-IP ingress rules and the conditions resolved as expected)
aws cloudformation deploy \
  --template-file template.yaml \
  --stack-name ch-aws-workshop \
  --parameter-overrides file://parameters.json \
  --capabilities CAPABILITY_NAMED_IAM \
  --no-execute-changeset

# deploy for real
aws cloudformation deploy \
  --template-file template.yaml \
  --stack-name ch-aws-workshop \
  --parameter-overrides file://parameters.json \
  --capabilities CAPABILITY_NAMED_IAM
```

Notes:

- **`CAPABILITY_NAMED_IAM`** is required — the Kinesis role has an explicit name
  (`ClickHouseAccessRole-…`, mandated by ClickPipes).
- The template uses **`Transform: AWS::LanguageExtensions`** (for `Fn::ForEach` and
  `Fn::FindInMap` defaults), so it deploys via **change sets**. `aws cloudformation
  deploy` and the console handle this transparently; plain `create-stack` users
  must `create-change-set` + `execute-change-set`.

Grab the outputs you'll need for the manual steps:

```bash
aws cloudformation describe-stacks --stack-name ch-aws-workshop \
  --query 'Stacks[0].Outputs' --output table
```

| Output | Used for |
| --- | --- |
| `AuroraWriterEndpoint` | Postgres ClickPipe host; seed scripts' `PGHOST` |
| `AuroraDatabaseName` | the CDC pipe's database |
| `KinesisStreamName` | the Kinesis ClickPipe's stream |
| `ClickPipesKinesisRoleArn` | the Kinesis ClickPipe's IAM-role auth |
| `GeneratorSsmCommand` | shell into the generator EC2 (if enabled) |

## Seed Aurora

The CDC pipe needs the schema, the `clickpipes_user` role, and the
`clickpipes_pub` publication to exist first. Two ways — identical to the Terraform
flow:

- **From your laptop:** deploy with `SeedIngressCidrs="<your-ip>/32"`, then follow
  [hands-on/README.md → Phase 2a](../README.md) (`run_migrations.py`, `seed_rds.py`,
  `run_generators.py`) pointing at `AuroraWriterEndpoint`.
- **From the in-VPC EC2:** deploy with `EnableGeneratorEc2=true` and `RepoUrl=…`.
  It clones the repo, runs migrations + seed, and starts the generators as a
  systemd service, reaching Aurora over its private IP (no laptop network, no
  public-IP allow-listing). Shell in with the `GeneratorSsmCommand` output; check
  `systemctl status ch-generators`. See [EC2_GENERATOR.md](../EC2_GENERATOR.md).

> **EC2 secrets divergence.** CloudFormation can't create SSM SecureString
> parameters, so the two DB passwords go into **Secrets Manager**. The shared
> [`../scripts/ec2_bootstrap.sh`](../scripts/ec2_bootstrap.sh) selects the backend
> via `SECRETS_SOURCE` (this stack sets `secretsmanager`; the Terraform path leaves
> it unset and uses SSM). Same script, both paths. Secrets Manager has a small
> per-secret monthly cost.

## Manual ClickHouse Service creation + ClickPipes steps

After we've built the AWS components, we can proceed with the data ingestion:

> [!IMPORTANT]
> **Naming contract — use these exact destination names.** You name the databases
> and tables by hand here, and the SQL in `../sql/clickhouse/` references them
> verbatim. Get a name wrong and the modeling and demo queries fail (or silently
> return nothing).
>
> | Source | Destination DB | Destination table | Engine |
> | --- | --- | --- | --- |
> | Postgres `public.customers` | `raw` | `customers` | ReplacingMergeTree |
> | Postgres `public.orders` | `raw` | `orders` | ReplacingMergeTree |
> | Kinesis stream | `raw` | `events_raw` | MergeTree |
>
> The modeling SQL then creates the `marts` database for the derived views.

1. **Create the ClickPipes' target database** in ClickHouse (the workshop uses
   `raw`): `CREATE DATABASE IF NOT EXISTS raw;`.
2. **Postgres CDC pipe** (ClickPipes UI → _Postgres CDC_) — full walkthrough:
   <https://clickhouse.com/docs/integrations/clickpipes/postgres>
   - **Host** = `AuroraWriterEndpoint` output, **Port** `5432`, **Database** =
     `AuroraDatabaseName`. (Connect to the **writer** — logical replication only
     runs on the primary.)
   - **User** `clickpipes_user`, password = your `ClickpipesUserPassword`.
   - Publication **`clickpipes_pub`**.
   - **Sync mode: "Initial Load + CDC"** — not "CDC only" or "Initial load only".
     _Initial Load_ snapshots the rows already in Aurora (the seeded ~500 customers +
     ~2000 orders) into ClickHouse; _CDC_ then streams every ongoing
     INSERT/UPDATE/DELETE via logical replication. Together you get the historical
     rows **and** the live changes — which the demo needs.
   - Table mappings: `public.customers → customers`, `public.orders → orders`,
     both **ReplacingMergeTree**, destination database `raw`.
   - The Aurora SG already allow-lists the ClickPipes static IPs, so it connects
     over the public endpoint (no PrivateLink).
3. **Kinesis pipe** (ClickPipes UI → _Kinesis_):
   - **Stream** = `KinesisStreamName` output, **region** = your deploy region.
   - Auth **IAM role**, role ARN = `ClickPipesKinesisRoleArn` output.
   - Format `JSONEachRow`, destination `raw.events_raw`. Match the columns
     produced by `kinesis_producer.py` (see `../terraform/clickpipes.tf` for the
     exact column list/types).
4. **Model + query** in the SQL console: run
   `../sql/clickhouse/01_materialized_views.sql` then `02_demo_queries.sql`.

## Teardown

**Order matters.** Delete the **Kinesis ClickPipe first** (in ClickHouse), then the
stack. The Kinesis pipe registers an enhanced fan-out **consumer** on the stream, and
Kinesis refuses to delete a stream that still has consumers — so deleting the stack
first fails with `DeleteStream can't delete ... because there are consumers
associated`. CloudFormation's `AWS::Kinesis::Stream` has no `EnforceConsumerDeletion`
property, so this is handled by ordering, not the template.

```bash
# 1. In the ClickHouse / ClickPipes UI: delete the Kinesis pipe (and the Postgres
#    pipe), then the ClickHouse service. CloudFormation doesn't own these.

# 2. Delete the stack.
aws cloudformation delete-stack --stack-name ch-aws-workshop
```

If the stack delete already failed on the stream (it'll be in `DELETE_FAILED`), force
the stream's consumers out and retry:

```bash
aws kinesis delete-stream --stream-name ch-aws-workshop-events \
  --enforce-consumer-deletion --region <region>          # use your NamePrefix-events name
aws cloudformation delete-stack --stack-name ch-aws-workshop --region <region>   # retry
```

Aurora and Kinesis have `DeletionPolicy: Delete` (throwaway workshop infra), so they
go with the stack; the auto-named Secrets Manager secrets are deleted with a recovery
window.

## Gotchas

- **Baked IPs go stale** (ClickPipes changed its egress IPs since the template was
  last synced) → use `ClickPipesIngressCidrsOverride` (see
  [Region & the static-IP Mapping](#region--the-static-ip-mapping)).
- **Ordering** — the ClickHouse service must exist _before_ deploy (its IAM
  principal feeds the Kinesis role trust); the `ClickPipesKinesisRoleArn` output is
  needed _after_ to create the Kinesis pipe.
- **Postgres CDC settings** (`AuroraDbParameterGroup`): an _instance_ parameter
  group sets the replication-safety GUCs ClickPipes' "Review Postgres settings" step
  flags — `max_slot_wal_keep_size = 2048` MB (bounds the WAL kept for a lagging slot;
  default `-1` is unlimited), plus `statement_timeout` and
  `idle_in_transaction_session_timeout = 300000` ms (5 min) to cap sessions that hold
  back the xmin horizon and block replication. **Tradeoff:** too-low
  `max_slot_wal_keep_size` lets a long pipe pause invalidate the slot (forcing a
  re-snapshot) — raise it if you pause for long stretches. `../sql/aurora/01_setup.sql`
  also pins the two timeouts on the database as a fallback. (These are instance-level,
  not cluster-level, parameters.)
- **Not auto-synced with Terraform** — two stacks to keep in step. Terraform is the
  source of truth; this template mirrors its AWS half, with the intended
  PrivateLink → static-IP difference called out above.
- **Deliberate deviations from generic best practice** (kept for workshop
  reliability/parity, documented in-template): Aurora master + `clickpipes_user`
  passwords are operator-supplied `NoEcho` parameters (not RDS-managed secrets), so
  the same values flow to seeding and the ClickPipes UI; `DeletionPolicy: Delete` on
  Aurora for clean teardown. Aurora storage **is** encrypted at rest (a transparent
  secure default added on top of Terraform).
