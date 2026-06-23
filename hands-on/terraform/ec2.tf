# ec2.tf
# Optional in-VPC data generator. An EC2 instance in the SAME VPC as Aurora that
# self-bootstraps (clone repo -> migrate -> seed -> run generators continuously).
#
# Why: running the generators from a laptop is fragile (rotating public IPs to
# allowlist, home networks that block/throttle 5432). From inside the VPC, Aurora's
# writer endpoint resolves to its PRIVATE IP — already permitted by
# aws_security_group_rule.aurora_ingress_vpc — so no public-IP allowlisting is
# needed, and Kinesis is reached via the instance role.
#
# Everything here is gated behind var.enable_generator_ec2.

############################################
# AMI + KMS lookups
############################################

# Latest Amazon Linux 2023 AMI (x86_64). AL2023 ships the SSM agent preinstalled,
# which is what Session Manager access relies on.
data "aws_ssm_parameter" "al2023" {
  name = "/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-x86_64"
}

# AWS-managed key used to encrypt SecureString SSM parameters. The instance role
# needs kms:Decrypt on it to read the passwords with --with-decryption.
data "aws_kms_alias" "ssm" {
  name = "alias/aws/ssm"
}

############################################
# Secrets in SSM Parameter Store (SecureString)
############################################
# Keeps the DB passwords out of plaintext user_data; the EC2 fetches them at boot.

resource "aws_ssm_parameter" "aurora_master_password" {
  count = var.enable_generator_ec2 ? 1 : 0
  name  = "/${var.name_prefix}/aurora_master_password"
  type  = "SecureString"
  value = var.aurora_master_password
}

resource "aws_ssm_parameter" "clickpipes_user_password" {
  count = var.enable_generator_ec2 ? 1 : 0
  name  = "/${var.name_prefix}/clickpipes_user_password"
  type  = "SecureString"
  value = var.clickpipes_user_password
}

############################################
# IAM role + instance profile
############################################

data "aws_iam_policy_document" "generator_trust" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "generator" {
  count              = var.enable_generator_ec2 ? 1 : 0
  name               = "${var.name_prefix}-generator"
  assume_role_policy = data.aws_iam_policy_document.generator_trust.json
}

# Session Manager (keyless shell access, no inbound port needed).
resource "aws_iam_role_policy_attachment" "generator_ssm_core" {
  count      = var.enable_generator_ec2 ? 1 : 0
  role       = aws_iam_role.generator[0].name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

# Produce to the Kinesis stream (kinesis_producer.py).
data "aws_iam_policy_document" "generator_kinesis" {
  statement {
    sid    = "KinesisProduce"
    effect = "Allow"
    actions = [
      "kinesis:PutRecord",
      "kinesis:PutRecords",
      "kinesis:DescribeStream",
      "kinesis:DescribeStreamSummary",
      "kinesis:ListShards",
    ]
    resources = [aws_kinesis_stream.events.arn]
  }
}

resource "aws_iam_role_policy" "generator_kinesis" {
  count  = var.enable_generator_ec2 ? 1 : 0
  name   = "${var.name_prefix}-generator-kinesis"
  role   = aws_iam_role.generator[0].id
  policy = data.aws_iam_policy_document.generator_kinesis.json
}

# Read the two SecureString secrets (and decrypt them).
data "aws_iam_policy_document" "generator_ssm_read" {
  count = var.enable_generator_ec2 ? 1 : 0

  statement {
    sid     = "ReadSecrets"
    effect  = "Allow"
    actions = ["ssm:GetParameter", "ssm:GetParameters"]
    resources = [
      aws_ssm_parameter.aurora_master_password[0].arn,
      aws_ssm_parameter.clickpipes_user_password[0].arn,
    ]
  }

  statement {
    sid       = "DecryptSecureString"
    effect    = "Allow"
    actions   = ["kms:Decrypt"]
    resources = [data.aws_kms_alias.ssm.target_key_arn]
  }
}

resource "aws_iam_role_policy" "generator_ssm_read" {
  count  = var.enable_generator_ec2 ? 1 : 0
  name   = "${var.name_prefix}-generator-ssm-read"
  role   = aws_iam_role.generator[0].id
  policy = data.aws_iam_policy_document.generator_ssm_read[0].json
}

resource "aws_iam_instance_profile" "generator" {
  count = var.enable_generator_ec2 ? 1 : 0
  name  = "${var.name_prefix}-generator"
  role  = aws_iam_role.generator[0].name
}

############################################
# Security group (egress only)
############################################
# No inbound — Session Manager needs none. Egress covers SSM, GitHub (clone),
# the Kinesis API, and Aurora on 5432 (reached via the private IP inside the VPC).

resource "aws_security_group" "generator" {
  count       = var.enable_generator_ec2 ? 1 : 0
  name        = "${var.name_prefix}-generator-sg"
  description = "Egress-only SG for the in-VPC data generator EC2"
  vpc_id      = local.vpc_id

  egress {
    description = "All outbound (SSM, GitHub, Kinesis, Aurora 5432)"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

############################################
# The instance
############################################

resource "aws_instance" "generator" {
  count = var.enable_generator_ec2 ? 1 : 0

  ami                         = data.aws_ssm_parameter.al2023.value
  instance_type               = var.ec2_instance_type
  subnet_id                   = tolist(local.subnet_ids)[0]
  associate_public_ip_address = true # default-VPC subnets are public; outbound via IGW (no NAT)
  vpc_security_group_ids      = [aws_security_group.generator[0].id]
  iam_instance_profile        = aws_iam_instance_profile.generator[0].name

  # Re-run the bootstrap if the templated config changes.
  user_data_replace_on_change = true
  user_data = templatefile("${path.module}/templates/ec2_user_data.sh.tftpl", {
    repo_url                = var.repo_url
    repo_branch             = var.repo_branch
    aws_region              = var.aws_region
    kinesis_stream_name     = aws_kinesis_stream.events.name
    pg_host                 = aws_rds_cluster.pg.endpoint # resolves to the PRIVATE IP from inside the VPC
    pg_database             = var.aurora_database_name
    pg_user                 = var.aurora_master_username
    ssm_pg_password         = aws_ssm_parameter.aurora_master_password[0].name
    ssm_clickpipes_password = aws_ssm_parameter.clickpipes_user_password[0].name
    cdc_sleep               = var.generator_cdc_sleep
    kinesis_rate            = var.generator_kinesis_rate
  })

  tags = {
    Name = "${var.name_prefix}-generator"
  }

  lifecycle {
    precondition {
      condition     = var.repo_url != ""
      error_message = "Set var.repo_url (public HTTPS git URL of this repo) when enable_generator_ec2 = true."
    }
  }

  # Aurora must exist so its endpoint/private IP are reachable for migrations+seed.
  depends_on = [aws_rds_cluster_instance.pg]
}
