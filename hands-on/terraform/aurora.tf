# aurora.tf
# Aurora PostgreSQL cluster used as the CDC source for ClickPipes.
#
# Key requirement for CDC: logical replication must be enabled via the cluster
# parameter group (rds.logical_replication = 1). This is a STATIC parameter, so
# the cluster is rebooted once after creation by AWS when the param group is
# attached at create time.

############################################
# Networking lookups (default VPC fallback)
############################################

data "aws_vpc" "default" {
  count   = var.vpc_id == "" ? 1 : 0
  default = true
}

data "aws_subnets" "default" {
  count = length(var.db_subnet_ids) == 0 ? 1 : 0
  filter {
    name   = "vpc-id"
    values = [local.vpc_id]
  }
}

# Always resolve the chosen VPC so we have its CIDR for the internal NLB ingress
# rule (privatelink.tf), regardless of whether it's the default or a custom VPC.
data "aws_vpc" "selected" {
  id = local.vpc_id
}

locals {
  vpc_id     = var.vpc_id != "" ? var.vpc_id : data.aws_vpc.default[0].id
  subnet_ids = length(var.db_subnet_ids) > 0 ? var.db_subnet_ids : data.aws_subnets.default[0].ids
}

############################################
# Cluster parameter group: enable logical replication
############################################

resource "aws_rds_cluster_parameter_group" "aurora_pg" {
  name        = "${var.name_prefix}-logical-repl"
  family      = "aurora-postgresql17"
  description = "Aurora PG params for ClickPipes CDC (logical replication enabled)"

  parameter {
    name         = "rds.logical_replication"
    value        = "1"
    apply_method = "pending-reboot" # static -> needs reboot
  }

  # 0 disables the WAL sender timeout, which keeps long-lived CDC slots healthy.
  parameter {
    name         = "wal_sender_timeout"
    value        = "0"
    apply_method = "pending-reboot"
  }
}

############################################
# Instance parameter group: CDC replication-safety GUCs
############################################
# These are INSTANCE-level params (NOT valid in the cluster group) and address the
# ClickPipes "Review Postgres settings" checks for a CDC source:
#   - max_slot_wal_keep_size bounds the WAL retained for a lagging replication slot
#     so a stuck/paused pipe can't grow storage unbounded (was -1 = unlimited).
#     Value in MB. Raise it if you pause the pipe for long stretches; too low risks
#     the slot being invalidated, which forces ClickPipes to re-snapshot.
#   - statement_timeout / idle_in_transaction_session_timeout cap long-running and
#     idle-in-transaction sessions that otherwise hold back the catalog xmin and
#     block replication. Value in ms (300000 = 5 min). All three are dynamic, so
#     they apply without a reboot.
resource "aws_db_parameter_group" "aurora_instance" {
  name        = "${var.name_prefix}-instance"
  family      = "aurora-postgresql17"
  description = "Aurora PG instance params for ClickPipes CDC safety"

  parameter {
    name         = "max_slot_wal_keep_size"
    value        = "2048" # MB (2 GiB)
    apply_method = "immediate"
  }

  parameter {
    name         = "statement_timeout"
    value        = "300000" # ms (5 min)
    apply_method = "immediate"
  }

  parameter {
    name         = "idle_in_transaction_session_timeout"
    value        = "300000" # ms (5 min)
    apply_method = "immediate"
  }
}

############################################
# DB subnet group + security group
############################################

resource "aws_db_subnet_group" "aurora" {
  name       = "${var.name_prefix}-subnets"
  subnet_ids = local.subnet_ids
}

resource "aws_security_group" "aurora" {
  name        = "${var.name_prefix}-aurora-sg"
  description = "Allow ClickPipes + workshop access to Aurora PostgreSQL"
  vpc_id      = local.vpc_id

  egress {
    description = "Allow all outbound"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

# Inbound rule(s) for your own IP so the seed scripts can reach Aurora over the
# public endpoint. ClickPipes itself no longer needs to be in this list — it
# reaches Aurora privately over PrivateLink (see privatelink.tf).
# Kept as a separate resource so the list can be edited without churning the SG.
resource "aws_security_group_rule" "aurora_ingress" {
  count             = length(var.clickpipes_ingress_cidrs)
  type              = "ingress"
  from_port         = 5432
  to_port           = 5432
  protocol          = "tcp"
  cidr_blocks       = [var.clickpipes_ingress_cidrs[count.index]]
  security_group_id = aws_security_group.aurora.id
  description       = "Postgres 5432 inbound (workshop seeding)"
}

# The internal Network Load Balancer that fronts Aurora for PrivateLink lives in
# this VPC and forwards on 5432. Allow the whole VPC CIDR inbound so the NLB
# targets (and the seed host, if in-VPC) can reach the writer.
resource "aws_security_group_rule" "aurora_ingress_vpc" {
  type              = "ingress"
  from_port         = 5432
  to_port           = 5432
  protocol          = "tcp"
  cidr_blocks       = [data.aws_vpc.selected.cidr_block]
  security_group_id = aws_security_group.aurora.id
  description       = "Postgres 5432 inbound from in-VPC (PrivateLink NLB path)"
}

############################################
# Aurora PostgreSQL cluster + writer instance
############################################

resource "aws_rds_cluster" "pg" {
  cluster_identifier              = "${var.name_prefix}-aurora-pg"
  engine                          = "aurora-postgresql"
  engine_version                  = var.aurora_engine_version
  database_name                   = var.aurora_database_name
  master_username                 = var.aurora_master_username
  master_password                 = var.aurora_master_password
  db_cluster_parameter_group_name = aws_rds_cluster_parameter_group.aurora_pg.name
  db_subnet_group_name            = aws_db_subnet_group.aurora.name
  vpc_security_group_ids          = [aws_security_group.aurora.id]
  skip_final_snapshot             = true
  apply_immediately               = true
}

resource "aws_rds_cluster_instance" "pg" {
  identifier              = "${var.name_prefix}-aurora-pg-1"
  cluster_identifier      = aws_rds_cluster.pg.id
  engine                  = aws_rds_cluster.pg.engine
  engine_version          = aws_rds_cluster.pg.engine_version
  instance_class          = var.aurora_instance_class
  db_subnet_group_name    = aws_db_subnet_group.aurora.name
  db_parameter_group_name = aws_db_parameter_group.aurora_instance.name # CDC-safety GUCs
  # Kept public so the seed scripts can reach Aurora from your laptop. ClickPipes
  # itself connects privately over AWS PrivateLink (privatelink.tf) — the NLB +
  # VPC endpoint service front the writer's private IP, so no NAT IPs are needed.
  # The VPC-resource PrivateLink path would require this to be false; the NLB path
  # used here does not.
  publicly_accessible = true
}
