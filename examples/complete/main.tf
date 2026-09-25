data "aws_caller_identity" "current" {}

data "aws_partition" "current" {}

data "aws_region" "current" {}

locals {
  account_id = data.aws_caller_identity.current.account_id
  partition  = data.aws_partition.current.partition
  region     = data.aws_region.current.name # 5.x attribute

  # Deterministic flow log group ARN, matching the module's naming rule, so the
  # key policy can be written before the log group exists.
  flow_log_group_arn = "arn:${local.partition}:logs:${local.region}:${local.account_id}:log-group:/aws/vpc-flow-logs/${var.name}"
}

################################################################################
# KMS key for flow log encryption
################################################################################

data "aws_iam_policy_document" "flow_logs_kms" {
  # Account root administers the key (delegates access control to IAM).
  statement {
    sid       = "EnableRootAccountAdministration"
    effect    = "Allow"
    actions   = ["kms:*"]
    resources = ["*"]

    principals {
      type        = "AWS"
      identifiers = ["arn:${local.partition}:iam::${local.account_id}:root"]
    }
  }

  # CloudWatch Logs may use the key only for this VPC's flow log group.
  statement {
    sid    = "AllowCloudWatchLogsFlowLogGroup"
    effect = "Allow"
    actions = [
      "kms:Encrypt*",
      "kms:Decrypt*",
      "kms:ReEncrypt*",
      "kms:GenerateDataKey*",
      "kms:Describe*",
    ]
    resources = ["*"]

    principals {
      type        = "Service"
      identifiers = ["logs.${local.region}.amazonaws.com"]
    }

    condition {
      test     = "ArnEquals"
      variable = "kms:EncryptionContext:aws:logs:arn"
      values   = [local.flow_log_group_arn]
    }
  }
}

resource "aws_kms_key" "flow_logs" {
  description             = "Encrypts VPC flow logs for ${var.name}"
  deletion_window_in_days = 7
  enable_key_rotation     = true
  policy                  = data.aws_iam_policy_document.flow_logs_kms.json

  tags = var.tags
}

resource "aws_kms_alias" "flow_logs" {
  name          = "alias/${var.name}-vpc-flow-logs"
  target_key_id = aws_kms_key.flow_logs.key_id
}

################################################################################
# VPC
################################################################################

module "vpc" {
  source = "../../"

  name       = var.name
  cidr_block = "10.0.0.0/16"

  public_subnets = {
    web-a = { cidr_block = "10.0.0.0/24", availability_zone = "${var.region}a", tags = { "kubernetes.io/role/elb" = "1" } }
    web-b = { cidr_block = "10.0.1.0/24", availability_zone = "${var.region}b" }
    web-c = { cidr_block = "10.0.2.0/24", availability_zone = "${var.region}c" }
  }

  private_subnets = {
    app-a = { cidr_block = "10.0.10.0/24", availability_zone = "${var.region}a" }
    app-b = { cidr_block = "10.0.11.0/24", availability_zone = "${var.region}b" }
    app-c = { cidr_block = "10.0.12.0/24", availability_zone = "${var.region}c" }
  }

  database_subnets = {
    db-a = { cidr_block = "10.0.20.0/24", availability_zone = "${var.region}a" }
    db-b = { cidr_block = "10.0.21.0/24", availability_zone = "${var.region}b" }
  }

  intra_subnets = {
    intra-a = { cidr_block = "10.0.30.0/24", availability_zone = "${var.region}a" }
    intra-b = { cidr_block = "10.0.31.0/24", availability_zone = "${var.region}b" }
  }

  map_public_ip_on_launch      = false
  single_nat_gateway           = false
  gateway_endpoints            = ["s3", "dynamodb"]
  create_database_subnet_group = true

  enable_flow_logs                  = true
  flow_log_retention_in_days        = 731
  flow_log_max_aggregation_interval = 60
  kms_key_id                        = aws_kms_key.flow_logs.arn

  tags = var.tags
}
