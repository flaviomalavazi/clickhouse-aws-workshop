# clickpipes.tf
# The two managed ingestion pipelines:
#   1. Aurora PostgreSQL CDC  -> raw.customers / raw.orders (ReplacingMergeTree)
#   2. Amazon Kinesis stream  -> raw.events_raw (MergeTree, append-only)
#
# Both default ON (var.enable_*_clickpipe = true) so a SINGLE `terraform apply`
# stands up everything end-to-end. Two prerequisites are created here so the pipes
# don't have to be a separate second apply:
#   - terraform_data.clickhouse_target_db creates the destination database
#     (ClickPipes creates the target *table* but not the *database*).
#   - terraform_data.wait_for_seed blocks until the generator EC2 has finished its
#     bootstrap (migrations create clickpipes_pub + clickpipes_user, then seed),
#     which the Postgres CDC pipe validates at creation time.
# Set the toggles to false to fall back to the manual two-phase flow.
#
# NOTE: clickhouse_clickpipe uses nested *attributes* (assignment syntax with
# `=`), not nested blocks.

############################################
# 0) Prerequisites for a single-apply
############################################

# Create the ClickPipes target database before either pipe. ClickPipes creates the
# destination table but not the database. Idempotent; retries while the freshly
# created service finishes coming online. Runs on the apply host (needs curl).
resource "terraform_data" "clickhouse_target_db" {
  count = (var.enable_postgres_clickpipe || var.enable_kinesis_clickpipe) ? 1 : 0

  triggers_replace = [
    clickhouse_service.workshop.id,
    var.clickhouse_target_database,
  ]

  provisioner "local-exec" {
    interpreter = ["/bin/bash", "-c"]
    environment = {
      CH_HOST = clickhouse_service.workshop.endpoints.https.host
      CH_PORT = clickhouse_service.workshop.endpoints.https.port
      CH_KEY  = var.clickhouse_password
      CH_DB   = var.clickhouse_target_database
    }
    command = <<-EOT
      set -uo pipefail
      for i in $(seq 1 30); do
        if curl -fsS --max-time 15 \
             -H "X-ClickHouse-User: default" \
             -H "X-ClickHouse-Key: $CH_KEY" \
             --data-binary "CREATE DATABASE IF NOT EXISTS $CH_DB" \
             "https://$CH_HOST:$CH_PORT/" ; then
          echo "ClickHouse database '$CH_DB' is ready."
          exit 0
        fi
        echo "  ... ClickHouse endpoint not ready yet (attempt $i/30), retrying"; sleep 10
      done
      echo "Failed to create ClickHouse database '$CH_DB' on https://$CH_HOST:$CH_PORT/" >&2
      exit 1
    EOT
  }
}

# Block the Postgres CDC pipe until the generator EC2 has finished bootstrapping.
# The pipe validates clickpipes_pub + clickpipes_user at creation time, and those
# are created by the EC2's migration step. depends_on the instance alone is NOT
# enough: Terraform marks the instance "created" at LAUNCH, long before cloud-init
# (clone -> uv sync -> migrate -> seed) finishes. The bootstrap touches
# /opt/ch-workshop/.seeded as its last successful step; we poll for it over SSM.
# Runs on the apply host (needs the AWS CLI — already required for AWS creds).
resource "terraform_data" "wait_for_seed" {
  count = var.enable_generator_ec2 ? 1 : 0

  triggers_replace = [aws_instance.generator[0].id]

  provisioner "local-exec" {
    interpreter = ["/bin/bash", "-c"]
    environment = {
      INSTANCE_ID = aws_instance.generator[0].id
      REGION      = var.aws_region
    }
    command = <<-EOT
      set -uo pipefail
      echo "Waiting for generator EC2 ($INSTANCE_ID) to finish bootstrapping (.seeded)..."
      for i in $(seq 1 80); do
        CID=$(aws ssm send-command --region "$REGION" --instance-ids "$INSTANCE_ID" \
          --document-name AWS-RunShellScript \
          --parameters 'commands=["test -f /opt/ch-workshop/.seeded && echo SEEDED || echo PENDING"]' \
          --query Command.CommandId --output text 2>/dev/null) || { sleep 15; continue; }
        aws ssm wait command-executed --region "$REGION" --command-id "$CID" --instance-id "$INSTANCE_ID" 2>/dev/null || true
        OUT=$(aws ssm get-command-invocation --region "$REGION" --command-id "$CID" --instance-id "$INSTANCE_ID" --query StandardOutputContent --output text 2>/dev/null || echo "")
        case "$OUT" in
          *SEEDED*) echo "Generator bootstrap complete (.seeded present)."; exit 0 ;;
        esac
        echo "  ... still bootstrapping (attempt $i/80)"; sleep 15
      done
      echo "Timed out waiting for /opt/ch-workshop/.seeded on $INSTANCE_ID." >&2
      echo "Inspect: aws ssm start-session --target $INSTANCE_ID --region $REGION; then journalctl -u ch-generators -e" >&2
      exit 1
    EOT
  }

  depends_on = [aws_instance.generator]
}

