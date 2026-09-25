locals {
  # Non-public route table key => route table ID. Keys match
  # local.non_public_route_table_keys exactly ("private-<az>", "database",
  # "intra"); the public route table is never attached to a gateway endpoint.
  non_public_route_table_ids = merge(
    { for az, rt in aws_route_table.private : "private-${az}" => rt.id },
    { for rt in aws_route_table.database : "database" => rt.id },
    { for rt in aws_route_table.intra : "intra" => rt.id },
  )
}

# Gateway endpoints keep S3/DynamoDB traffic on the AWS network. Route tables
# are attached only through aws_vpc_endpoint_route_table_association;
# route_table_ids is intentionally never set (the two conflict).
resource "aws_vpc_endpoint" "gateway" {
  for_each = var.gateway_endpoints

  vpc_id            = aws_vpc.this.id
  vpc_endpoint_type = "Gateway"
  service_name      = "com.amazonaws.${data.aws_region.current.name}.${each.key}"

  tags = merge(local.common_tags, {
    Name = "${var.name}-${each.key}"
  })
}

resource "aws_vpc_endpoint_route_table_association" "gateway" {
  for_each = local.gateway_endpoint_route_tables

  vpc_endpoint_id = aws_vpc_endpoint.gateway[each.value.service].id
  route_table_id  = local.non_public_route_table_ids[each.value.rt_key]
}
