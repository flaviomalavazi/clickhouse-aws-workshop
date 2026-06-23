# privatelink.tf
# Private connectivity from ClickPipes -> Aurora over AWS PrivateLink, using the
# "VPC endpoint service" approach:
#
#   ClickPipes (reverse private endpoint, ClickHouse account 072088201116)
#     -> interface VPC endpoint (created by ClickPipes)
#        -> our VPC endpoint service
#           -> internal Network Load Balancer (TCP 5432)
#              -> Aurora writer (private IP)
#
# Aurora stays publicly_accessible = true (so laptop seeding still works); the
# NLB targets its *private* IP inside the VPC, so production traffic from
# ClickPipes never traverses the public internet.

############################################
# Discover the Aurora writer's private IP
############################################
# The cluster's DNS endpoint resolves to a PUBLIC IP from outside the VPC, which
# an internal NLB cannot target. Instead we find the instance's ENI (it carries
# the Aurora security group) and read its private IP.
#
# NOTE: a single-writer cluster has one ENI. If you add replicas/RDS Proxy this
# filter returns several ENIs and [0] may not be the writer — pin it explicitly
# then. The private IP can also change on failover/replacement; re-apply to
# re-resolve (a production setup would keep it fresh with a Lambda updater).

data "aws_network_interfaces" "aurora" {
  filter {
    name   = "group-id"
    values = [aws_security_group.aurora.id]
  }

  depends_on = [aws_rds_cluster_instance.pg]
}

data "aws_network_interface" "aurora" {
  id = tolist(data.aws_network_interfaces.aurora.ids)[0]
}

############################################
# Internal NLB fronting Aurora on 5432
############################################

resource "aws_lb" "aurora_pl" {
  name               = "${var.name_prefix}-aurora-nlb"
  internal           = true
  load_balancer_type = "network"
  subnets            = local.subnet_ids

  # REQUIRED for this setup: Aurora's writer is a single instance in ONE AZ,
  # but the ClickPipes interface endpoint may enter the NLB through a node in a
  # DIFFERENT AZ. With cross-zone disabled (the NLB default) that node has no
  # local target and connections time out. Enabling it lets every NLB node reach
  # the single Aurora target regardless of AZ.
  enable_cross_zone_load_balancing = true
}

resource "aws_lb_target_group" "aurora_pl" {
  name        = "${var.name_prefix}-aurora-tg"
  port        = 5432
  protocol    = "TCP"
  target_type = "ip"
  vpc_id      = local.vpc_id

  # Don't preserve the consumer's client IP. Across a PrivateLink endpoint
  # service the original source is in ClickPipes' VPC (e.g. 10.35.x.x) and would
  # be dropped by Aurora's SG. With this off, Aurora sees the NLB node's IP,
  # which is inside our VPC CIDR (allowed by aws_security_group_rule.aurora_ingress_vpc).
  preserve_client_ip = false

  health_check {
    protocol = "TCP"
    port     = "5432"
  }
}

resource "aws_lb_target_group_attachment" "aurora_pl" {
  target_group_arn = aws_lb_target_group.aurora_pl.arn
  target_id        = data.aws_network_interface.aurora.private_ip
  port             = 5432
}

resource "aws_lb_listener" "aurora_pl" {
  load_balancer_arn = aws_lb.aurora_pl.arn
  port              = 5432
  protocol          = "TCP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.aurora_pl.arn
  }
}

############################################
# VPC endpoint service exposed to ClickPipes
############################################

resource "aws_vpc_endpoint_service" "aurora_pl" {
  acceptance_required        = false # auto-accept the ClickPipes endpoint connection
  network_load_balancer_arns = [aws_lb.aurora_pl.arn]

  # Allow only the ClickPipes AWS account to connect to this endpoint service.
  allowed_principals = ["arn:aws:iam::${var.clickpipes_account_id}:root"]

  tags = {
    Name = "${var.name_prefix}-aurora-endpoint-service"
  }
}

############################################
# ClickPipes reverse private endpoint
############################################
# Tells ClickHouse Cloud to stand up an interface endpoint into our endpoint
# service. Exposes dns_names that the Postgres ClickPipe uses as its host.

resource "clickhouse_clickpipes_reverse_private_endpoint" "aurora" {
  service_id                = clickhouse_service.workshop.id
  description               = "${var.name_prefix} Aurora PrivateLink"
  type                      = "VPC_ENDPOINT_SERVICE"
  vpc_endpoint_service_name = aws_vpc_endpoint_service.aurora_pl.service_name
}

locals {
  # The internal DNS name ClickPipes resolves to reach Aurora through the
  # reverse private endpoint. Prefer dns_names; fall back to private_dns_names.
  aurora_private_host = try(
    clickhouse_clickpipes_reverse_private_endpoint.aurora.dns_names[0],
    clickhouse_clickpipes_reverse_private_endpoint.aurora.private_dns_names[0],
  )
}
