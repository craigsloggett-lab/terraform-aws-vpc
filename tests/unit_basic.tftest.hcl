# Generated from specs/003-vpc/design.md Section 5
# Unit tests: Secure Defaults (mock provider, command = plan, no credentials)

mock_provider "aws" {
  mock_data "aws_iam_policy_document" {
    defaults = { json = "{\"Version\":\"2012-10-17\",\"Statement\":[]}" } # must be valid JSON (P1)
  }
  mock_data "aws_region" {
    defaults = { region = "us-east-1" }
  }
  mock_data "aws_caller_identity" {
    defaults = { account_id = "123456789012" }
  }
  mock_data "aws_partition" {
    defaults = { partition = "aws" }
  }
}

variables {
  name       = "test"
  cidr_block = "10.0.0.0/16"
}

# Scenario: "Secure Defaults (basic)"
run "test_secure_defaults" {
  command = plan

  variables {
    name       = "test"
    cidr_block = "10.0.0.0/16"
  }

  # 1
  assert {
    condition     = aws_vpc.this.cidr_block == "10.0.0.0/16"
    error_message = "VPC cidr_block must equal the cidr_block input (10.0.0.0/16)."
  }

  # 2
  assert {
    condition     = aws_vpc.this.enable_dns_support == true
    error_message = "VPC must enable DNS support by default (FR-02)."
  }

  # 3
  assert {
    condition     = aws_vpc.this.enable_dns_hostnames == true
    error_message = "VPC must enable DNS hostnames by default (FR-02); the provider default is false."
  }

  # 4
  assert {
    condition     = aws_vpc.this.tags["Name"] == "test"
    error_message = "VPC Name tag must equal var.name (\"test\")."
  }

  # 5
  assert {
    condition     = aws_vpc.this.tags["ManagedBy"] == "terraform"
    error_message = "VPC must carry ManagedBy = \"terraform\" when the consumer does not override it (FR-13)."
  }

  # 6
  assert {
    condition     = length(aws_default_security_group.this.ingress) == 0
    error_message = "Default security group must have no ingress rules (CIS 5.4 / Security Hub EC2.2)."
  }

  # 7
  assert {
    condition     = length(aws_default_security_group.this.egress) == 0
    error_message = "Default security group must have no egress rules (CIS 5.4 / Security Hub EC2.2)."
  }

  # 8
  assert {
    condition     = length(aws_flow_log.this) == 1
    error_message = "A VPC flow log must be created by default (CIS 3.7 / Security Hub EC2.6)."
  }

  # 9
  assert {
    condition     = aws_flow_log.this[0].traffic_type == "ALL"
    error_message = "Flow log must capture ALL traffic (accepted and rejected)."
  }

  # 10
  assert {
    condition     = aws_flow_log.this[0].log_destination_type == "cloud-watch-logs"
    error_message = "Flow log destination type must be cloud-watch-logs."
  }

  # 11
  assert {
    condition     = aws_flow_log.this[0].max_aggregation_interval == 600
    error_message = "Flow log max_aggregation_interval must default to 600 seconds."
  }

  # 12 [plan-unknown] aws_flow_log.this[0].log_destination -> substitute: log group exists
  assert {
    condition     = length(aws_cloudwatch_log_group.flow_logs) == 1
    error_message = "The module-owned flow log CloudWatch Logs group must be created by default."
  }

  # 13
  assert {
    condition     = aws_cloudwatch_log_group.flow_logs[0].name == "/aws/vpc-flow-logs/test"
    error_message = "Flow log group name must be deterministic: /aws/vpc-flow-logs/<name>."
  }

  # 14
  assert {
    condition     = aws_cloudwatch_log_group.flow_logs[0].retention_in_days == 365
    error_message = "Flow log group retention must default to 365 days (Security Hub CloudWatch.16)."
  }

  # 15
  assert {
    condition     = aws_cloudwatch_log_group.flow_logs[0].kms_key_id == null
    error_message = "Flow log group must use service-managed encryption (kms_key_id = null) by default."
  }

  # 16
  assert {
    condition     = aws_iam_role.flow_logs[0].name == "test-flow-logs-us-east-1"
    error_message = "Flow log IAM role name must be <name>-flow-logs-<region> because IAM is global."
  }

  # 17
  assert {
    condition     = one(data.aws_iam_policy_document.flow_logs_assume[0].statement[0].principals).type == "Service"
    error_message = "Flow log trust policy principal type must be Service."
  }

  # 18
  assert {
    condition     = toset(one(data.aws_iam_policy_document.flow_logs_assume[0].statement[0].principals).identifiers) == toset(["vpc-flow-logs.amazonaws.com"])
    error_message = "Flow log trust policy must trust only vpc-flow-logs.amazonaws.com."
  }

  # 19
  assert {
    condition     = toset(data.aws_iam_policy_document.flow_logs_assume[0].statement[0].actions) == toset(["sts:AssumeRole"])
    error_message = "Flow log trust policy must allow only sts:AssumeRole."
  }

  # 20
  assert {
    condition     = contains(one([for c in data.aws_iam_policy_document.flow_logs_assume[0].statement[0].condition : c if c.variable == "aws:SourceAccount"]).values, "123456789012")
    error_message = "Flow log trust policy must restrict aws:SourceAccount to the caller account (confused-deputy protection)."
  }

  # 21
  assert {
    condition     = one([for c in data.aws_iam_policy_document.flow_logs_assume[0].statement[0].condition : c.test if c.variable == "aws:SourceArn"]) == "ArnLike"
    error_message = "Flow log trust policy aws:SourceArn condition must use the ArnLike operator."
  }

  # 22
  assert {
    condition     = contains(one([for c in data.aws_iam_policy_document.flow_logs_assume[0].statement[0].condition : c if c.variable == "aws:SourceArn"]).values, "arn:aws:ec2:us-east-1:123456789012:vpc-flow-log/*")
    error_message = "Flow log trust policy aws:SourceArn must be arn:<partition>:ec2:<region>:<account>:vpc-flow-log/* (confused-deputy protection)."
  }

  # 23
  assert {
    condition     = toset(data.aws_iam_policy_document.flow_logs[0].statement[0].actions) == toset(["logs:CreateLogStream", "logs:PutLogEvents", "logs:DescribeLogGroups", "logs:DescribeLogStreams"])
    error_message = "Flow log permissions must be exactly the four logs actions (no logs:CreateLogGroup)."
  }

  # 24
  assert {
    condition     = toset(data.aws_iam_policy_document.flow_logs[0].statement[0].resources) == toset(["arn:aws:logs:us-east-1:123456789012:log-group:/aws/vpc-flow-logs/test", "arn:aws:logs:us-east-1:123456789012:log-group:/aws/vpc-flow-logs/test:*"])
    error_message = "Flow log permissions must be scoped to the module log group ARN and its :* stream ARN, with no wildcard resource."
  }

  # 25
  assert {
    condition     = aws_iam_role_policy.flow_logs[0].name == "flow-logs-to-cloudwatch"
    error_message = "Flow log role policy flow-logs-to-cloudwatch must be attached to the role."
  }

  # 26
  assert {
    condition     = length(aws_internet_gateway.this) == 0
    error_message = "No internet gateway may be created when no public subnets are declared (FR-04)."
  }

  # 27
  assert {
    condition     = length(aws_nat_gateway.this) == 0
    error_message = "No NAT gateway may be created when no private subnets are declared (FR-05)."
  }

  # 28
  assert {
    condition     = length(aws_eip.nat) == 0
    error_message = "No NAT Elastic IPs may be allocated when no private subnets are declared."
  }

  # 29
  assert {
    condition     = length(aws_vpc_endpoint.gateway) == 0
    error_message = "No gateway endpoints may be created by default (gateway_endpoints defaults to [])."
  }

  # 30
  assert {
    condition     = length(aws_db_subnet_group.this) == 0
    error_message = "No DB subnet group may be created when no database subnets are declared."
  }

  # 31
  assert {
    condition     = output.vpc_cidr_block == "10.0.0.0/16"
    error_message = "Output vpc_cidr_block must equal the cidr_block input."
  }

  # 32
  assert {
    condition     = length(output.azs) == 0
    error_message = "Output azs must be empty when no subnets are declared."
  }

  # 33
  assert {
    condition     = output.public_route_table_id == null
    error_message = "Output public_route_table_id must be null when no public subnets are declared."
  }

  # 34
  assert {
    condition     = output.flow_log_cloudwatch_log_group_name == "/aws/vpc-flow-logs/test"
    error_message = "Output flow_log_cloudwatch_log_group_name must be /aws/vpc-flow-logs/<name>."
  }

  # 35 [plan-unknown] output.vpc_id -> substitute assertion 1
  assert {
    condition     = aws_vpc.this.cidr_block == "10.0.0.0/16"
    error_message = "VPC must be planned with the input cidr_block (substitute for plan-unknown output.vpc_id)."
  }
}
