# Generated from specs/003-vpc/design.md Section 5
# Unit tests: Full Features (mock provider, command = plan, no credentials)

mock_provider "aws" {
  mock_data "aws_iam_policy_document" {
    defaults = { json = "{\"Version\":\"2012-10-17\",\"Statement\":[]}" } # must be valid JSON (P1)
  }
  mock_data "aws_region" {
    defaults = { name = "us-east-1" } # 5.x attribute
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

# Scenario: "Full Features (complete)"
run "test_full_features" {
  command = plan

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
    kms_key_id                        = "arn:aws:kms:us-east-1:123456789012:key/1234abcd-12ab-34cd-56ef-1234567890ab"
    tags                              = { Environment = "test", Owner = "platform" }
  }

  # 1
  assert {
    condition     = length(aws_subnet.public) == 3
    error_message = "Expected three public subnets, one per public_subnets entry."
  }

  # 2
  assert {
    condition     = keys(aws_subnet.private) == ["app-a", "app-b", "app-c"]
    error_message = "Private subnet instance keys must mirror the private_subnets input keys (NFR-03)."
  }

  # 3
  assert {
    condition     = length(aws_subnet.database) == 2
    error_message = "Expected two database subnets, one per database_subnets entry."
  }

  # 4
  assert {
    condition     = length(aws_subnet.intra) == 2
    error_message = "Expected two intra subnets, one per intra_subnets entry."
  }

  # 5
  assert {
    condition     = aws_subnet.public["web-b"].cidr_block == "10.0.1.0/24"
    error_message = "Public subnet web-b cidr_block must come from its input entry (10.0.1.0/24)."
  }

  # 6
  assert {
    condition     = aws_subnet.private["app-c"].availability_zone == "us-east-1c"
    error_message = "Private subnet app-c availability_zone must come from its input entry (us-east-1c)."
  }

  # 7
  assert {
    condition     = alltrue([for s in aws_subnet.public : s.map_public_ip_on_launch == false])
    error_message = "Public subnets must not auto-assign public IPs by default (Security Hub EC2.15)."
  }

  # 8
  assert {
    condition     = alltrue([for s in aws_subnet.private : s.map_public_ip_on_launch == false])
    error_message = "Private subnets must never auto-assign public IPs."
  }

  # 9
  assert {
    condition     = aws_subnet.public["web-a"].tags["kubernetes.io/role/elb"] == "1"
    error_message = "Per-subnet tags from the input entry must be applied to the subnet."
  }

  # 10
  assert {
    condition     = aws_subnet.private["app-b"].tags["Name"] == "complete-private-app-b"
    error_message = "Subnet Name tag must follow <name>-<tier>-<key>."
  }

  # 11
  assert {
    condition     = aws_subnet.database["db-a"].tags["Environment"] == "test"
    error_message = "Consumer tags (var.tags) must propagate to subnets."
  }

  # 12
  assert {
    condition     = aws_vpc.this.tags["Owner"] == "platform"
    error_message = "Consumer tags (var.tags) must propagate to the VPC."
  }

  # 13
  assert {
    condition     = length(aws_internet_gateway.this) == 1
    error_message = "An internet gateway must be created when public subnets are declared."
  }

  # 14
  assert {
    condition     = aws_route.public_internet_gateway[0].destination_cidr_block == "0.0.0.0/0"
    error_message = "The public route table must have a 0.0.0.0/0 default route to the internet gateway."
  }

  # 15
  assert {
    condition     = toset(keys(aws_nat_gateway.this)) == toset(["us-east-1a", "us-east-1b", "us-east-1c"])
    error_message = "Expected one NAT gateway per private-subnet AZ, keyed by AZ name (NFR-02)."
  }

  # 16
  assert {
    condition     = aws_nat_gateway.this["us-east-1a"].connectivity_type == "public"
    error_message = "NAT gateways must use public connectivity."
  }

  # 17
  assert {
    condition     = alltrue([for e in aws_eip.nat : e.domain == "vpc"])
    error_message = "NAT Elastic IPs must use domain = \"vpc\" (never the removed vpc = true argument)."
  }

  # 18
  assert {
    condition     = toset(keys(aws_eip.nat)) == toset(keys(aws_nat_gateway.this))
    error_message = "There must be exactly one Elastic IP per NAT gateway, keyed by the same AZ."
  }

  # 19
  assert {
    condition     = keys(aws_route_table.private) == ["us-east-1a", "us-east-1b", "us-east-1c"]
    error_message = "Expected one private route table per private-subnet AZ, keyed by AZ name."
  }

  # 20
  assert {
    condition     = length(aws_route.private_nat_gateway) == 3
    error_message = "Expected one NAT default route per private AZ."
  }

  # 21
  assert {
    condition     = aws_route.private_nat_gateway["us-east-1b"].destination_cidr_block == "0.0.0.0/0"
    error_message = "Private route tables must default-route 0.0.0.0/0 to NAT."
  }

  # 22 [plan-unknown] aws_route.private_nat_gateway["us-east-1b"].nat_gateway_id
  # No substitute assertion: wiring is proven in Feature Interactions sub-scenario 2
  # (tests/unit_edge_cases.tftest.hcl, run "test_per_az_nat_placement_and_az_scoped_association").

  # 23
  assert {
    condition     = length(aws_route_table.database) == 1
    error_message = "Expected a single database route table."
  }

  # 24
  assert {
    condition     = length(aws_route_table.intra) == 1
    error_message = "Expected a single intra route table."
  }

  # 25
  assert {
    condition     = length(aws_route.public_internet_gateway) + length(aws_route.private_nat_gateway) == 4
    error_message = "Only 1 public and 3 private default routes may exist; database and intra tiers must have no default route (FR-06)."
  }

  # 26
  assert {
    condition     = length(aws_route_table_association.public) == 3
    error_message = "Every public subnet must be explicitly associated with the public route table."
  }

  # 27
  assert {
    condition     = keys(aws_route_table_association.private) == ["app-a", "app-b", "app-c"]
    error_message = "Every private subnet must be explicitly associated, keyed by subnet name."
  }

  # 28
  assert {
    condition     = length(aws_route_table_association.database) == 2
    error_message = "Every database subnet must be explicitly associated with the database route table."
  }

  # 29
  assert {
    condition     = length(aws_route_table_association.intra) == 2
    error_message = "Every intra subnet must be explicitly associated with the intra route table."
  }

  # 30
  assert {
    condition     = toset(keys(aws_vpc_endpoint.gateway)) == toset(["s3", "dynamodb"])
    error_message = "Both S3 and DynamoDB gateway endpoints must be created, keyed by service."
  }

  # 31
  assert {
    condition     = aws_vpc_endpoint.gateway["s3"].service_name == "com.amazonaws.us-east-1.s3"
    error_message = "S3 endpoint service_name must be built from the current region (com.amazonaws.<region>.s3)."
  }

  # 32
  assert {
    condition     = aws_vpc_endpoint.gateway["dynamodb"].vpc_endpoint_type == "Gateway"
    error_message = "Endpoints must be of type Gateway."
  }

  # 33
  assert {
    condition     = toset(keys(aws_vpc_endpoint_route_table_association.gateway)) == toset(["s3/private-us-east-1a", "s3/private-us-east-1b", "s3/private-us-east-1c", "s3/database", "s3/intra", "dynamodb/private-us-east-1a", "dynamodb/private-us-east-1b", "dynamodb/private-us-east-1c", "dynamodb/database", "dynamodb/intra"])
    error_message = "Each gateway endpoint must be associated with all five non-public route tables, keyed <svc>/<rt-key>."
  }

  # 34
  assert {
    condition     = length([for k in keys(aws_vpc_endpoint_route_table_association.gateway) : k if endswith(k, "/public")]) == 0
    error_message = "The public route table must never be associated with a gateway endpoint."
  }

  # 35
  assert {
    condition     = aws_db_subnet_group.this[0].name == "complete-database"
    error_message = "DB subnet group name must be lower(\"<name>-database\")."
  }

  # 36 [plan-unknown] aws_db_subnet_group.this[0].subnet_ids -> substitute: group exists
  assert {
    condition     = length(aws_db_subnet_group.this) == 1
    error_message = "A DB subnet group must be created when database subnets span at least 2 AZs."
  }

  # 37
  assert {
    condition     = aws_cloudwatch_log_group.flow_logs[0].kms_key_id == "arn:aws:kms:us-east-1:123456789012:key/1234abcd-12ab-34cd-56ef-1234567890ab"
    error_message = "The customer-managed KMS key ARN must be applied to the flow log group."
  }

  # 38
  assert {
    condition     = aws_cloudwatch_log_group.flow_logs[0].retention_in_days == 731
    error_message = "Flow log group retention must use flow_log_retention_in_days (731)."
  }

  # 39
  assert {
    condition     = aws_flow_log.this[0].max_aggregation_interval == 60
    error_message = "Flow log max_aggregation_interval must use flow_log_max_aggregation_interval (60)."
  }

  # 40
  assert {
    condition     = aws_flow_log.this[0].traffic_type == "ALL"
    error_message = "Flow log must still capture ALL traffic with every feature enabled."
  }

  # 41
  assert {
    condition     = length(aws_default_security_group.this.ingress) == 0
    error_message = "Default security group must stay closed (no ingress) with every feature enabled."
  }

  # 42
  assert {
    condition     = output.azs == ["us-east-1a", "us-east-1b", "us-east-1c"]
    error_message = "Output azs must be the sorted, distinct AZs used by any subnet."
  }

  # 43
  assert {
    condition     = keys(output.private_subnet_ids) == ["app-a", "app-b", "app-c"]
    error_message = "Output private_subnet_ids must be keyed by subnet name."
  }

  # 44
  assert {
    condition     = output.public_subnet_cidr_blocks["web-b"] == "10.0.1.0/24"
    error_message = "Output public_subnet_cidr_blocks must map subnet name to its CIDR block."
  }

  # 45
  assert {
    condition     = toset(keys(output.nat_gateway_ids)) == toset(["us-east-1a", "us-east-1b", "us-east-1c"])
    error_message = "Output nat_gateway_ids must be keyed by AZ."
  }

  # 46 (values are [plan-unknown]; keys/length only)
  assert {
    condition     = length(output.nat_public_ips) == 3
    error_message = "Output nat_public_ips must have one entry per NAT gateway AZ."
  }

  # 47
  assert {
    condition     = keys(output.private_route_table_ids) == ["us-east-1a", "us-east-1b", "us-east-1c"]
    error_message = "Output private_route_table_ids must be keyed by AZ."
  }

  # 48
  assert {
    condition     = keys(output.gateway_endpoint_ids) == ["dynamodb", "s3"]
    error_message = "Output gateway_endpoint_ids must be keyed by service name."
  }

  # 49
  assert {
    condition     = output.database_subnet_group_name == "complete-database"
    error_message = "Output database_subnet_group_name must be the DB subnet group name."
  }

  # 50 [plan-unknown] output.flow_log_iam_role_arn -> substitute: role exists
  assert {
    condition     = length(aws_iam_role.flow_logs) == 1
    error_message = "The flow log IAM role must be created when flow logs are enabled."
  }
}
