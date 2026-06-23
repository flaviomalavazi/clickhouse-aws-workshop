# kinesis.tf
# Amazon Kinesis data stream used as the streaming (append-only) source, plus
# the IAM role ClickPipes assumes to read it.
#
# Role-based auth flow:
#   1. The ClickHouse Cloud service exposes an IAM principal (clickhouse_service
#      .workshop.iam_role) — the "Service role ID (IAM)" in the console.
#   2. We create a role here whose NAME MUST START WITH "ClickHouseAccessRole-"
#      and whose trust policy lets that principal sts:AssumeRole.
#   3. We attach a least-privilege policy scoped to this stream and pass the
#      role ARN to the Kinesis ClickPipe (see clickpipes.tf).

resource "aws_kinesis_stream" "events" {
  name = "${var.name_prefix}-events"

  stream_mode_details {
    stream_mode = var.kinesis_stream_mode
  }

  # shard_count only applies in PROVISIONED mode.
  shard_count = var.kinesis_stream_mode == "PROVISIONED" ? var.kinesis_shard_count : null

  retention_period = 24
}

# Trust policy: allow the ClickHouse service IAM principal to assume this role.
data "aws_iam_policy_document" "clickpipes_kinesis_trust" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]
    principals {
      type        = "AWS"
      identifiers = [clickhouse_service.workshop.iam_role]
    }
  }
}

resource "aws_iam_role" "clickpipes_kinesis" {
  # Name prefix is required by ClickPipes for Kinesis IAM-role auth.
  name               = "ClickHouseAccessRole-${var.name_prefix}-kinesis"
  assume_role_policy = data.aws_iam_policy_document.clickpipes_kinesis_trust.json
}

# Least-privilege read access to the workshop stream.
data "aws_iam_policy_document" "clickpipes_kinesis_perms" {
  statement {
    sid    = "StreamLevel"
    effect = "Allow"
    actions = [
      "kinesis:DescribeStream",
      "kinesis:GetShardIterator",
      "kinesis:GetRecords",
      "kinesis:ListShards",
      "kinesis:RegisterStreamConsumer",
      "kinesis:DeregisterStreamConsumer",
      "kinesis:ListStreamConsumers",
    ]
    resources = [aws_kinesis_stream.events.arn]
  }

  statement {
    sid    = "ConsumerLevel"
    effect = "Allow"
    actions = [
      "kinesis:SubscribeToShard",
      "kinesis:DescribeStreamConsumer",
    ]
    resources = ["${aws_kinesis_stream.events.arn}/*"]
  }

  statement {
    sid       = "ListAll"
    effect    = "Allow"
    actions   = ["kinesis:ListStreams"]
    resources = ["*"]
  }
}

resource "aws_iam_role_policy" "clickpipes_kinesis" {
  name   = "${var.name_prefix}-kinesis-read"
  role   = aws_iam_role.clickpipes_kinesis.id
  policy = data.aws_iam_policy_document.clickpipes_kinesis_perms.json
}
