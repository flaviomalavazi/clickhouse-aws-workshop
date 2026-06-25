# variables.tf

############################################
# Naming / general
############################################

variable "name_prefix" {
  description = "Prefix applied to all created resources."
  type        = string
  default     = "ch-aws-workshop"
}

variable "aws_region" {
  description = "AWS region for Aurora PostgreSQL and the Kinesis stream. Keep it close to the ClickHouse Cloud region to minimise latency/egress."
  type        = string
  default     = "us-east-1"
}

############################################
# ClickHouse Cloud service
############################################

variable "clickhouse_organization_id" {
  description = "ClickHouse Cloud organization ID (CLICKHOUSE_ORG_ID). Found in the Cloud console under Organization -> Details."
  type        = string
}

variable "clickhouse_token_key" {
  description = "ClickHouse Cloud API key ID (CLICKHOUSE_CLOUD_API_KEY). Create under Organization -> API keys."
  type        = string
  sensitive   = true
}

variable "clickhouse_token_secret" {
  description = "ClickHouse Cloud API key secret (CLICKHOUSE_CLOUD_API_SECRET). Shown once when the API key is created."
  type        = string
  sensitive   = true
}

variable "clickhouse_region" {
  description = "ClickHouse Cloud region (e.g. us-east-1, eu-west-1)."
  type        = string
  default     = "us-east-1"
}

variable "clickhouse_min_replica_memory_gb" {
  description = "Minimum per-replica memory during autoscaling (GiB). 8 is the smallest production size."
  type        = number
  default     = 8
}

variable "clickhouse_max_replica_memory_gb" {
  description = "Maximum per-replica memory during autoscaling (GiB). Caps spend on ad-hoc queries."
  type        = number
  default     = 60
}

variable "clickhouse_password" {
  description = "Password for the ClickHouse `default` user. Supplied as a write-only argument (never stored in state)."
  type        = string
  sensitive   = true
}

variable "ip_access_list" {
  description = "CIDRs allowed to reach the ClickHouse service endpoint. Default opens to the world for a throwaway workshop — tighten this for anything real."
  type = list(object({
    source      = string
    description = string
  }))
  default = [
    {
      source      = "0.0.0.0/0"
      description = "Workshop - open to all (DO NOT use in production)"
    }
  ]
}

############################################
# Aurora PostgreSQL (CDC source)
############################################

variable "aurora_engine_version" {
  description = "Aurora PostgreSQL engine version. Must be 12+ for ClickPipes CDC."
  type        = string
  default     = "17.7"
}

variable "aurora_instance_class" {
  description = "Instance class for the Aurora writer. db.t4g.medium is plenty for the workshop dataset."
  type        = string
  default     = "db.t4g.medium"
}

variable "aurora_database_name" {
  description = "Initial database created in the Aurora cluster."
  type        = string
  default     = "appdb"
}

variable "aurora_master_username" {
  description = "Aurora master (admin) username."
  type        = string
  default     = "postgres"
}

variable "aurora_master_password" {
  description = "Aurora master password. 8+ chars, no '/', '@', '\"' or spaces."
  type        = string
  sensitive   = true
}

variable "clickpipes_user_password" {
  description = "Password for the dedicated `clickpipes_user` role that ClickPipes uses to read from Aurora. Passed write-only to the ClickPipe."
  type        = string
  sensitive   = true
}

variable "vpc_id" {
  description = "VPC to place the Aurora cluster in. Leave empty to use the region's default VPC."
  type        = string
  default     = ""
}

variable "db_subnet_ids" {
  description = "Subnet IDs for the Aurora DB subnet group. Leave empty to use the default VPC's subnets. For ClickPipes over the public internet these should be public subnets."
  type        = list(string)
  default     = []
}

variable "clickpipes_ingress_cidrs" {
  description = <<-EOT
    CIDRs allowed inbound to Aurora on 5432 over the PUBLIC endpoint, used only
    for loading seed data (e.g. your laptop /32). ClickPipes itself reaches
    Aurora privately over PrivateLink (privatelink.tf), so its NAT egress IPs are
    NOT needed here. Default is intentionally empty so you make a conscious choice.
  EOT
  type        = list(string)
  default     = []
}

variable "clickpipes_account_id" {
  description = "ClickPipes' AWS account ID, allow-listed as a principal on the Aurora VPC endpoint service. Documented at https://clickhouse.com/docs/integrations/clickpipes/aws-privatelink — unlikely to change."
  type        = string
  default     = "072088201116"
}

############################################
# Kinesis (streaming source)
############################################

variable "kinesis_stream_mode" {
  description = "Kinesis capacity mode: ON_DEMAND or PROVISIONED."
  type        = string
  default     = "ON_DEMAND"
}

variable "kinesis_shard_count" {
  description = "Shard count when kinesis_stream_mode = PROVISIONED (ignored for ON_DEMAND)."
  type        = number
  default     = 1
}

############################################
# ClickPipes toggles
############################################

variable "enable_postgres_clickpipe" {
  description = "Create the Aurora PostgreSQL CDC ClickPipe. Set to false until the Aurora SQL bootstrap (publication + clickpipes_user) has been run."
  type        = bool
  default     = false
}

variable "enable_kinesis_clickpipe" {
  description = "Create the Kinesis ClickPipe."
  type        = bool
  default     = false
}

variable "clickhouse_target_database" {
  description = "ClickHouse database that ClickPipes writes into."
  type        = string
  default     = "raw"
}

############################################
# In-VPC data-generator EC2 (optional)
############################################

variable "enable_generator_ec2" {
  description = "Create an EC2 instance inside the Aurora VPC that self-bootstraps and runs the data generators (migrations + seed + CDC/Kinesis traffic). Connects to Aurora over its private IP, so no public-IP allowlisting is needed."
  type        = bool
  default     = false
}

variable "repo_url" {
  description = "Public HTTPS git URL of this workshop repo, cloned by the generator EC2 at boot (e.g. https://github.com/<org>/clickhouse-aws-workshop.git). Required when enable_generator_ec2 = true."
  type        = string
  default     = ""
}

variable "repo_branch" {
  description = "Git branch the generator EC2 checks out."
  type        = string
  default     = "main"
}

variable "ec2_instance_type" {
  description = "Instance type for the generator EC2. t4g.micro is plenty for the workshop generators."
  type        = string
  default     = "t4g.micro"
}

variable "generator_cdc_sleep" {
  description = "Seconds between simulated CDC mutations on the generator EC2 (passed to run_generators.py --cdc-sleep)."
  type        = number
  default     = 0.1
}

variable "generator_kinesis_rate" {
  description = "Kinesis events per second produced by the generator EC2 (passed to run_generators.py --kinesis-rate)."
  type        = number
  default     = 1000
}
