# outputs.tf

output "clickhouse_service_id" {
  description = "ClickHouse Cloud service ID."
  value       = clickhouse_service.workshop.id
}

output "clickhouse_service_iam_principal" {
  description = "IAM principal the ClickHouse service uses (trusted by the Kinesis role)."
  value       = clickhouse_service.workshop.iam_role
}

output "clickhouse_https_endpoint" {
  description = "HTTPS endpoint host/port for the SQL console / clients."
  value       = clickhouse_service.workshop.endpoints.https
}

output "aurora_writer_endpoint" {
  description = "Aurora PostgreSQL writer endpoint — point ClickPipes and the seed scripts here."
  value       = aws_rds_cluster.pg.endpoint
}

output "aurora_reader_endpoint" {
  description = "Aurora PostgreSQL reader endpoint."
  value       = aws_rds_cluster.pg.reader_endpoint
}

output "aurora_database_name" {
  description = "Aurora database name."
  value       = var.aurora_database_name
}

output "aurora_endpoint_service_name" {
  description = "VPC endpoint service name fronting Aurora (allow-listed to the ClickPipes account)."
  value       = aws_vpc_endpoint_service.aurora_pl.service_name
}

output "aurora_reverse_private_endpoint_id" {
  description = "ClickPipes reverse private endpoint ID for the Aurora PrivateLink connection."
  value       = clickhouse_clickpipes_reverse_private_endpoint.aurora.id
}

output "aurora_reverse_private_endpoint_status" {
  description = "Status of the Aurora reverse private endpoint (should reach Ready/Active before the pipe connects)."
  value       = clickhouse_clickpipes_reverse_private_endpoint.aurora.status
}

output "aurora_private_host" {
  description = "Private DNS host the Postgres ClickPipe uses to reach Aurora over PrivateLink."
  value       = local.aurora_private_host
}

output "kinesis_stream_name" {
  description = "Kinesis stream name — point kinesis_producer.py here."
  value       = aws_kinesis_stream.events.name
}

output "kinesis_stream_arn" {
  description = "Kinesis stream ARN."
  value       = aws_kinesis_stream.events.arn
}

output "clickpipes_kinesis_role_arn" {
  description = "IAM role ARN ClickPipes assumes to read the Kinesis stream."
  value       = aws_iam_role.clickpipes_kinesis.arn
}

############################################
# In-VPC generator EC2 (when enable_generator_ec2 = true)
############################################

output "generator_ec2_instance_id" {
  description = "Instance ID of the in-VPC data-generator EC2 (null when disabled)."
  value       = one(aws_instance.generator[*].id)
}

output "generator_ec2_private_ip" {
  description = "Private IP of the generator EC2 (null when disabled)."
  value       = one(aws_instance.generator[*].private_ip)
}

output "generator_ec2_ssm_command" {
  description = "Open a shell on the generator EC2 via Session Manager (no SSH/keys). Null when disabled."
  # for-over-splat (0 or 1 element) avoids indexing [0], which would error during
  # plan when the instance is disabled (count = 0).
  value = one([
    for id in aws_instance.generator[*].id :
    "aws ssm start-session --target ${id} --region ${var.aws_region}"
  ])
}

output "next_steps" {
  description = "What to do after `terraform apply`."
  value       = <<-EOT
    Option A — let the in-VPC EC2 do it (no laptop network needed):
      1. Set enable_generator_ec2 = true and repo_url = "<public git url>" in
         terraform.tfvars, then `terraform apply`. The EC2 clones the repo, runs
         migrations, seeds Aurora, and starts the generators as a systemd service.
         Inspect it with: `terraform output -raw generator_ec2_ssm_command`.
         (See ../EC2_GENERATOR.md.)
      2. Create the ClickPipes' target database in ClickHouse (default: `raw`).
      3. Set enable_postgres_clickpipe = true and enable_kinesis_clickpipe = true,
         then `terraform apply` again to create the pipes.
      4. In the ClickHouse SQL console run sql/clickhouse/01_materialized_views.sql
         and sql/clickhouse/02_demo_queries.sql.

    Option B — run the generators from your laptop instead:
      1. cd ../mock_data && uv run run_migrations.py   (schema, clickpipes_user, publication)
      2. uv run seed_rds.py; uv run run_generators.py   (CDC + Kinesis)
      3-4. Same ClickPipes + SQL steps as above.
  EOT
}
