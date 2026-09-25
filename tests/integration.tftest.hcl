# Generated from specs/003-vpc/design.md Section 5
# Integration tests: real provider, command = apply. Requires AWS credentials.
# Creates billable NAT gateways and EIPs; not run in the implementation workflow.

provider "aws" {
  region = "us-east-1"
}

# Scenario: "End-to-End"
# integration
run "test_end_to_end" {
  command = apply

  variables {
    name       = "tftest-vpc"
    cidr_block = "10.42.0.0/16"

    public_subnets = {
      web-a = { cidr_block = "10.42.0.0/24", availability_zone = "us-east-1a" }
      web-b = { cidr_block = "10.42.1.0/24", availability_zone = "us-east-1b" }
    }
    private_subnets = {
      app-a = { cidr_block = "10.42.10.0/24", availability_zone = "us-east-1a" }
      app-b = { cidr_block = "10.42.11.0/24", availability_zone = "us-east-1b" }
    }
    database_subnets = {
      db-a = { cidr_block = "10.42.20.0/24", availability_zone = "us-east-1a" }
      db-b = { cidr_block = "10.42.21.0/24", availability_zone = "us-east-1b" }
    }
    intra_subnets = {
      intra-a = { cidr_block = "10.42.30.0/24", availability_zone = "us-east-1a" }
    }
    gateway_endpoints = ["s3"]
  }

  assert {
    condition     = startswith(output.vpc_id, "vpc-")
    error_message = "The VPC must be created with a real vpc- ID."
  }

  assert {
    condition     = length(output.nat_gateway_ids) == 2
    error_message = "One NAT gateway per private-subnet AZ (2) must be created."
  }

  assert {
    condition     = alltrue([for ip in values(output.nat_public_ips) : can(cidrhost("${ip}/32", 0))])
    error_message = "Every NAT gateway must have an allocated public IPv4 address."
  }

  assert {
    condition     = startswith(output.flow_log_id, "fl-")
    error_message = "The VPC flow log must be created with a real fl- ID."
  }

  assert {
    condition     = length(aws_default_security_group.this.ingress) == 0
    error_message = "Default security group must have no ingress rules after apply (CIS 5.4)."
  }

  assert {
    condition     = length(aws_default_security_group.this.egress) == 0
    error_message = "Default security group must have no egress rules after apply (CIS 5.4)."
  }

  assert {
    condition     = startswith(aws_vpc_endpoint.gateway["s3"].prefix_list_id, "pl-")
    error_message = "The S3 gateway endpoint must expose a real pl- prefix list ID."
  }

  assert {
    condition     = output.database_subnet_group_name == "tftest-vpc-database"
    error_message = "The DB subnet group must be created as <name>-database."
  }
}
