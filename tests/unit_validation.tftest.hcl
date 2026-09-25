# Generated from specs/003-vpc/design.md Section 5
# Unit tests: Validation Errors (reject side only; mock provider, command = plan).
# Negative runs live in this file only; accept-side boundaries are in unit_boundaries.tftest.hcl (P7).

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

# Scenario: "Validation Errors - empty name"
run "test_empty_name_rejected" {
  command = plan

  variables {
    name = ""
  }

  expect_failures = [var.name]
}

# Scenario: "Validation Errors - name with invalid characters"
run "test_name_invalid_characters_rejected" {
  command = plan

  variables {
    name = "my_vpc!"
  }

  expect_failures = [var.name]
}

# Scenario: "Validation Errors - name of 33 characters"
run "test_name_too_long_rejected" {
  command = plan

  variables {
    name = "abcdefghijklmnopqrstuvwxyz-123456"
  }

  expect_failures = [var.name]
}

# Scenario: "Validation Errors - malformed VPC CIDR"
run "test_malformed_vpc_cidr_rejected" {
  command = plan

  variables {
    cidr_block = "10.0.0.300/16"
  }

  expect_failures = [var.cidr_block]
}

# Scenario: "Validation Errors - IPv6 VPC CIDR"
run "test_ipv6_vpc_cidr_rejected" {
  command = plan

  variables {
    cidr_block = "2001:db8::/56"
  }

  expect_failures = [var.cidr_block]
}

# Scenario: "Validation Errors - VPC CIDR with host bits set"
run "test_vpc_cidr_host_bits_rejected" {
  command = plan

  variables {
    cidr_block = "10.0.0.1/16"
  }

  expect_failures = [var.cidr_block]
}

# Scenario: "Validation Errors - VPC prefix /15"
run "test_vpc_prefix_15_rejected" {
  command = plan

  variables {
    cidr_block = "10.0.0.0/15"
  }

  expect_failures = [var.cidr_block]
}

# Scenario: "Validation Errors - VPC prefix /29"
run "test_vpc_prefix_29_rejected" {
  command = plan

  variables {
    cidr_block = "10.0.0.0/29"
  }

  expect_failures = [var.cidr_block]
}

# Scenario: "Validation Errors - public subnet outside the VPC"
run "test_public_subnet_outside_vpc_rejected" {
  command = plan

  variables {
    public_subnets = { web-a = { cidr_block = "10.1.0.0/24", availability_zone = "us-east-1a" } }
  }

  expect_failures = [var.public_subnets]
}

# Scenario: "Validation Errors - private subnet CIDR with host bits set"
run "test_private_subnet_host_bits_rejected" {
  command = plan

  variables {
    public_subnets  = { web-a = { cidr_block = "10.0.0.0/24", availability_zone = "us-east-1a" } }
    private_subnets = { app-a = { cidr_block = "10.0.10.1/24", availability_zone = "us-east-1a" } }
  }

  expect_failures = [var.private_subnets]
}

# Scenario: "Validation Errors - database subnet prefix /29"
run "test_database_subnet_prefix_29_rejected" {
  command = plan

  variables {
    database_subnets = {
      db-a = { cidr_block = "10.0.20.0/29", availability_zone = "us-east-1a" }
      db-b = { cidr_block = "10.0.21.0/24", availability_zone = "us-east-1b" }
    }
  }

  expect_failures = [var.database_subnets]
}

# Scenario: "Validation Errors - intra subnet with an AZ ID instead of an AZ name"
run "test_intra_subnet_az_id_rejected" {
  command = plan

  variables {
    intra_subnets = { i = { cidr_block = "10.0.30.0/24", availability_zone = "use1-az1" } }
  }

  expect_failures = [var.intra_subnets]
}

# Scenario: "Validation Errors - private subnets without any public subnet"
run "test_private_without_public_rejected" {
  command = plan

  variables {
    private_subnets = { app-a = { cidr_block = "10.0.10.0/24", availability_zone = "us-east-1a" } }
  }

  expect_failures = [var.private_subnets]
}

# Scenario: "Validation Errors - database subnets in a single AZ with the default subnet group"
run "test_database_single_az_with_subnet_group_rejected" {
  command = plan

  variables {
    database_subnets = {
      db-a = { cidr_block = "10.0.20.0/24", availability_zone = "us-east-1a" }
      db-b = { cidr_block = "10.0.21.0/24", availability_zone = "us-east-1a" }
    }
  }

  expect_failures = [var.database_subnets]
}

# Scenario: "Validation Errors - unsupported gateway endpoint service"
run "test_unsupported_gateway_endpoint_rejected" {
  command = plan

  variables {
    gateway_endpoints = ["s3", "ec2"]
  }

  expect_failures = [var.gateway_endpoints]
}

# Scenario: "Validation Errors - retention 42 not in the allowed set"
run "test_retention_42_rejected" {
  command = plan

  variables {
    flow_log_retention_in_days = 42
  }

  expect_failures = [var.flow_log_retention_in_days]
}

# Scenario: "Validation Errors - negative retention"
run "test_retention_negative_rejected" {
  command = plan

  variables {
    flow_log_retention_in_days = -1
  }

  expect_failures = [var.flow_log_retention_in_days]
}

# Scenario: "Validation Errors - aggregation interval 120"
run "test_aggregation_interval_120_rejected" {
  command = plan

  variables {
    flow_log_max_aggregation_interval = 120
  }

  expect_failures = [var.flow_log_max_aggregation_interval]
}

# Scenario: "Validation Errors - KMS alias instead of key ARN"
run "test_kms_alias_rejected" {
  command = plan

  variables {
    kms_key_id = "alias/my-key"
  }

  expect_failures = [var.kms_key_id]
}

# Scenario: "Validation Errors - bare KMS key ID instead of key ARN"
run "test_kms_bare_key_id_rejected" {
  command = plan

  variables {
    kms_key_id = "1234abcd-12ab-34cd-56ef-1234567890ab"
  }

  expect_failures = [var.kms_key_id]
}

# Scenario: "Validation Errors - reserved aws: tag key prefix"
run "test_reserved_aws_tag_prefix_rejected" {
  command = plan

  variables {
    tags = { "aws:foo" = "bar" }
  }

  expect_failures = [var.tags]
}

# Scenario: "Validation Errors - duplicate CIDR across tiers"
run "test_duplicate_cidr_across_tiers_rejected" {
  command = plan

  variables {
    public_subnets = { web-a = { cidr_block = "10.0.0.0/24", availability_zone = "us-east-1a" } }
    intra_subnets  = { i = { cidr_block = "10.0.0.0/24", availability_zone = "us-east-1a" } }
  }

  expect_failures = [aws_vpc.this]
}

# Scenario: "Validation Errors - overlapping CIDRs"
run "test_overlapping_cidrs_rejected" {
  command = plan

  variables {
    public_subnets = { web-a = { cidr_block = "10.0.0.0/20", availability_zone = "us-east-1a" } }
    intra_subnets  = { i = { cidr_block = "10.0.1.0/24", availability_zone = "us-east-1a" } }
  }

  expect_failures = [aws_vpc.this]
}

# Scenario: "Validation Errors - private AZ without a public subnet in per-AZ NAT mode"
run "test_private_az_without_public_in_per_az_mode_rejected" {
  command = plan

  variables {
    single_nat_gateway = false
    public_subnets     = { web-a = { cidr_block = "10.0.0.0/24", availability_zone = "us-east-1a" } }
    private_subnets    = { app-b = { cidr_block = "10.0.11.0/24", availability_zone = "us-east-1b" } }
  }

  expect_failures = [aws_vpc.this]
}
