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
Kinesis, the IAM role, PrivateLink, the generator EC2, **and** the ClickPipes.
**By default this is now a single `terraform apply`** — the generator EC2 seeds
Aurora, Terraform waits for that to finish, creates the `raw` database, and then
creates both pipes, all in one run. The two-phase flow is still available as an
opt-out (see T2). Reference:
[hands-on/terraform/README.md](hands-on/terraform/README.md).

## T0 — Prerequisites & environment check

**Say to the user:** "I'll check your tools and credentials — all read-only. For
Terraform we need: Terraform ≥ 1.11, the AWS CLI authenticated, and a ClickHouse
Cloud **API key** (org id + key id + secret). The single-apply also runs two local
provisioners during `apply`, so this machine needs **`curl`** (to create the `raw`
database) and the **AWS CLI** (to poll the EC2 seed over SSM) — both usually already
present."

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
(their `<ip>/32`, only needed for laptop seeding). **Leave the toggles at their
new defaults** — `enable_postgres_clickpipe`, `enable_kinesis_clickpipe`, and
`enable_generator_ec2` all default `true`, and `repo_url` defaults to the canonical
repo (override it if they use a fork). Don't change these yet; the deployment mode
is decided in **T2**. The defaults give a single-apply, end-to-end deploy.

**Verify (without printing secrets):**

```bash
for k in clickhouse_password aurora_master_password clickpipes_user_password; do
  grep -q "change-me-strong-password" terraform.tfvars && \
    echo "$k: still placeholder?" ; done
grep -E 'clickhouse_organization_id|token_key|token_secret' terraform.tfvars | \
  grep -q '<' && echo "ClickHouse API placeholders still present" || echo "ok"
```

**If it fails:** placeholders remain → ask the user to finish filling them.

## T2 — Choose the deployment mode

**Say to the user:** "Terraform now defaults to a **single apply** that brings up
*everything*: the ClickHouse service, Aurora, Kinesis, IAM, PrivateLink, and the
generator EC2 — then it **waits for the EC2 to seed Aurora**, creates the `raw`
database, and finally creates **both ClickPipes**. One `terraform apply`, no manual
SQL, no second run. It just takes longer (~15–25 min) because the apply blocks while
Aurora boots and the EC2 finishes bootstrapping and seeding."

**Ask the user to choose (and confirm before proceeding):**

- **Single apply (default, recommended):** everything in one `terraform apply`.
- **Two-phase apply:** stand up infra first, seed, then a second apply for the
  pipes — useful if they want to inspect each stage, or seed from their laptop
  instead of the EC2.

**Must explain regardless of their choice:** the **Postgres CDC pipe cannot be
created until Aurora has been seeded** — specifically until the `clickpipes_pub`
publication and the `clickpipes_user` role exist, which the generator EC2 creates
during its bootstrap (migrations). In **single apply** this ordering is *automatic*:
Terraform polls the EC2's `/opt/ch-workshop/.seeded` marker and only creates the
Postgres pipe once seeding is done. In **two-phase**, **the ordering is theirs to
enforce** — they must seed before the pipe apply. (The Kinesis pipe has no such
dependency; it only needs the stream + the `raw` database.)

- Single apply → **T3**, then **T4 (single apply)**.
- Two-phase → **T3**, then **T4 (two-phase)**.

## T3 — Initialize Terraform

**Say to the user:** "This downloads the AWS and ClickHouse providers. Safe,
read-only on your infra."

**Run (after approval):**

```bash
cd hands-on/terraform
terraform init
```

**Verify:** "Terraform has been successfully initialized."

## T4 — Apply — HARD GATE

Follow the path the user chose in T2.

### T4 (single apply) — the default

