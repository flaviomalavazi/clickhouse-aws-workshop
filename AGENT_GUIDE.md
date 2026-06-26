# Agent-guided workshop

> [Workshop README](README.md) · [Hands-on guide](hands-on/README.md) · paths: [Terraform](hands-on/terraform/README.md) · [CloudFormation](hands-on/cloudformation/README.md)

This is a **runbook for an AI agent** (e.g. Claude Code) to run the ClickHouse × AWS
workshop **interactively, alongside a human**, like pair programming: the agent
explains each action in plain language, the human reads it, and the agent runs the
command **only after the human says go**. The human always supplies their own
secrets, IDs, and choices.

The workshop can be provisioned **two ways** — with **Terraform** or with
**CloudFormation**. This guide starts by helping the user pick one, then follows the
matching track. Both tracks converge on the same seeding, modeling, and teardown.

If you are a **human** reading this: you can follow it yourself, but it's written to
be handed to an agent — tell your agent *"follow `AGENT_GUIDE.md`"*.

---

## For the agent: operating rules (read first, follow throughout)

1. **Explain before you act.** Before every command, tell the user in 1–3 plain
   sentences *what* it does and *why*, then show the exact command you will run.
2. **Always ask before running anything.** Never run a command until the user
   explicitly approves it. Treat each command (or tight group of read-only
   commands) as a gate. Anything that **creates, changes, or destroys**
   infrastructure (`terraform apply`, `terraform destroy`, `aws cloudformation
   deploy`/`delete-stack`) is a **HARD GATE** — get an unambiguous "yes".
3. **Never invent secrets or identifiers.** You must NOT make up or guess
   passwords, API keys, the ClickHouse org/IAM identifiers, account IDs,
   VPC/subnet IDs, IPs, or the repo URL. Ask the user, or run a read-only discovery
   command and let the user choose.
4. **Handle secrets safely.** Passwords and API secrets are the user's to set. Ask
   them to put secrets **into the config file (`terraform.tfvars` or
   `parameters.json`) or environment variables themselves**. Do **not** print,
   echo, log, or read back secret values, and keep them out of shell history
   (avoid `echo "$SECRET"`).
5. **One step at a time.** Don't jump ahead or batch phases. Finish a step, confirm
   success with the user, then move on.
6. **Some steps are the human's to do.** Web-console actions (creating a ClickHouse
   service by hand, the ClickPipes UI, running SQL in the SQL console) you cannot
   drive. Give clear instructions, then **wait** for the user to confirm done and to
   paste back any value you need.
7. **Surface what matters.** After a command, summarize the result. After
   provisioning, show the outputs the user needs for the next steps.
8. **Stop on errors.** If a command fails, show the error, explain the likely
   cause, propose a fix, and ask before retrying. Don't loop blindly.
9. **Respect their environment.** Confirm the AWS account/region (and, for
   Terraform, the ClickHouse org) before creating anything. The workshop creates
   **billable** resources.

> [!IMPORTANT]
> **Naming contract — the ClickPipes destination names are not free choices.** The
> modeling and demo SQL in `hands-on/sql/clickhouse/` references these tables by
> name. If a pipe writes to a different database or table, every query in
> `01_materialized_views.sql` and `02_demo_queries.sql` fails (or silently returns
> nothing). When you (or the user) create the pipes, the destinations **must** be:
>
> | Source | Destination DB | Destination table | Engine |
> | --- | --- | --- | --- |
> | Postgres `public.customers` | `raw` | `customers` | ReplacingMergeTree |
> | Postgres `public.orders` | `raw` | `orders` | ReplacingMergeTree |
> | Kinesis stream | `raw` | `events_raw` | MergeTree |
>
> Track T (Terraform) sets these for you in `hands-on/terraform/clickpipes.tf`. On
> Track C (manual/CloudFormation UI), relay these exact names to the user and have
> them confirm each pipe's destination matches before moving on. The modeling SQL
> then creates the `marts` database for derived views — don't pre-create it differently.

### The shape of every step

Each phase below gives you:

- **Say to the user** — the explanation to relay before acting.
- **Need from the user** — what they must provide or do first (if anything).
- **Run (after approval)** — the exact command(s); ask permission, then run.
- **Verify** — how to confirm it worked.
- **If it fails** — the most likely fix.

