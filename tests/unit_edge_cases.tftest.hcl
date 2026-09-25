# Generated from specs/003-vpc/design.md Section 5
# Unit tests: Feature Interactions (mock provider, command = plan, no credentials)

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

# Scenario: "Feature Interactions - Sub-scenario 1: single NAT serves an AZ without a public subnet"
run "test_single_nat_serves_az_without_public_subnet" {
  command = plan

  variables {
    single_nat_gateway = true
    public_subnets     = { web-a = { cidr_block = "10.0.0.0/24", availability_zone = "us-east-1a" } }
    private_subnets = {
      app-a = { cidr_block = "10.0.10.0/24", availability_zone = "us-east-1a" }
      app-b = { cidr_block = "10.0.11.0/24", availability_zone = "us-east-1b" }
    }
  }

  # Plan-known NAT ID so route wiring can be asserted (P3/P6)
  override_resource {
    target          = aws_nat_gateway.this["us-east-1a"]
    override_during = plan
    values = {
      id = "nat-0anchor"
    }
  }

  assert {
    condition     = keys(aws_nat_gateway.this) == ["us-east-1a"]
    error_message = "single_nat_gateway must create exactly one NAT, keyed by the first sorted public AZ (us-east-1a)."
  }

  assert {
    condition     = length(aws_eip.nat) == 1
    error_message = "single_nat_gateway must allocate exactly one Elastic IP."
  }

  assert {
    condition     = keys(aws_route_table.private) == ["us-east-1a", "us-east-1b"]
    error_message = "Private route tables must remain one per private AZ in single-NAT mode (no churn on mode switch)."
  }

  assert {
    condition     = aws_route.private_nat_gateway["us-east-1b"].nat_gateway_id == "nat-0anchor"
    error_message = "A private AZ without its own NAT must route to the single anchor NAT."
  }

  assert {
    condition     = aws_route.private_nat_gateway["us-east-1a"].nat_gateway_id == "nat-0anchor"
    error_message = "The anchor AZ must route to the anchor NAT."
  }
}

# Scenario: "Feature Interactions - Sub-scenario 2: per-AZ NAT placement, lexical host selection, and AZ-scoped association"
run "test_per_az_nat_placement_and_az_scoped_association" {
  command = plan

  variables {
    public_subnets = {
      web-a   = { cidr_block = "10.0.0.0/24", availability_zone = "us-east-1a" }
      alpha-a = { cidr_block = "10.0.3.0/24", availability_zone = "us-east-1a" }
      web-b   = { cidr_block = "10.0.1.0/24", availability_zone = "us-east-1b" }
      web-c   = { cidr_block = "10.0.2.0/24", availability_zone = "us-east-1c" }
    }
    private_subnets = {
      app-a = { cidr_block = "10.0.10.0/24", availability_zone = "us-east-1a" }
      app-b = { cidr_block = "10.0.11.0/24", availability_zone = "us-east-1b" }
    }
  }

  # Distinct plan-known IDs per instance (P3/P6)
  override_resource {
    target          = aws_subnet.public["alpha-a"]
    override_during = plan
    values = {
      id = "subnet-0alpha"
    }
  }

  override_resource {
    target          = aws_subnet.public["web-b"]
    override_during = plan
    values = {
      id = "subnet-0webb"
    }
  }

  override_resource {
    target          = aws_route_table.private["us-east-1b"]
    override_during = plan
    values = {
      id = "rtb-0privb"
    }
  }

  override_resource {
    target          = aws_nat_gateway.this["us-east-1b"]
    override_during = plan
    values = {
      id = "nat-0b"
    }
  }

  assert {
    condition     = keys(aws_nat_gateway.this) == ["us-east-1a", "us-east-1b"]
    error_message = "NAT gateways must exist only in AZs that have private subnets (not us-east-1c)."
  }

  assert {
    condition     = aws_nat_gateway.this["us-east-1a"].subnet_id == "subnet-0alpha"
    error_message = "The NAT in us-east-1a must sit in the public subnet whose key sorts first in that AZ (alpha-a)."
  }

  assert {
    condition     = aws_nat_gateway.this["us-east-1b"].subnet_id == "subnet-0webb"
    error_message = "The NAT in us-east-1b must sit in public subnet web-b."
  }

  assert {
    condition     = aws_route_table_association.private["app-b"].route_table_id == "rtb-0privb"
    error_message = "Private subnet app-b must be associated with the private route table of its own AZ (us-east-1b)."
  }

  assert {
    condition     = aws_route.private_nat_gateway["us-east-1b"].nat_gateway_id == "nat-0b"
    error_message = "Private AZ us-east-1b must route to its own-AZ NAT gateway in per-AZ mode."
  }
}

