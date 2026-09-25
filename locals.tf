locals {
  # ---------------------------------------------------------------------------
  # Tags
  # ---------------------------------------------------------------------------

  # Consumer tags override ManagedBy. Each resource merges its own Name on top.
  common_tags = merge({ ManagedBy = "terraform" }, var.tags)

  # ---------------------------------------------------------------------------
  # Availability zones (input-derived only, so every key is known at plan)
  # ---------------------------------------------------------------------------

  public_azs   = sort(distinct([for s in values(var.public_subnets) : s.availability_zone]))
  private_azs  = sort(distinct([for s in values(var.private_subnets) : s.availability_zone]))
  database_azs = sort(distinct([for s in values(var.database_subnets) : s.availability_zone]))
  intra_azs    = sort(distinct([for s in values(var.intra_subnets) : s.availability_zone]))

  # Sorted union of every AZ used by any subnet tier.
  azs = sort(distinct(concat(local.public_azs, local.private_azs, local.database_azs, local.intra_azs)))

  # Every subnet CIDR across all tiers, used by the duplicate and overlap
  # preconditions on aws_vpc.this.
  all_subnet_cidrs = concat(
    [for s in values(var.public_subnets) : s.cidr_block],
    [for s in values(var.private_subnets) : s.cidr_block],
    [for s in values(var.database_subnets) : s.cidr_block],
    [for s in values(var.intra_subnets) : s.cidr_block],
  )

  # ---------------------------------------------------------------------------
  # NAT gateways (keyed by AZ name)
  # ---------------------------------------------------------------------------

  # AZ => lexically first public subnet key in that AZ (the NAT host subnet).
  public_subnet_key_by_az = {
    for az in local.public_azs :
    az => sort([for k, s in var.public_subnets : k if s.availability_zone == az])[0]
  }

  # NAT exists only when private subnets exist. Per-AZ mode places one NAT in
  # each private AZ that has a public subnet (AZs without one are filtered out
  # here and rejected by the precondition on aws_vpc.this). Single mode places
  # one NAT in the first sorted public AZ. Every [0] is guarded against empty
  # lists so invalid combinations never surface as index or lookup errors.
  nat_gateway_azs = (
    length(var.private_subnets) == 0 || length(local.public_azs) == 0 ? [] :
    var.single_nat_gateway ? [local.public_azs[0]] :
    [for az in local.private_azs : az if contains(local.public_azs, az)]
  )

  # for_each map for aws_eip.nat and aws_nat_gateway.this.
  nat_gateways = {
    for az in local.nat_gateway_azs : az => {
      subnet_key = local.public_subnet_key_by_az[az]
    }
  }

  # Private AZ => AZ key of the NAT it routes through: its own AZ's NAT when
  # one exists, otherwise the single (anchor) NAT. Empty when there is no NAT.
  private_nat_gateway_az = length(local.nat_gateway_azs) == 0 ? {} : {
    for az in local.private_azs :
    az => contains(local.nat_gateway_azs, az) ? az : local.nat_gateway_azs[0]
  }

  # ---------------------------------------------------------------------------
  # Flow logs
  # ---------------------------------------------------------------------------

  # Deterministic so consumers can write the KMS key policy before apply.
  flow_log_group_name = "/aws/vpc-flow-logs/${var.name}"

  # Built from data sources rather than the log group resource so the IAM
  # policy document is fully known at plan time.
  flow_log_group_arn = format(
    "arn:%s:logs:%s:%s:log-group:%s",
    data.aws_partition.current.partition,
    data.aws_region.current.region,
    data.aws_caller_identity.current.account_id,
    local.flow_log_group_name,
  )

  # ---------------------------------------------------------------------------
  # Gateway endpoints
  # ---------------------------------------------------------------------------

  # Non-public route table keys, derived from inputs only (never resource IDs).
  # The public route table is never attached to a gateway endpoint.
  non_public_route_table_keys = concat(
    [for az in local.private_azs : "private-${az}"],
    length(var.database_subnets) > 0 ? ["database"] : [],
    length(var.intra_subnets) > 0 ? ["intra"] : [],
  )

  # "<svc>/<rt-key>" => { service, rt_key } for
  # aws_vpc_endpoint_route_table_association.gateway.
  gateway_endpoint_route_tables = {
    for pair in setproduct(sort(tolist(var.gateway_endpoints)), local.non_public_route_table_keys) :
    "${pair[0]}/${pair[1]}" => {
      service = pair[0]
      rt_key  = pair[1]
    }
  }

  # NOTE: non_public_route_table_ids (rt-key => route table ID) references
  # aws_route_table.private / .database / .intra and is defined in
  # endpoints.tf next to its only consumer.
}