---

## Step 0 — Choose the provisioning path

**Say to the user:** "There are two ways to stand up this workshop. I'll summarize
them and you choose — then I'll follow that track."

| | **Terraform** (Track T) | **CloudFormation** (Track C) |
| --- | --- | --- |
| Creates the ClickHouse Cloud **service** | Yes, automatically | **No** — you create it in the console |
| Creates the **ClickPipes** | Yes, via flags | **No** — you create them in the ClickPipes UI |
| ClickPipes → Aurora connectivity | **PrivateLink** (private) | **Static-IP allow-listing** (public endpoint) |
| Tooling needed | Terraform CLI **+** ClickHouse Cloud API key **+** AWS creds | **AWS CLI only** (+ ClickHouse console access by hand) |
| Best when | You can use Terraform and want it all automated | You can't/won't use Terraform, or want AWS-native only |

**Need from the user:** a choice — **Track T (Terraform)** or **Track C
(CloudFormation)**.

- If they pick Terraform → go to **[Track T](#track-t--terraform)**.
- If they pick CloudFormation → go to **[Track C](#track-c--cloudformation)**.

Reference docs: [hands-on/terraform/README.md](hands-on/terraform/README.md) and
[hands-on/cloudformation/README.md](hands-on/cloudformation/README.md). Both tracks
finish with the **[Shared procedures](#shared-procedures)**.

---

# Track T — Terraform

Terraform provisions everything in one place: the ClickHouse Cloud service, Aurora,
Kinesis, the IAM role, PrivateLink, and (optionally) the generator EC2 — and creates
the ClickPipes in a second apply. Reference:
[hands-on/terraform/README.md](hands-on/terraform/README.md).

## T0 — Prerequisites & environment check

**Say to the user:** "I'll check your tools and credentials — all read-only. For
Terraform we need: Terraform ≥ 1.11, the AWS CLI authenticated, and a ClickHouse
Cloud **API key** (org id + key id + secret)."

**Run (after approval):**

```bash
terraform version
aws sts get-caller-identity
aws configure get region || echo "AWS_REGION=$AWS_REGION"
# ClickHouse API creds must be present as env vars (do NOT print their values):
for v in CLICKHOUSE_ORG_ID CLICKHOUSE_CLOUD_API_KEY CLICKHOUSE_CLOUD_API_SECRET; do
  [ -n "${!v}" ] && echo "$v: set" || echo "$v: MISSING"
done
```

**Need from the user:** if any ClickHouse var prints `MISSING`, ask them to create
an API key (ClickHouse console → Organization → API keys) and export the three vars
themselves. Confirm the AWS account/region is the one they want.

**Verify:** Terraform present, AWS identity correct, all three ClickHouse vars `set`.

**If it fails:** install/upgrade the missing tool; for AWS creds set `AWS_PROFILE`;
for ClickHouse, have them export the API key vars.

## T1 — Configure `terraform.tfvars`

**Say to the user:** "I'll copy the example tfvars; then you fill in the secrets. I
won't type or read your passwords."

**Run (after approval):**

```bash
cd hands-on/terraform
cp -n terraform.tfvars.example terraform.tfvars
```

**Need from the user (they edit `terraform.tfvars`):** ask them to set, themselves:

- `clickhouse_organization_id`, `clickhouse_token_key`, `clickhouse_token_secret`
  (or rely on the env vars from T0 — confirm which they prefer).
- `clickhouse_password` (the ClickHouse `default` user password).
- `aurora_master_password`, `clickpipes_user_password`.

You may set the **non-secret** choices they make: `aws_region`,
`clickhouse_region`, `name_prefix`, and (optionally) `clickpipes_ingress_cidrs`
(their `<ip>/32` for laptop seeding). Leave `enable_postgres_clickpipe` and
`enable_kinesis_clickpipe` **false** for now (two-phase apply). Mention the
generator EC2 toggle (`enable_generator_ec2` + `repo_url`) as an option.

**Verify (without printing secrets):**

```bash
for k in clickhouse_password aurora_master_password clickpipes_user_password; do
  grep -q "change-me-strong-password" terraform.tfvars && \
    echo "$k: still placeholder?" ; done
grep -E 'clickhouse_organization_id|token_key|token_secret' terraform.tfvars | \
  grep -q '<' && echo "ClickHouse API placeholders still present" || echo "ok"
```

**If it fails:** placeholders remain → ask the user to finish filling them.

## T2 — Initialize Terraform

**Say to the user:** "This downloads the AWS and ClickHouse providers. Safe,
read-only on your infra."

**Run (after approval):**

```bash
terraform init
```

**Verify:** "Terraform has been successfully initialized."

## T3 — Apply phase 1 (infrastructure, pipes off) — HARD GATE

**Say to the user:** "This creates **real, billable** resources: the ClickHouse
Cloud service, Aurora PostgreSQL, Kinesis, IAM, and PrivateLink. The ClickPipes are
**not** created yet (their flags are false) — we turn them on after seeding. I'll
show you the plan first. Proceed?"

**Run (after approval):**

```bash
terraform plan        # review together first
terraform apply       # type yes — or I can run `apply -auto-approve` only if you tell me to
```

Prefer letting Terraform's own `yes` prompt be the final confirmation. Don't use
`-auto-approve` unless the user explicitly says so.

**Verify:** apply completes; note that Aurora reboots once (logical replication is a
static parameter) so it can take ~10–15 min.

**If it fails:** read the error; common causes are ClickHouse API auth, a region
mismatch, or RDS password rules. Fix and re-apply after asking.

## T4 — Read the outputs

**Say to the user:** "I'll pull the outputs you'll need for seeding and modeling."

**Run (after approval):**

```bash
terraform output
```

**Verify & relay:** `aurora_writer_endpoint`, `aurora_database_name`,
`kinesis_stream_name`, `clickhouse_https_endpoint`, and (if EC2 enabled)
`generator_ec2_ssm_command`.

## T5 — Seed Aurora

→ Do **[Shared procedure S1 — Seed Aurora](#s1--seed-aurora)**, then return here.

## T6 — Create the ClickPipes target database

**Say to the user:** "In the ClickHouse SQL console, create the database the pipes
write into:"

```sql
CREATE DATABASE IF NOT EXISTS raw;
```

**Need from the user:** confirm they ran it.

## T7 — Apply phase 2 (create the ClickPipes) — HARD GATE

**Say to the user:** "Now we flip the pipe flags on and apply again — this creates
the Postgres CDC pipe and the Kinesis pipe (over PrivateLink). The sources should
already be seeded and emitting. Proceed?"

**Need from the user:** confirm `enable_postgres_clickpipe = true` and
`enable_kinesis_clickpipe = true` in `terraform.tfvars` (you may set these after
they approve).

**Run (after approval):**

```bash
terraform apply
```

**Verify:** the two `clickhouse_clickpipe` resources are created; data starts
arriving in `raw.customers`, `raw.orders`, `raw.events_raw`.

**If it fails:** the Postgres pipe needs `clickpipes_pub` + `clickpipes_user` to
exist (the seed/migration in S1 creates them) — confirm S1 ran before this.

## T8 — Model & query

→ Do **[Shared procedure S2 — Model & query](#s2--model--query)**.

## T9 — Teardown (when finished) — HARD GATE

**Say to the user:** "This destroys everything Terraform created — the ClickHouse
service, both pipes, Aurora, and Kinesis. Stop the Python producers first. Proceed?"

**Run (after approval):**

```bash
terraform destroy
```

**Verify:** destroy completes. (The Kinesis stream sets `enforce_consumer_deletion =
true`, so a lingering ClickPipes consumer won't block it.) If they used the EC2 but
want to keep infra and only stop cost, `../scripts/generator_ec2.sh stop` powers it
down instead.

---

# Track C — CloudFormation

CloudFormation builds **only the AWS side**. You create the ClickHouse Cloud service
and the ClickPipes **by hand**, and Aurora is reached by allow-listing ClickPipes'
**static egress IPs**. Reference:
[hands-on/cloudformation/README.md](hands-on/cloudformation/README.md).

## C0 — Prerequisites & environment check

**Say to the user:** "I'll check your tools and which AWS account/region we'd deploy
into — all read-only. For CloudFormation we need the AWS CLI v2 authenticated."

**Run (after approval):**

```bash
aws --version
aws sts get-caller-identity
aws configure get region || echo "AWS_REGION=$AWS_REGION"
cfn-lint --version 2>/dev/null || echo "cfn-lint not installed (optional)"
```

**Then confirm:** account is correct, and region is `us-east-1` (the baked
ClickPipes static-IP list covers `us-east-1` only — other regions need
`ClickPipesIngressCidrsOverride` later).

**If it fails:** old/missing CLI → install AWS CLI v2; wrong account → set
`AWS_PROFILE`; no region → `export AWS_REGION=...`.

## C1 — Create the ClickHouse Cloud service (the user does this)

**Say to the user:** "CloudFormation builds only AWS. You create the ClickHouse
service in the console, and we need its IAM principal ARN before deploying (the
Kinesis role trusts it). Please:
1) create a service; 2) copy its **IAM principal ARN** (*'Service role ID (IAM)'*);
3) paste it back to me. Also set the ClickHouse `default` password for later."

**Need from the user:** the **IAM principal ARN** (`arn:aws:iam::...`). Don't
proceed to deploy without it (unless they won't use the Kinesis pipe).

## C2 — Pick the VPC and subnets

**Say to the user:** "I'll list your VPCs/subnets so you can pick where Aurora goes.
We need a VPC and **≥2 public subnets in different AZs**. The default VPC is fine."

**Run (after approval):**

```bash
aws ec2 describe-vpcs \
  --query 'Vpcs[].{VpcId:VpcId,Default:IsDefault,Cidr:CidrBlock}' --output table
# after the user names a VPC:
aws ec2 describe-subnets --filters Name=vpc-id,Values=<vpc-id> \
  --query 'Subnets[].{Subnet:SubnetId,AZ:AvailabilityZone,Public:MapPublicIpOnLaunch}' \
  --output table
```

**Need from the user:** the **VpcId** and **2+ SubnetIds** in different AZs.

**Verify:** chosen subnets span ≥2 AZs and are public. If none are public, warn and
ask how to proceed.

## C3 — Fill in `parameters.json`

**Say to the user:** "I'll copy the example parameters file; you fill in the secrets
yourself. I'll set the non-secret choices (VPC, subnets, the ClickHouse ARN). I
won't type or read your passwords."

**Run (after approval):**

```bash
cd hands-on/cloudformation
cp -n parameters.example.json parameters.json
```

You (agent) may set the **non-secret** values: `VpcId`, `SubnetIds`
(comma-separated), `ClickHouseIamPrincipalArn`, any region override, and optional
toggles they ask for.

**Need from the user (they edit the file):** `AuroraMasterPassword` and
`ClickpipesUserPassword` (strong; 8+ chars; avoid `/ @ "` and spaces). Optional
decisions to walk through:

- **Outside `us-east-1`?** They provide that region's ClickPipes static `/32`s for
  `ClickPipesIngressCidrsOverride`
  (<https://clickhouse.com/docs/integrations/clickpipes#list-of-static-ips>).
- **Seeding from laptop?** Offer to detect their IP for `SeedIngressCidrs` (they
  confirm): `echo "$(curl -s https://checkip.amazonaws.com)/32"`.
- **Want the generator EC2?** Set `EnableGeneratorEc2=true` + `RepoUrl`.

**Verify (without printing secrets):**

```bash
python3 - <<'PY'
import json
p={d["ParameterKey"]:d["ParameterValue"] for d in json.load(open("parameters.json"))}
for k in ["VpcId","SubnetIds","ClickHouseIamPrincipalArn","AuroraMasterPassword","ClickpipesUserPassword"]:
    v=p.get(k,""); bad=(not v) or "REPLACE" in v or v=="change-me-strong-password"
    print(f"{k}: {'NEEDS A VALUE' if bad else 'set'}")
PY
```

**If it fails:** any key prints `NEEDS A VALUE` → ask the user to fill it.

## C4 — Validate the template

**Say to the user:** "Before deploying I'll validate the template, and optionally do
a dry-run change set that expands everything **without creating resources**."

**Run (after approval):**

```bash
aws cloudformation validate-template --template-body file://template.yaml
cfn-lint template.yaml          # if installed
aws cloudformation deploy --template-file template.yaml --stack-name ch-aws-workshop \
  --parameter-overrides file://parameters.json --capabilities CAPABILITY_NAMED_IAM \
  --no-execute-changeset
```

**Verify:** validation passes; the dry run prints a change set but executes nothing.

## C5 — Deploy the stack — HARD GATE

**Say to the user:** "This **creates real, billable** resources — Aurora, Kinesis,
IAM, and (if enabled) EC2 + Secrets Manager. ~10–15 min (Aurora reboots once).
Shall I deploy?"

**Run (after an explicit "yes"):**

```bash
aws cloudformation deploy --template-file template.yaml --stack-name ch-aws-workshop \
  --parameter-overrides file://parameters.json --capabilities CAPABILITY_NAMED_IAM
```

**Verify:** "Successfully created/updated stack."

**If it fails:** inspect events and explain before retrying:

```bash
aws cloudformation describe-stack-events --stack-name ch-aws-workshop \
  --query 'StackEvents[?contains(ResourceStatus,`FAILED`)].[LogicalResourceId,ResourceStatusReason]' \
  --output table
```

Common causes: subnets not in ≥2 AZs, RDS password rule, or region ≠ us-east-1
without `ClickPipesIngressCidrsOverride`.

## C6 — Read the stack outputs

**Say to the user:** "These are the values you'll paste into the ClickPipes UI and
use for seeding."

**Run (after approval):**

```bash
aws cloudformation describe-stacks --stack-name ch-aws-workshop \
  --query 'Stacks[0].Outputs[].{Key:OutputKey,Value:OutputValue}' --output table
```

**Relay:** `AuroraWriterEndpoint`, `AuroraDatabaseName`, `KinesisStreamName`,
`ClickPipesKinesisRoleArn`, and `GeneratorSsmCommand` (if EC2 enabled).

## C7 — Seed Aurora

→ Do **[Shared procedure S1 — Seed Aurora](#s1--seed-aurora)**, then return here.

## C8 — Create the ClickPipes (the user does this in the UI)

**Say to the user:** "I can't drive the ClickPipes web UI, so you'll create the two
pipes — I'll hand you the exact values from the stack outputs. Walkthrough:
<https://clickhouse.com/docs/integrations/clickpipes/postgres>"

First, in the SQL console: `CREATE DATABASE IF NOT EXISTS raw;`

**Postgres CDC pipe** (ClickPipes UI → *Postgres CDC*):

- Host = `AuroraWriterEndpoint`, Port `5432`, Database = `AuroraDatabaseName`
  (the **writer**).
- User `clickpipes_user`, password = the `ClickpipesUserPassword` they set.
- Replication mode **CDC**, publication **`clickpipes_pub`**.
- Mappings: `public.customers → customers`, `public.orders → orders`, both
  **ReplacingMergeTree**, destination `raw`.

**Kinesis pipe** (ClickPipes UI → *Kinesis*):

- Stream = `KinesisStreamName`, region = the deploy region.
- Auth **IAM role**, role ARN = `ClickPipesKinesisRoleArn`.
- Format `JSONEachRow`, destination `raw.events_raw` (columns in
  [hands-on/terraform/clickpipes.tf](hands-on/terraform/clickpipes.tf)).

**Verify:** both pipes show data flowing.

**If it fails:** Postgres pipe can't connect → static IPs stale/wrong region
(`ClickPipesIngressCidrsOverride`); Kinesis auth error → confirm
`ClickHouseIamPrincipalArn` matched this service.

## C9 — Model & query

→ Do **[Shared procedure S2 — Model & query](#s2--model--query)**.

## C10 — Teardown (when finished) — HARD GATE

**Say to the user:** "I'll delete the AWS stack to stop charges. The **ClickPipes
and ClickHouse service are not owned by CloudFormation** — you delete those in the
console separately. **Delete the Kinesis ClickPipe first** (it registers a consumer
on the stream, and Kinesis won't delete a stream that still has consumers). Aurora
and Kinesis then delete with the stack. Proceed?"

**Need from the user:** confirm they've deleted the Kinesis (and Postgres) ClickPipe
in the ClickHouse UI first.

**Run (after an explicit "yes"):**

```bash
aws cloudformation delete-stack --stack-name ch-aws-workshop
aws cloudformation wait stack-delete-complete --stack-name ch-aws-workshop
```

**If it fails** with `DeleteStream can't delete ... because there are consumers
associated`, the Kinesis pipe's consumer is still registered. Force it out and retry
(CFN's `AWS::Kinesis::Stream` has no `EnforceConsumerDeletion` property, so this is
manual):

```bash
aws kinesis delete-stream --stream-name <NamePrefix>-events \
  --enforce-consumer-deletion --region <region>
aws cloudformation delete-stack --stack-name ch-aws-workshop --region <region>
```

**Then remind:** delete the ClickPipes and the ClickHouse Cloud service in the
console. To keep infra but stop EC2 cost: `../scripts/generator_ec2.sh stop`.

---

# Shared procedures

Both tracks use these. Return to your track's step after completing one.

## S1 — Seed Aurora

The Postgres CDC pipe needs the schema, the `clickpipes_user` role, and the
`clickpipes_pub` publication first. Two ways — ask the user which:

### S1-A — from the laptop

**Say to the user:** "I'll run the migration + seed scripts against Aurora from
here. This needs your IP allow-listed (Track T: `clickpipes_ingress_cidrs`; Track C:
`SeedIngressCidrs`) and the env set up per [hands-on/README.md](hands-on/README.md)
Phase 2a (`.env`, `uv sync`, RDS CA bundle)."

**Run (after approval), from `hands-on/`:**

```bash
cd "$(git rev-parse --show-toplevel)/hands-on"
uv sync
# RDS CA bundle (gitignored — needed for verify-full TLS):
curl -fsSL https://truststore.pki.rds.amazonaws.com/global/global-bundle.pem \
  -o sql/aurora/global-bundle.pem
uv run mock_data/run_migrations.py     # schema, clickpipes_user, publication
uv run mock_data/seed_rds.py           # initial rows
uv run mock_data/run_generators.py     # live CDC + Kinesis (Ctrl-C to stop)
```

**Need from the user:** a filled `hands-on/.env` (from the outputs). Offer to help
populate the non-secret values; let them add secrets.

**Verify:** migrations + seed complete without connection/TLS errors; generators
emit.

**If it fails:** connection refused/timeout → IP not allow-listed; TLS error → RDS
CA bundle step above.

### S1-B — the in-VPC generator EC2

**Say to the user:** "If you provisioned the generator EC2, it already cloned the
repo, ran migrations + seed, and started the generators. We just verify it."

**Run (after approval):** open a shell (Track T: `generator_ec2_ssm_command`;
Track C: `GeneratorSsmCommand`), then:

```bash
systemctl status ch-generators
journalctl -u ch-generators -n 30 --no-pager
```

Mention `hands-on/scripts/generator_ec2.sh {stop|start|status}` to manage cost.

**Verify:** `ch-generators` is `active (running)`.

## S2 — Model & query

**Say to the user:** "Final lab step — run the modeling SQL in the ClickHouse SQL
console: the incremental materialized view + AggregatingMergeTree, then the demo
queries."

**Need from the user:** in the ClickHouse console, run, in order:

- `hands-on/sql/clickhouse/01_materialized_views.sql`
- `hands-on/sql/clickhouse/02_demo_queries.sql`

**Verify:** the demo queries return rows joining the CDC and streaming data.

---

## Appendix — quick troubleshooting

| Symptom | Likely cause | Action |
| --- | --- | --- |
| Aurora create fails | subnets not in ≥2 AZs, or RDS password rule | fix subnets/password, re-apply/redeploy |
| CFN deploy fails, region ≠ us-east-1 | no baked static IPs | set `ClickPipesIngressCidrsOverride`, redeploy |
| `CAPABILITY_NAMED_IAM` error (Track C) | the named Kinesis role | keep `--capabilities CAPABILITY_NAMED_IAM` |
| ClickHouse provider auth fails (Track T) | API key vars wrong | re-export `CLICKHOUSE_ORG_ID` / `_CLOUD_API_KEY` / `_CLOUD_API_SECRET` |
| Postgres pipe won't connect | seeding not done, or (Track C) static IPs stale | confirm S1 ran; check override IPs |
| Kinesis pipe auth error | wrong ClickHouse principal/service | confirm the ARN matches the service |
| Seeding times out from laptop | IP not allow-listed | add `<ip>/32` to the ingress list, re-apply/redeploy |
| Rates need changing on a live EC2 | baked into the systemd unit | edit `ExecStart` in `/etc/systemd/system/ch-generators.service`, `daemon-reload`, restart |
