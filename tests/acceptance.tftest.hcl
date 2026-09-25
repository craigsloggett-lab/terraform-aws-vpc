# Generated from specs/003-vpc/design.md Section 5
# Acceptance tests: real provider, command = plan. Requires AWS credentials.
# Not run in the implementation workflow.

provider "aws" {
  region = "us-east-1"
}

# Scenario: "Plan Verification"
# acceptance
run "test_plan_verification" {
  command = plan

  # Full Features inputs without kms_key_id (the key must exist in the account).
  variables {
    name       = "complete"
    cidr_block = "10.0.0.0/16"

    public_subnets = {
      web-a = { cidr_block = "10.0.0.0/24", availability_zone = "us-east-1a", tags = { "kubernetes.io/role/elb" = "1" } }
      web-b = { cidr_block = "10.0.1.0/24", availability_zone = "us-east-1b" }
      web-c = { cidr_block = "10.0.2.0/24", availability_zone = "us-east-1c" }
    }
    private_subnets = {
      app-a = { cidr_block = "10.0.10.0/24", availability_zone = "us-east-1a" }
      app-b = { cidr_block = "10.0.11.0/24", availability_zone = "us-east-1b" }
      app-c = { cidr_block = "10.0.12.0/24", availability_zone = "us-east-1c" }
    }
    database_subnets = {
      db-a = { cidr_block = "10.0.20.0/24", availability_zone = "us-east-1a" }
      db-b = { cidr_block = "10.0.21.0/24", availability_zone = "us-east-1b" }
    }
    intra_subnets = {
      intra-a = { cidr_block = "10.0.30.0/24", availability_zone = "us-east-1a" }
      intra-b = { cidr_block = "10.0.31.0/24", availability_zone = "us-east-1b" }
    }
    gateway_endpoints                 = ["s3", "dynamodb"]
    flow_log_retention_in_days        = 731
    flow_log_max_aggregation_interval = 60
    tags                              = { Environment = "test", Owner = "platform" }
  }

  assert {
    condition     = aws_vpc_endpoint.gateway["s3"].service_name == "com.amazonaws.us-east-1.s3"
    error_message = "S3 endpoint service_name must use the real provider region (us-east-1)."
  }

  assert {
    condition     = jsondecode(data.aws_iam_policy_document.flow_logs_assume[0].json).Statement[0].Principal.Service == "vpc-flow-logs.amazonaws.com"
    error_message = "Rendered trust policy JSON must restrict the principal to vpc-flow-logs.amazonaws.com."
  }

  assert {
    condition     = !contains(flatten([jsondecode(data.aws_iam_policy_document.flow_logs[0].json).Statement[0].Action]), "logs:CreateLogGroup")
    error_message = "Rendered permissions policy JSON must not grant logs:CreateLogGroup."
  }

  assert {
    condition     = contains(flatten([jsondecode(data.aws_iam_policy_document.flow_logs[0].json).Statement[0].Resource]), "arn:aws:logs:us-east-1:${data.aws_caller_identity.current.account_id}:log-group:/aws/vpc-flow-logs/complete")
    error_message = "Rendered permissions policy JSON must be scoped to the module log group ARN in the real account."
  }

  assert {
    condition     = aws_iam_role.flow_logs[0].name == "complete-flow-logs-us-east-1"
    error_message = "Flow log IAM role name must use the real provider region."
  }
}
