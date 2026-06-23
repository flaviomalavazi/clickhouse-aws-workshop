# versions.tf
# Provider requirements for the ClickHouse + AWS workshop.
#
# - clickhouse/clickhouse  >= 3.14 ships the GA `clickhouse_clickpipe` resource
#   (Postgres CDC + Kinesis sources) that we use to wire ingestion.
# - hashicorp/aws provisions the Aurora PostgreSQL source and the Kinesis stream.
#
# Write-only password arguments (password_wo) require Terraform >= 1.11.

terraform {
  required_version = ">= 1.11.0"

  required_providers {
    clickhouse = {
      source  = "ClickHouse/clickhouse"
      version = ">= 3.17.3, < 4.0.0"
    }
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.51"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.9"
    }
  }
}