**Say to the user:** "This creates **real, billable** resources and runs to the end
in one go: the ClickHouse service, Aurora, Kinesis, IAM, PrivateLink, the generator
EC2 (which seeds Aurora), then — after Terraform waits for that seed — the `raw`
database and **both ClickPipes**. Expect **~15–25 min**: Aurora reboots once
(logical replication is a static parameter) and the apply *blocks* at
`terraform_data.wait_for_seed` while the EC2 bootstraps and seeds. I'll show you the
plan first. Proceed?"

**Run (after approval):**

```bash
terraform plan        # review together first
terraform apply       # type yes at Terraform's own prompt
```

Don't use `-auto-approve` unless the user explicitly says so.

**Verify:** apply completes; the two `clickhouse_clickpipe` resources are created and
data lands in `raw.customers`, `raw.orders`, `raw.events_raw`. Then go to **T5**.

**If it fails:**

- Blocked a long time at `terraform_data.wait_for_seed` → the EC2 bootstrap is slow
  or failed. In another shell, inspect it (**[S1-B](#s1-b--the-in-vpc-generator-ec2)**);
  if the bootstrap died, re-run `sudo bash
  /opt/ch-workshop/hands-on/scripts/ec2_bootstrap.sh`, then let the wait finish (it
  times out after ~20 min).
- `wait_for_seed` timed out → once `.seeded` exists (per S1-B), just re-run
  `terraform apply` — it resumes and creates the pipes.
- Postgres pipe errors that the publication/role is missing → the seed didn't run;
  confirm the EC2 seeded (S1-B).
- `curl: command not found` / `aws: command not found` → install them on this host
  (see T0), then re-apply.

### T4 (two-phase) — opt-out

Only if the user chose two-phase in T2.

1. **Turn the pipe toggles off for phase 1** (you may set these non-secret values
   after they approve): `enable_postgres_clickpipe = false`,
   `enable_kinesis_clickpipe = false`. Decide the seeding path with them: keep
   `enable_generator_ec2 = true` (EC2 seeds, recommended) or set it `false` to seed
   from their laptop via S1-A.
2. **Apply phase 1 — HARD GATE.** "Creates the infra — service, Aurora, Kinesis, IAM,
   PrivateLink — and the EC2 if enabled. No pipes yet. ~10–15 min. Proceed?"

   ```bash
   terraform plan
   terraform apply
   ```

3. **Seed Aurora** → do **[Shared procedure S1 — Seed Aurora](#s1--seed-aurora)**
   (EC2 path: S1-B to verify; laptop path: S1-A). **The Postgres pipe cannot be
   created until this completes** — it needs `clickpipes_pub` + `clickpipes_user`.
4. **Turn the pipe toggles on:** `enable_postgres_clickpipe = true`,
   `enable_kinesis_clickpipe = true`.
5. **Apply phase 2 — HARD GATE.** "Now creates the `raw` database and both ClickPipes
   against the seeded sources. Proceed?"

   ```bash
   terraform apply
   ```

   **Verify:** both `clickhouse_clickpipe` resources created; data lands in `raw.*`.
   Then go to **T5**.

   **If it fails:** Postgres pipe says the publication/role is missing → S1 didn't
   complete; confirm the seed ran, then re-apply.

## T5 — Read the outputs & confirm data

**Say to the user:** "I'll pull the outputs and confirm data is flowing."

**Run (after approval):**

```bash
terraform output
```

**Verify & relay:** `aurora_writer_endpoint`, `aurora_database_name`,
`kinesis_stream_name`, `clickhouse_https_endpoint`, and `generator_ec2_ssm_command`.
Confirm with the user that `raw.customers`, `raw.orders`, and `raw.events_raw` are
receiving rows (SQL console).

## T6 — Model & query

→ Do **[Shared procedure S2 — Model & query](#s2--model--query)**.

## T7 — Teardown (when finished) — HARD GATE

**Say to the user:** "This destroys everything Terraform created — the ClickHouse
service, both pipes, Aurora, Kinesis, and the generator EC2 (which terminates the
generators with it). If instead you seeded from your laptop (S1-A), stop those Python
producers first. Proceed?"

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

**Then confirm:** account is correct, and note the region. The template now bakes
the ClickPipes static IPs for **all AWS regions** and selects by `AWS::Region`, so
any region works with no extra input (unlisted regions fall back to the us-east-2
list). `ClickPipesIngressCidrsOverride` is only needed if the baked list has drifted.

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

- **Region?** No action needed — the template auto-selects the ClickPipes static
  IPs for the deploy region. Only set `ClickPipesIngressCidrsOverride` if the baked
  list has drifted vs the docs
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

Common causes: subnets not in ≥2 AZs, or an RDS password rule. (Region no longer
matters — the ClickPipes static IPs are baked for all regions and auto-selected.)

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

> Driving SSM non-interactively (you can't open an interactive shell)? Run these via
> `aws ssm send-command --document-name AWS-RunShellScript --instance-ids <id>
> --parameters 'commands=[...]'` and read the result with `aws ssm
> get-command-invocation`, rather than `start-session`.

**Verify:** `ch-generators` is `active (running)` **and the bootstrap actually
finished** — service-active alone isn't enough. Confirm the seed completed:

```bash
ls -l /opt/ch-workshop/.seeded                        # present ⇒ migrations + seed done
grep -n "Bootstrap complete" /var/log/cloud-init-output.log
```

**If it fails:** the most common first-attempt failure is a **timing race** — the EC2
bootstraps before Aurora's writer endpoint is resolvable / accepting connections, so
`run_migrations.py` dies (`Name or service not known`, or `server closed the
connection unexpectedly`) and the service is never installed (`Unit
ch-generators.service could not be found` / `inactive`, no `.seeded` marker). Aurora
is up by the time you're verifying, so just re-run the **idempotent** bootstrap:

```bash
sudo bash /opt/ch-workshop/hands-on/scripts/ec2_bootstrap.sh
```

It re-applies migrations, seeds once (guarded by `/opt/ch-workshop/.seeded`), and
(re)starts the service. ⚠️ If `.seeded` *exists* but the data looks partial/wrong,
`seed_rds.py` is **not** idempotent — `sudo systemctl stop ch-generators`, `sudo rm -f
/opt/ch-workshop/.seeded`, truncate the Aurora tables, then re-run. Full detail:
[hands-on/EC2_GENERATOR.md](hands-on/EC2_GENERATOR.md). (The current CloudFormation and
Terraform templates prevent this race via a dependency on the Aurora *instance*; the
re-run is the recovery if the bootstrap fails for any other reason — clone error, a
transient Aurora blip, etc.)

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
| Postgres pipe can't connect (Track C) | baked ClickPipes IPs drifted vs the docs | set `ClickPipesIngressCidrsOverride` to the current IPs, redeploy |
| `CAPABILITY_NAMED_IAM` error (Track C) | the named Kinesis role | keep `--capabilities CAPABILITY_NAMED_IAM` |
| ClickHouse provider auth fails (Track T) | API key vars wrong | re-export `CLICKHOUSE_ORG_ID` / `_CLOUD_API_KEY` / `_CLOUD_API_SECRET` |
| Postgres pipe won't connect | seeding not done, or (Track C) static IPs stale | confirm S1 ran; check override IPs |
| Kinesis pipe auth error | wrong ClickHouse principal/service | confirm the ARN matches the service |
| Seeding times out from laptop | IP not allow-listed | add `<ip>/32` to the ingress list, re-apply/redeploy |
| Generator EC2 has no `ch-generators` service / no `.seeded` | bootstrap ran before Aurora was ready (DNS/connection race), or another bootstrap error | re-run `sudo bash /opt/ch-workshop/hands-on/scripts/ec2_bootstrap.sh` (idempotent) — see S1-B and [EC2_GENERATOR.md](hands-on/EC2_GENERATOR.md) |
| Rates need changing on a live EC2 | baked into the systemd unit | edit `ExecStart` in `/etc/systemd/system/ch-generators.service`, `daemon-reload`, restart |
