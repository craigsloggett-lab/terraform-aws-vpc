# Generated from specs/003-vpc/design.md Section 5
# Unit tests: Validation Boundaries (accept side only; mock provider, command = plan).
# Kept separate from unit_validation.tftest.hcl so that negative runs cannot mask these (P7).

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

# --- Boundary-pass cases ---

# Scenario: "Validation Boundaries - name minimum length 1"
run "test_name_minimum_length_accepted" {
  command = plan

  variables {
    name = "a"
  }

  assert {
    condition     = aws_vpc.this.tags["Name"] == "a"
    error_message = "A 1-character name (minimum length) must be accepted."
  }
}

# Scenario: "Validation Boundaries - name maximum length 32"
run "test_name_maximum_length_accepted" {
  command = plan

  variables {
    name = "abcdefghijklmnopqrstuvwxyz-12345"
  }

  assert {
    condition     = aws_iam_role.flow_logs[0].name == "abcdefghijklmnopqrstuvwxyz-12345-flow-logs-us-east-1"
    error_message = "A 32-character name (maximum length) must be accepted and keep the derived role name within 64 characters."
  }
}

# Scenario: "Validation Boundaries - VPC /28 with an intra subnet equal to the VPC CIDR"
run "test_vpc_prefix_28_with_subnet_equal_to_vpc_accepted" {
  command = plan

  variables {
    cidr_block    = "10.0.0.0/28"
    intra_subnets = { only = { cidr_block = "10.0.0.0/28", availability_zone = "us-east-1a" } }
  }

  assert {
    condition     = aws_subnet.intra["only"].cidr_block == "10.0.0.0/28"
    error_message = "A /28 VPC (largest allowed prefix) with a subnet equal to the VPC CIDR must be accepted as contained."
  }
}

# Scenario: "Validation Boundaries - subnet prefix /16 (smallest allowed)"
run "test_subnet_prefix_16_accepted" {
  command = plan

  variables {
    cidr_block    = "10.0.0.0/16"
    intra_subnets = { whole = { cidr_block = "10.0.0.0/16", availability_zone = "us-east-1a" } }
  }

  assert {
    condition     = aws_subnet.intra["whole"].cidr_block == "10.0.0.0/16"
    error_message = "A /16 subnet (smallest allowed subnet prefix) equal to the VPC CIDR must be accepted."
  }
}

# Scenario: "Validation Boundaries - last /28 block inside the VPC"
run "test_last_block_inside_vpc_accepted" {
  command = plan

  variables {
    intra_subnets = { last = { cidr_block = "10.0.255.240/28", availability_zone = "us-east-1a" } }
  }

  assert {
    condition     = aws_subnet.intra["last"].cidr_block == "10.0.255.240/28"
    error_message = "The last /28 block inside the VPC (10.0.255.240/28) must be accepted as contained."
  }
}

# Scenario: "Validation Boundaries - adjacent blocks do not overlap"
run "test_adjacent_blocks_accepted" {
  command = plan

  variables {
    intra_subnets = {
      lo = { cidr_block = "10.0.0.0/25", availability_zone = "us-east-1a" }
      hi = { cidr_block = "10.0.0.128/25", availability_zone = "us-east-1a" }
    }
  }

  assert {
    condition     = length(aws_subnet.intra) == 2
    error_message = "Adjacent /25 blocks must not be treated as overlapping."
  }
}

# Scenario: "Validation Boundaries - multi-segment region AZ name"
run "test_multi_segment_az_name_accepted" {
  command = plan

  variables {
    intra_subnets = { gov = { cidr_block = "10.0.0.0/24", availability_zone = "us-gov-west-1a" } }
  }

  assert {
    condition     = aws_subnet.intra["gov"].availability_zone == "us-gov-west-1a"
    error_message = "A multi-segment region AZ name (us-gov-west-1a) must be accepted."
  }
}

# Scenario: "Validation Boundaries - database subnets in exactly 2 AZs with the default subnet group"
run "test_database_exactly_two_azs_accepted" {
  command = plan

  variables {
    database_subnets = {
      db-a = { cidr_block = "10.0.20.0/24", availability_zone = "us-east-1a" }
      db-b = { cidr_block = "10.0.21.0/24", availability_zone = "us-east-1b" }
    }
  }

  assert {
    condition     = length(aws_db_subnet_group.this) == 1
    error_message = "Database subnets in exactly 2 AZs must be accepted and produce the default DB subnet group."
  }
}