############################################
# 1) Aurora PostgreSQL CDC ClickPipe
############################################

resource "clickhouse_clickpipe" "aurora_cdc" {
  count      = var.enable_postgres_clickpipe ? 1 : 0
  name       = "${var.name_prefix}-aurora-cdc"
  service_id = clickhouse_service.workshop.id

  # NOTE: no `scaling` block here. Postgres CDC pipes reject a replica count
  # ("replicas count is not supported for this source type"); their compute is
  # managed by ClickHouse (optionally tuned via clickhouse_clickpipe_cdc_infrastructure).
  # The `scaling` block is only valid for Kafka/Kinesis-style sources.

  source = {
    postgres = {
      # Connect over AWS PrivateLink: the reverse private endpoint's DNS name
      # tunnels through the VPC endpoint service + internal NLB to the Aurora
      # WRITER's private IP (logical replication only runs on the primary).
      # tls_host pins certificate verification to the real Aurora hostname, since
      # the cert is issued for the RDS endpoint, not the private-endpoint DNS.
      host     = local.aurora_private_host
      port     = 5432
      database = var.aurora_database_name
      type     = "aurorapostgres"
      tls_host = aws_rds_cluster.pg.endpoint

      credentials = {
        username            = "clickpipes_user"
        password_wo         = var.clickpipes_user_password
        password_wo_version = 1
      }

      settings = {
        replication_mode = "cdc" # initial snapshot + ongoing CDC
        publication_name = "clickpipes_pub"
      }

      # For CDC pipes the destination tables are created per-mapping; columns are
      # inferred from the source. ReplacingMergeTree handles UPDATE/DELETE replays.
      table_mappings = [
        {
          source_schema_name = "public"
          source_table       = "customers"
          target_table       = "customers"
          table_engine       = "ReplacingMergeTree"
        },
        {
          source_schema_name = "public"
          source_table       = "orders"
          target_table       = "orders"
          table_engine       = "ReplacingMergeTree"
        },
      ]
    }
  }

  destination = {
    database = var.clickhouse_target_database
  }

  # Single-apply ordering: the target database must exist, and the EC2 bootstrap
  # (publication + clickpipes_user + seed) must have completed, before this pipe
  # is created. Both are no-ops/empty lists when their toggles are off.
  depends_on = [
    terraform_data.clickhouse_target_db,
    terraform_data.wait_for_seed,
  ]
}

############################################
# 2) Amazon Kinesis ClickPipe
############################################

resource "clickhouse_clickpipe" "kinesis" {
  count      = var.enable_kinesis_clickpipe ? 1 : 0
  name       = "${var.name_prefix}-kinesis-events"
  service_id = clickhouse_service.workshop.id

  scaling = {
    replicas = 1
  }

  source = {
    kinesis = {
      authentication = "IAM_ROLE"
      iam_role       = aws_iam_role.clickpipes_kinesis.arn
      format         = "JSONEachRow"
      iterator_type  = "TRIM_HORIZON" # read the stream from the start
      region         = var.aws_region
      stream_name    = aws_kinesis_stream.events.name
    }
  }

  destination = {
    database      = var.clickhouse_target_database
    table         = "events_raw"
    managed_table = true

    table_definition = {
      engine = {
        type = "MergeTree"
      }
      partition_by = "toYYYYMMDD(event_ts)"
      sorting_key  = ["event_ts", "event_id"]
    }

    # Column order/names must match the JSON keys produced by kinesis_producer.py.
    columns = [
      { name = "event_id", type = "String" },
      { name = "event_type", type = "LowCardinality(String)" },
      { name = "user_id", type = "String" },
      { name = "session_id", type = "String" },
      { name = "product_id", type = "String" },
      { name = "url", type = "String" },
      { name = "price", type = "Float64" },
      { name = "event_ts", type = "DateTime64(3)" },
    ]
  }

  # Only needs the target database (and the stream + IAM role, referenced above).
  # Unlike the Postgres pipe it does not depend on the Aurora seed.
  depends_on = [terraform_data.clickhouse_target_db]
}
