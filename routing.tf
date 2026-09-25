# -----------------------------------------------------------------------------
# Internet gateway (only when a public tier exists)
# -----------------------------------------------------------------------------

resource "aws_internet_gateway" "this" {
  count = length(var.public_subnets) > 0 ? 1 : 0

  vpc_id = aws_vpc.this.id

  tags = merge(local.common_tags, {
    Name = var.name
  })
}

# -----------------------------------------------------------------------------
# NAT gateways (keyed by AZ; exist only when private subnets exist)
# -----------------------------------------------------------------------------

resource "aws_eip" "nat" {
  for_each = local.nat_gateways

  # 5.x/6.x-compatible form; never the deprecated `vpc = true`.
  domain = "vpc"

  tags = merge(local.common_tags, {
    Name = "${var.name}-nat-${each.key}"
  })

  # An EIP for a NAT gateway requires the IGW to be attached first.
  depends_on = [aws_internet_gateway.this]
}

resource "aws_nat_gateway" "this" {
  for_each = local.nat_gateways

  connectivity_type = "public"
  allocation_id     = aws_eip.nat[each.key].allocation_id

  # Hosted in the lexically first public subnet key within the AZ.
  subnet_id = aws_subnet.public[each.value.subnet_key].id

  tags = merge(local.common_tags, {
    Name = "${var.name}-nat-${each.key}"
  })

  depends_on = [aws_internet_gateway.this]
}

# -----------------------------------------------------------------------------
# Route tables (no inline route blocks; routes are standalone aws_route)
# -----------------------------------------------------------------------------

resource "aws_route_table" "public" {
  count = length(var.public_subnets) > 0 ? 1 : 0

  vpc_id = aws_vpc.this.id

  tags = merge(local.common_tags, {
    Name = "${var.name}-public"
  })
}

# One private route table per private AZ in both NAT modes, so switching
# single_nat_gateway only updates routes in place.
resource "aws_route_table" "private" {
  for_each = toset(local.private_azs)

  vpc_id = aws_vpc.this.id

  tags = merge(local.common_tags, {
    Name = "${var.name}-private-${each.key}"
  })
}

# Isolated tier: no route beyond `local` (gateway endpoint prefix-list routes
# are managed by AWS through the endpoint associations).
resource "aws_route_table" "database" {
  count = length(var.database_subnets) > 0 ? 1 : 0

  vpc_id = aws_vpc.this.id

  tags = merge(local.common_tags, {
    Name = "${var.name}-database"
  })
}

# Isolated tier: no route beyond `local`.
resource "aws_route_table" "intra" {
  count = length(var.intra_subnets) > 0 ? 1 : 0

  vpc_id = aws_vpc.this.id

  tags = merge(local.common_tags, {
    Name = "${var.name}-intra"
  })
}

# -----------------------------------------------------------------------------
# Routes
# -----------------------------------------------------------------------------

# Only the public tier has an internet gateway route.
resource "aws_route" "public_internet_gateway" {
  count = length(var.public_subnets) > 0 ? 1 : 0

  route_table_id         = aws_route_table.public[0].id
  destination_cidr_block = "0.0.0.0/0"
  gateway_id             = aws_internet_gateway.this[0].id
}

# Private AZ => its own NAT when present, otherwise the single (anchor) NAT.
# Uses nat_gateway_id (gateway_id would cause a perpetual diff).
resource "aws_route" "private_nat_gateway" {
  for_each = local.private_nat_gateway_az

  route_table_id         = aws_route_table.private[each.key].id
  destination_cidr_block = "0.0.0.0/0"
  nat_gateway_id         = aws_nat_gateway.this[each.value].id
}

# -----------------------------------------------------------------------------
# Route table associations (every subnet explicitly associated; none falls
# back to the main route table)
# -----------------------------------------------------------------------------

resource "aws_route_table_association" "public" {
  for_each = var.public_subnets

  subnet_id      = aws_subnet.public[each.key].id
  route_table_id = aws_route_table.public[0].id
}

resource "aws_route_table_association" "private" {
  for_each = var.private_subnets

  subnet_id      = aws_subnet.private[each.key].id
  route_table_id = aws_route_table.private[each.value.availability_zone].id
}

resource "aws_route_table_association" "database" {
  for_each = var.database_subnets

  subnet_id      = aws_subnet.database[each.key].id
  route_table_id = aws_route_table.database[0].id
}

resource "aws_route_table_association" "intra" {
  for_each = var.intra_subnets

  subnet_id      = aws_subnet.intra[each.key].id
  route_table_id = aws_route_table.intra[0].id
}
