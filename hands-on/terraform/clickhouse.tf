# clickhouse.tf
# ClickHouse Cloud service that receives data from both ClickPipes.
#
# Notes:
# - `tier` is intentionally omitted: it is required only for orgs still on the
#   legacy Cloud tiers and must be omitted on the new tiers. If your org errors
#   asking for a tier, add `tier = "production"`.
# - We size with per-replica memory args. The deprecated min/max_total_memory_gb
#   are not used.
# - password_wo (write-only) keeps the password out of Terraform state. Bump
#   password_wo_version to rotate it.

resource "clickhouse_service" "workshop" {
  name           = var.name_prefix
  cloud_provider = "aws"
  region         = var.clickhouse_region

  # Autoscaling envelope.
  idle_scaling          = true
  idle_timeout_minutes  = 30
  min_replica_memory_gb = var.clickhouse_min_replica_memory_gb
  max_replica_memory_gb = var.clickhouse_max_replica_memory_gb

  ip_access = var.ip_access_list

  password_wo         = var.clickhouse_password
  password_wo_version = 1

  tags = {
    workshop = "clickhouse-aws"
  }
}
