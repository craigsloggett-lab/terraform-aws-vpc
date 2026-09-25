################################################################################
# VPC
################################################################################

resource "aws_vpc" "this" {
  cidr_block = var.cidr_block

  # FR-02: DNS resolution and DNS hostnames (provider default for hostnames is
  # false).
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = merge(local.common_tags, {
    Name = var.name
  })

  lifecycle {
    # Cross-tier rules. Every condition references input-derived locals only,
    # so it is evaluated at plan before any resource is created.
    precondition {
      condition     = length(local.all_subnet_cidrs) == length(distinct(local.all_subnet_cidrs))
      error_message = "Subnet CIDR blocks must be unique across all tiers (public, private, database, intra)."
    }

    # Two CIDRs overlap when truncating both to the shorter prefix yields the
    # same network address.
    precondition {
      condition = alltrue(flatten([
        for i, a in distinct(local.all_subnet_cidrs) : [
          for j, b in distinct(local.all_subnet_cidrs) : try(
            cidrhost(format("%s/%d", split("/", a)[0], min(tonumber(split("/", a)[1]), tonumber(split("/", b)[1]))), 0) !=
            cidrhost(format("%s/%d", split("/", b)[0], min(tonumber(split("/", a)[1]), tonumber(split("/", b)[1]))), 0),
            false
          ) if i < j
        ]
      ]))
      error_message = "Subnet CIDR blocks must not overlap across or within tiers."
    }

    precondition {
      condition = var.single_nat_gateway || alltrue([
        for az in local.private_azs : contains(local.public_azs, az)
      ])
      error_message = "With single_nat_gateway = false, every private subnet AZ needs a public subnet in the same AZ to host its NAT gateway."
    }
  }
}

################################################################################
# Default security group
################################################################################

# CIS AWS Foundations v3.0 5.4 / Security Hub EC2.2: adopting the default
# security group with explicit empty rule sets removes every AWS-created rule
# and keeps it closed. Consumers create purpose-built security groups.
resource "aws_default_security_group" "this" {
  vpc_id = aws_vpc.this.id

  ingress = []
  egress  = []

  tags = merge(local.common_tags, {
    Name = "${var.name}-default"
  })
}

################################################################################
# Subnets
################################################################################

# Public tier. Security Hub EC2.15: map_public_ip_on_launch defaults to false;
# NAT gateways and load balancers do not need auto-assigned public IPs.
resource "aws_subnet" "public" {
  for_each = var.public_subnets

  vpc_id                  = aws_vpc.this.id
  cidr_block              = each.value.cidr_block
  availability_zone       = each.value.availability_zone
  map_public_ip_on_launch = var.map_public_ip_on_launch

  tags = merge(
    local.common_tags,
    { Name = "${var.name}-public-${each.key}" },
    each.value.tags,
  )
}

# Non-public tiers hardcode map_public_ip_on_launch = false (Security Hub
# EC2.15): they have no internet gateway route.
resource "aws_subnet" "private" {
  for_each = var.private_subnets

  vpc_id                  = aws_vpc.this.id
  cidr_block              = each.value.cidr_block
  availability_zone       = each.value.availability_zone
  map_public_ip_on_launch = false

  tags = merge(
    local.common_tags,
    { Name = "${var.name}-private-${each.key}" },
    each.value.tags,
  )
}

resource "aws_subnet" "database" {
  for_each = var.database_subnets

  vpc_id                  = aws_vpc.this.id
  cidr_block              = each.value.cidr_block
  availability_zone       = each.value.availability_zone
  map_public_ip_on_launch = false

  tags = merge(
    local.common_tags,
    { Name = "${var.name}-database-${each.key}" },
    each.value.tags,
  )
}

resource "aws_subnet" "intra" {
  for_each = var.intra_subnets

  vpc_id                  = aws_vpc.this.id
  cidr_block              = each.value.cidr_block
  availability_zone       = each.value.availability_zone
  map_public_ip_on_launch = false

  tags = merge(
    local.common_tags,
    { Name = "${var.name}-intra-${each.key}" },
    each.value.tags,
  )
}

################################################################################
# Database subnet group
################################################################################

# RDS requires at least two AZs; enforced by the database_subnets validation.
resource "aws_db_subnet_group" "this" {
  count = var.create_database_subnet_group && length(var.database_subnets) > 0 ? 1 : 0

  name        = lower("${var.name}-database")
  description = "Database subnet group for ${var.name}"
  subnet_ids  = [for s in aws_subnet.database : s.id]

  tags = merge(local.common_tags, {
    Name = lower("${var.name}-database")
  })
}
