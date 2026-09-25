################################################################################
# VPC flow logs (CIS AWS Foundations v3.0 3.7 / Security Hub EC2.6)
################################################################################

# Trust policy: only the VPC Flow Logs service may assume the role, and only on
# behalf of flow logs in this account and region (cross-service confused-deputy
# prevention via aws:SourceAccount and aws:SourceArn).
data "aws_iam_policy_document" "flow_logs_assume" {
  count = var.enable_flow_logs ? 1 : 0

  statement {
    sid     = "AllowVPCFlowLogsAssumeRole"
    effect  = "Allow"
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["vpc-flow-logs.amazonaws.com"]
    }

    # Confused-deputy protection: restrict to the caller account.
    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [data.aws_caller_identity.current.account_id]
    }

    # Confused-deputy protection: restrict to flow logs in this region/account.
    condition {
      test     = "ArnLike"
      variable = "aws:SourceArn"
      values = [format(
        "arn:%s:ec2:%s:%s:vpc-flow-log/*",
        data.aws_partition.current.partition,
        data.aws_region.current.region,
        data.aws_caller_identity.current.account_id,
      )]
    }
  }
}

# Permissions policy: least privilege, scoped to this module's log group and
# its log streams. No logs:CreateLogGroup (the module owns the group) and no
# wildcard resource.
data "aws_iam_policy_document" "flow_logs" {
  count = var.enable_flow_logs ? 1 : 0

  statement {
    sid    = "AllowPublishToFlowLogGroup"
    effect = "Allow"
    actions = [
      "logs:CreateLogStream",
      "logs:PutLogEvents",
      "logs:DescribeLogGroups",
      "logs:DescribeLogStreams",
    ]
    resources = [
      local.flow_log_group_arn,
      "${local.flow_log_group_arn}:*",
    ]
  }
}

resource "aws_cloudwatch_log_group" "flow_logs" {
  count = var.enable_flow_logs ? 1 : 0

  name              = local.flow_log_group_name
  retention_in_days = var.flow_log_retention_in_days # Security Hub CloudWatch.16 (default 365)
  kms_key_id        = var.kms_key_id                 # null => service-managed encryption

  tags = merge(local.common_tags, {
    Name = local.flow_log_group_name
  })
}

# IAM is global, so the role name includes the region to stay unique when the
# same VPC name is deployed in several regions.
resource "aws_iam_role" "flow_logs" {
  count = var.enable_flow_logs ? 1 : 0

  name               = "${var.name}-flow-logs-${data.aws_region.current.region}"
  description        = "Allows VPC Flow Logs to publish ${var.name} flow logs to CloudWatch Logs"
  assume_role_policy = data.aws_iam_policy_document.flow_logs_assume[0].json

  tags = merge(local.common_tags, {
    Name = "${var.name}-flow-logs-${data.aws_region.current.region}"
  })
}

resource "aws_iam_role_policy" "flow_logs" {
  count = var.enable_flow_logs ? 1 : 0

  name   = "flow-logs-to-cloudwatch"
  role   = aws_iam_role.flow_logs[0].id
  policy = data.aws_iam_policy_document.flow_logs[0].json
}

resource "aws_flow_log" "this" {
  count = var.enable_flow_logs ? 1 : 0

  vpc_id = aws_vpc.this.id

  # ALL is a superset of the REJECT traffic CIS 3.7 requires.
  traffic_type             = "ALL"
  log_destination_type     = "cloud-watch-logs"
  log_destination          = aws_cloudwatch_log_group.flow_logs[0].arn
  iam_role_arn             = aws_iam_role.flow_logs[0].arn
  max_aggregation_interval = var.flow_log_max_aggregation_interval

  tags = merge(local.common_tags, {
    Name = "${var.name}-flow-logs"
  })

  # The role policy must exist before the service first delivers logs.
  depends_on = [aws_iam_role_policy.flow_logs]
}