# Scenario: "Validation Boundaries - private subnets with exactly 1 public subnet in the same AZ"
run "test_private_with_exactly_one_public_accepted" {
  command = plan

  variables {
    public_subnets  = { web-a = { cidr_block = "10.0.0.0/24", availability_zone = "us-east-1a" } }
    private_subnets = { app-a = { cidr_block = "10.0.10.0/24", availability_zone = "us-east-1a" } }
  }

  assert {
    condition     = length(aws_nat_gateway.this) == 1
    error_message = "Private subnets with exactly one public subnet in the same AZ must be accepted and get one NAT."
  }
}

# Scenario: "Validation Boundaries - single allowed gateway endpoint"
run "test_single_gateway_endpoint_accepted" {
  command = plan

  variables {
    gateway_endpoints = ["dynamodb"]
  }

  assert {
    condition     = keys(aws_vpc_endpoint.gateway) == ["dynamodb"]
    error_message = "gateway_endpoints = [\"dynamodb\"] (single allowed value) must be accepted."
  }
}

# Scenario: "Validation Boundaries - retention 0 (never expire)"
run "test_retention_zero_accepted" {
  command = plan

  variables {
    flow_log_retention_in_days = 0
  }

  assert {
    condition     = aws_cloudwatch_log_group.flow_logs[0].retention_in_days == 0
    error_message = "flow_log_retention_in_days = 0 (never expire, lowest allowed) must be accepted."
  }
}

# Scenario: "Validation Boundaries - retention 1 (lowest finite)"
run "test_retention_one_accepted" {
  command = plan

  variables {
    flow_log_retention_in_days = 1
  }

  assert {
    condition     = aws_cloudwatch_log_group.flow_logs[0].retention_in_days == 1
    error_message = "flow_log_retention_in_days = 1 (lowest finite value) must be accepted."
  }
}

# Scenario: "Validation Boundaries - retention 3653 (highest allowed)"
run "test_retention_3653_accepted" {
  command = plan

  variables {
    flow_log_retention_in_days = 3653
  }

  assert {
    condition     = aws_cloudwatch_log_group.flow_logs[0].retention_in_days == 3653
    error_message = "flow_log_retention_in_days = 3653 (highest allowed) must be accepted."
  }
}

# Scenario: "Validation Boundaries - aggregation interval 60"
run "test_aggregation_interval_60_accepted" {
  command = plan

  variables {
    flow_log_max_aggregation_interval = 60
  }

  assert {
    condition     = aws_flow_log.this[0].max_aggregation_interval == 60
    error_message = "flow_log_max_aggregation_interval = 60 (lower allowed value) must be accepted."
  }
}

# Scenario: "Validation Boundaries - KMS key ARN in a non-commercial partition"
run "test_kms_key_non_commercial_partition_accepted" {
  command = plan

  variables {
    kms_key_id = "arn:aws-us-gov:kms:us-gov-west-1:123456789012:key/1234abcd-12ab-34cd-56ef-1234567890ab"
  }

  assert {
    condition     = aws_cloudwatch_log_group.flow_logs[0].kms_key_id == "arn:aws-us-gov:kms:us-gov-west-1:123456789012:key/1234abcd-12ab-34cd-56ef-1234567890ab"
    error_message = "A KMS key ARN in a non-commercial partition (aws-us-gov) must be accepted and applied."
  }
}

# Scenario: "Validation Boundaries - tag key containing aws: but not as a prefix"
run "test_tag_key_with_non_prefix_aws_accepted" {
  command = plan

  variables {
    tags = { "myaws:key" = "v" }
  }

  assert {
    condition     = aws_vpc.this.tags["myaws:key"] == "v"
    error_message = "A tag key containing aws: but not as a prefix (myaws:key) must be accepted."
  }
}

# Scenario: "Validation Boundaries - map_public_ip_on_launch explicit opt-in"
run "test_map_public_ip_on_launch_opt_in_accepted" {
  command = plan

  variables {
    map_public_ip_on_launch = true
    public_subnets          = { web-a = { cidr_block = "10.0.0.0/24", availability_zone = "us-east-1a" } }
  }

  assert {
    condition     = aws_subnet.public["web-a"].map_public_ip_on_launch == true
    error_message = "map_public_ip_on_launch = true (explicit opt-in) must be applied to public subnets."
  }
}
