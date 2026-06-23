# clickpipes.tf
# The two managed ingestion pipelines:
#   1. Aurora PostgreSQL CDC  -> raw.customers / raw.orders (ReplacingMergeTree)
#   2. Amazon Kinesis stream  -> raw.events_raw (MergeTree, append-only)
#
# Both are gated behind enable_* flags so you can stand up the infrastructure
# first, run the Aurora SQL bootstrap (publication + clickpipes_user) and start
# the Kinesis producer, THEN flip the flags and re-apply to create the pipes.
#
# NOTE: clickhouse_clickpipe uses nested *attributes* (assignment syntax with
# `=`), not nested blocks.

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
}
