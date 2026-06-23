# providers.tf
# Provider configuration.
#
# ClickHouse Cloud auth uses an organization ID + an API key pair, supplied via
# terraform.tfvars:
#
#   CLICKHOUSE_ORG_ID           -> var.clickhouse_organization_id -> organization_id
#   CLICKHOUSE_CLOUD_API_KEY    -> var.clickhouse_token_key        -> token_key
#   CLICKHOUSE_CLOUD_API_SECRET -> var.clickhouse_token_secret     -> token_secret
#
# Create the API key in the Cloud console: Organization -> API keys.
# terraform.tfvars is gitignored, so these values never land in version control.

provider "clickhouse" {
  organization_id = var.clickhouse_organization_id
  token_key       = var.clickhouse_token_key
  token_secret    = var.clickhouse_token_secret
}

provider "aws" {
  region = var.aws_region

  default_tags {
    tags = {
      Project   = "clickhouse-aws-workshop"
      ManagedBy = "terraform"
    }
  }
}