# Scenario: "Feature Interactions - Sub-scenario 3: public-only VPC with an endpoint requested and a null map"
run "test_public_only_vpc_with_endpoint_and_null_map" {
  command = plan

  variables {
    public_subnets    = { web-a = { cidr_block = "10.0.0.0/24", availability_zone = "us-east-1a" } }
    intra_subnets     = null
    gateway_endpoints = ["s3"]
  }

  assert {
    condition     = length(aws_internet_gateway.this) == 1
    error_message = "An internet gateway must be created when public subnets are declared."
  }

  assert {
    condition     = length(aws_route_table.public) == 1
    error_message = "A public route table must be created when public subnets are declared."
  }

  assert {
    condition     = length(aws_nat_gateway.this) == 0
    error_message = "No NAT gateway may be created without private subnets."
  }

  assert {
    condition     = length(aws_route_table.private) == 0
    error_message = "No private route tables may be created without private subnets."
  }

  assert {
    condition     = length(aws_subnet.intra) == 0
    error_message = "nullable = false must turn intra_subnets = null into an empty map."
  }

  assert {
    condition     = length(aws_vpc_endpoint.gateway) == 1
    error_message = "The requested S3 gateway endpoint must be created even in a public-only VPC."
  }

  assert {
    condition     = length(aws_vpc_endpoint_route_table_association.gateway) == 0
    error_message = "The endpoint must have no route table associations, because only non-public route tables are eligible."
  }
}

# Scenario: "Feature Interactions - Sub-scenario 4: flow logs disabled suppresses every flow log object, even with KMS and retention set"
run "test_flow_logs_disabled_suppresses_all_flow_log_objects" {
  command = plan

  variables {
    enable_flow_logs           = false
    kms_key_id                 = "arn:aws:kms:us-east-1:123456789012:key/1234abcd-12ab-34cd-56ef-1234567890ab"
    flow_log_retention_in_days = 30
  }

  assert {
    condition     = length(aws_flow_log.this) == 0
    error_message = "No flow log may be created when enable_flow_logs = false."
  }

  assert {
    condition     = length(aws_cloudwatch_log_group.flow_logs) == 0
    error_message = "No flow log group may be created when enable_flow_logs = false, even with kms_key_id and retention set."
  }

  assert {
    condition     = length(aws_iam_role.flow_logs) == 0
    error_message = "No flow log IAM role may be created when enable_flow_logs = false."
  }

  assert {
    condition     = length(aws_iam_role_policy.flow_logs) == 0
    error_message = "No flow log IAM role policy may be created when enable_flow_logs = false."
  }

  assert {
    condition     = length(data.aws_iam_policy_document.flow_logs) == 0
    error_message = "No flow log policy documents may be evaluated when enable_flow_logs = false."
  }

  assert {
    condition     = output.flow_log_id == null
    error_message = "Output flow_log_id must be null when flow logs are disabled."
  }

  assert {
    condition     = output.flow_log_cloudwatch_log_group_name == null
    error_message = "Output flow_log_cloudwatch_log_group_name must be null when flow logs are disabled."
  }

  assert {
    condition     = output.flow_log_iam_role_arn == null
    error_message = "Output flow_log_iam_role_arn must be null when flow logs are disabled."
  }

  assert {
    condition     = length(aws_default_security_group.this.egress) == 0
    error_message = "Default security group must still be managed and closed (no egress) when flow logs are disabled."
  }
}

# Scenario: "Feature Interactions - Sub-scenario 5: single-AZ database tier without a subnet group, with the DynamoDB endpoint"
run "test_single_az_database_without_subnet_group_with_dynamodb_endpoint" {
  command = plan

  variables {
    create_database_subnet_group = false
    database_subnets             = { db-a = { cidr_block = "10.0.20.0/24", availability_zone = "us-east-1a" } }
    gateway_endpoints            = ["dynamodb"]
  }

  assert {
    condition     = length(aws_db_subnet_group.this) == 0
    error_message = "No DB subnet group may be created when create_database_subnet_group = false."
  }

  assert {
    condition     = length(aws_route_table.database) == 1
    error_message = "The database route table must still be created when database subnets exist."
  }

  assert {
    condition     = keys(aws_route_table_association.database) == ["db-a"]
    error_message = "The database subnet db-a must be explicitly associated with the database route table."
  }

  assert {
    condition     = keys(aws_vpc_endpoint_route_table_association.gateway) == ["dynamodb/database"]
    error_message = "The DynamoDB endpoint must be attached to the database route table only."
  }

  assert {
    condition     = length(aws_internet_gateway.this) == 0
    error_message = "No internet gateway may be created for a database-only VPC."
  }

  assert {
    condition     = output.database_subnet_group_name == null
    error_message = "Output database_subnet_group_name must be null when no DB subnet group is created."
  }
}

# Scenario: "Feature Interactions - Sub-scenario 6: tag precedence"
run "test_tag_precedence" {
  command = plan

  variables {
    tags           = { ManagedBy = "custom-pipeline", Name = "ignored", Team = "net" }
    public_subnets = { web-a = { cidr_block = "10.0.0.0/24", availability_zone = "us-east-1a", tags = { Name = "custom-web-a" } } }
  }

  assert {
    condition     = aws_vpc.this.tags["ManagedBy"] == "custom-pipeline"
    error_message = "Consumer tags must override the module ManagedBy default."
  }

  assert {
    condition     = aws_vpc.this.tags["Name"] == "test"
    error_message = "The per-resource Name must beat a Name supplied in var.tags."
  }

  assert {
    condition     = aws_route_table.public[0].tags["Name"] == "test-public"
    error_message = "The public route table must keep its per-resource Name (<name>-public) over var.tags Name."
  }

  assert {
    condition     = aws_subnet.public["web-a"].tags["Name"] == "custom-web-a"
    error_message = "Per-subnet tags must override Name on that subnet."
  }

  assert {
    condition     = aws_cloudwatch_log_group.flow_logs[0].tags["Team"] == "net"
    error_message = "Consumer tags must reach the flow log group."
  }
}
