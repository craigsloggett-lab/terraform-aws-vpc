## Research: How do public registry VPC modules structure NAT placement, route tables, and gateway endpoints, and how should we adapt this to a for_each/map design?

### Decision

Key every "per-AZ" resource (EIP, NAT gateway, private route table, private NAT route) by **AZ name**, and every subnet resource and subnet association by the **subnet's short name**. Work out all keys in `locals.tf` from the input maps only. That way plans never depend on unknown values, and switching `single_nat_gateway` only adds or removes NATs in other AZs; the anchor NAT is never replaced. Public, database and intra tiers each get **one shared route table**. Private gets **one route table per AZ, always**, even when there is a single NAT. Gateway endpoints attach through `aws_vpc_endpoint_route_table_association`, whose `for_each` keys are fixed strings (`"<service>/<rt-key>"`).

### Resources Identified

- **Primary Resource**: `aws_nat_gateway` (plus `aws_route_table`) — egress placement and routing topology
- **Supporting Resources**:
  - `aws_eip` — one per NAT, keyed by AZ (`domain = "vpc"`)
  - `aws_route_table` `public` (singleton), `private` (for_each AZ), `database` (singleton), `intra` (singleton)
  - `aws_route` — `public_internet_gateway` (0.0.0.0/0 to IGW) and `private_nat_gateway` (for_each private AZ, 0.0.0.0/0 to that AZ's NAT)
  - `aws_route_table_association` — one per subnet, one resource per tier, keyed by subnet name
  - `aws_vpc_endpoint` — Gateway type (`s3`, `dynamodb`), for_each over service name
  - `aws_vpc_endpoint_route_table_association` — for_each over `"<service>/<rt-key>"`
- **Key Arguments**: `aws_nat_gateway.subnet_id` (ForceNew), `allocation_id`, `connectivity_type = "public"`, `availability_mode` (default `zonal`), `depends_on = [aws_internet_gateway.this]`. `aws_vpc_endpoint.vpc_endpoint_type = "Gateway"`, `service_name`. `aws_vpc_endpoint_route_table_association.route_table_id` / `vpc_endpoint_id` (both required)
- **Key Outputs**: `azs` (`list(string)`), `<tier>_subnet_ids` (`map(string)` keyed by subnet name), `<tier>_subnet_arns` / `<tier>_subnet_cidr_blocks` (`map(string)`), `public_route_table_id` (`string`), `private_route_table_ids` (`map(string)` keyed by AZ), `database_route_table_id` / `intra_route_table_id` (`string`), `nat_gateway_ids` (`map(string)` keyed by AZ), `nat_public_ips` (`map(string)` keyed by AZ), `gateway_endpoint_ids` (`map(string)` keyed by service)
- **Security Considerations**: database and intra route tables have **no** 0.0.0.0/0 route (isolation is enforced by routing). S3 and DynamoDB gateway endpoints let isolated tiers reach those services without NAT or IGW. Keep NAT in the same AZ as its consumers (AWS AZ-independence guidance). Use explicit subnet associations everywhere so no subnet falls back to the VPC main route table.

---

### 1. How the registry modules do it (evidence)

#### terraform-aws-modules/vpc/aws (v6.7.3), count/list-based

Source: `main.tf` on the upstream master branch.

- **NAT count**: `nat_gateway_count = var.single_nat_gateway ? 1 : var.one_nat_gateway_per_az ? length(var.azs) : local.max_subnet_length`.
- **NAT placement**: `subnet_id = element(aws_subnet.public[*].id, var.single_nat_gateway ? 0 : count.index)`. The single NAT always goes in `public[0]`, which is `azs[0]`. Per-AZ placement depends on public subnet *list index* lining up with `var.azs`.
- **Private RTs**: `count = local.nat_gateway_count`. This gives one RT when `single_nat_gateway`, otherwise one per NAT. Associations use `element(aws_route_table.private[*].id, var.single_nat_gateway ? 0 : count.index)`. **Switching `single_nat_gateway` changes the RT count and re-points every association.**
- **Public RT**: `num_public_route_tables = var.create_multiple_public_route_tables ? len_public_subnets : 1`. The default is one shared RT.
- **Database RT**: none by default. Database subnets associate with the *private* RTs unless `create_database_subnet_route_table = true`. With that set, you get one RT if `single_nat_gateway || create_database_internet_gateway_route`, otherwise one per subnet. Optional NAT or IGW routes are available through flags.
- **Intra RT**: `num_intra_route_tables = var.create_multiple_intra_route_tables ? len_intra_subnets : 1`. The default is one shared RT with no default route.
- **Gateway endpoints**: not in the root module. They live in the `modules/vpc-endpoints` submodule, which uses `for_each = local.endpoints`, `route_table_ids = service_type == "Gateway" ? lookup(each.value, "route_table_ids", null) : null`, and inline `route_table_ids`. Consumers pass `flatten([module.vpc.private_route_table_ids, module.vpc.intra_route_table_ids, ...])`.
- **Outputs**: flat **lists** ordered by index: `public_subnets`, `private_subnets`, `private_subnet_arns`, `private_subnets_cidr_blocks`, `private_route_table_ids`, `public_route_table_ids`, `database_route_table_ids`, `natgw_ids`, `nat_public_ips`, `azs`, plus `*_subnet_objects`.
- **Weakness for us**: everything is index-coupled. Removing a middle subnet shifts indices and forces replacements, and toggling NAT modes reshuffles RTs. This is the problem our for_each/map design is meant to fix.

#### aws-ia/vpc/aws (v4.9.0, verified), for_each keyed by AZ

Sources: `main.tf` and `data.tf`.

- **AZ set**: `local.azs` comes from `var.azs` or a slice of `data.aws_availability_zones`.
- **NAT options**: `nat_options = { all_azs = local.azs, single_az = [local.azs[0]], none = [] }`. `aws_eip.nat` and `aws_nat_gateway.main` both use `for_each = toset(local.nat_configuration)`, so **they are keyed by AZ name**. The single NAT's key is `azs[0]`, and it is also present under `all_azs`, so switching single to all **adds** NATs and never replaces the anchor.
- **NAT lookup for routes**: `nat_per_az = { for az in local.azs : az => { id = try(aws_nat_gateway.main[az].id, aws_nat_gateway.main[local.nat_configuration[0]].id) } }`. Each AZ uses its own NAT if one exists, otherwise the single NAT. `aws_route.private_to_nat` sets `nat_gateway_id = local.nat_per_az[split("/", each.key)[1]].id`.
- **Route tables**: public `aws_route_table.public` uses `for_each = toset(local.azs)` (one per AZ). Private `aws_route_table.private` uses `for_each = toset(local.private_per_az)` with keys `"<subnet-type>/<az>"`, i.e. one per subnet, because there is one subnet per type per AZ. TGW and Cloud WAN RTs are per AZ.
- **Isolated subnets**: private subnets with `connect_to_public_natgw = false` get their own RT with no default route. They are exposed as `isolated_subnet_ids`.
- **Outputs**: **maps keyed by AZ** (`public_subnet_attributes_by_az`, `private_subnet_attributes_by_az` keyed `"type/az"`), `nat_gateway_ids` (map AZ to id), `nat_public_ips` (map AZ to IP), `natgw_id_per_az` (map AZ to `{id}`, which repeats IDs in single_az mode), `route_table_ids_by_type_by_az`, `subnet_ids_by_role` (role to AZ to id), and the flat lists `natgw_subnet_ids` and `isolated_subnet_ids`.
- **What to take from it**: NAT, EIP and private-route keys by AZ; the `try(own, anchor)` fallback; full attribute or id maps as outputs. **What to leave out**: forcing exactly one subnet per type per AZ. Our input is arbitrary named subnets, and a single AZ can hold several.

#### Provider (hashicorp/aws 6.66.0 docs)

- `aws_nat_gateway`: `subnet_id` and `allocation_id` apply to zonal NATs only. Docs recommend `depends_on = [aws_internet_gateway.*]`. There is a new `availability_mode = "regional"` (multi-AZ NAT, with `vpc_id` instead of `subnet_id` and an auto-created `route_table_id`), which is an alternative to consider later (see table). Timeouts are create 10m, update 10m, delete 30m.
- `aws_vpc_endpoint_route_table_association`: requires `route_table_id` and `vpc_endpoint_id`. Import ID is `vpce-xxx/rtb-yyy`. Do **not** also set inline `route_table_ids` on the same `aws_vpc_endpoint`. The two methods conflict and cause perpetual diffs.

#### AWS guidance

- NAT gateway docs: resources in several AZs that share one NAT lose egress if that NAT's AZ fails. For AZ independence, put a NAT in each AZ and route each AZ's private subnets to the NAT in the same AZ.
- Gateway endpoints (S3, DynamoDB) have no hourly charge and work by adding prefix-list routes to the associated route tables. This lets subnets with no internet path reach those services.

---

### 2. Recommended adaptation (concrete `locals.tf`)

Assumed input shape: one variable per tier, each `map(object({ cidr_block = string, availability_zone = string, tags = optional(map(string), {}) }))`, defaulting to `{}`. Toggles are `enable_nat_gateway` (bool) and `single_nat_gateway` (bool), plus `gateway_endpoints` (set of service short names, e.g. `["s3", "dynamodb"]`). Use one resource block per tier (`aws_subnet.public`, `aws_subnet.private`, ...) so that instance keys are just the short name (`aws_subnet.private["app-a"]`).

#### (1) Deriving AZs from the subnet maps

```hcl
locals {
  # Per-tier AZ sets, known at plan time because they come only from input variables.
  public_azs   = sort(distinct([for s in values(var.public_subnets) : s.availability_zone]))
  private_azs  = sort(distinct([for s in values(var.private_subnets) : s.availability_zone]))
  database_azs = sort(distinct([for s in values(var.database_subnets) : s.availability_zone]))
  intra_azs    = sort(distinct([for s in values(var.intra_subnets) : s.availability_zone]))

  # All AZs used by the VPC, for the `azs` output.
  azs = sort(distinct(concat(local.public_azs, local.private_azs, local.database_azs, local.intra_azs)))
}
```

`sort()` on AZ *names* is lexical (`us-east-1a` < `us-east-1b`), so the result is deterministic. Accept only AZ names, not AZ IDs, and add a validation such as `can(regex("^[a-z]{2}(-[a-z]+)+-\\d[a-z]$", s.availability_zone))`, because mixing names and IDs breaks grouping. terraform-aws-modules accepts both through a regex switch. That adds complexity we do not need.

#### (2) NAT placement and `single_nat_gateway`

Rules:
- **Host subnet per AZ** = the lexically first public subnet key in that AZ.
- **NAT AZs** = all public AZs, or, when `single_nat_gateway = true`, only the **first sorted public AZ**. That AZ is also in the per-AZ set, so its key (`us-east-1a`) survives the toggle. The resource address `aws_nat_gateway.this["us-east-1a"]` stays the same and `subnet_id` does not change, so there is no replacement.
- **Route target per private AZ** = the NAT in the same AZ if one exists, otherwise the anchor NAT (the aws-ia `try()` pattern made explicit).

```hcl
locals {
  # AZ => lexically-first public subnet key in that AZ (the NAT host).
  public_subnet_key_by_az = {
    for az in local.public_azs :
    az => sort([for k, s in var.public_subnets : k if s.availability_zone == az])[0]
  }

  create_nat_gateways = var.enable_nat_gateway && length(local.public_azs) > 0

  # AZs that get a NAT gateway. single => first sorted public AZ only.
  nat_gateway_azs = (
    !local.create_nat_gateways ? [] :
    var.single_nat_gateway ? [local.public_azs[0]] :
    local.public_azs
  )

  # for_each map for aws_eip.nat and aws_nat_gateway.this, keyed by AZ.
  nat_gateways = {
    for az in local.nat_gateway_azs : az => {
      subnet_key = local.public_subnet_key_by_az[az]
    }
  }

  # private AZ => AZ key of the NAT it should route through.
  private_nat_gateway_az = {
    for az in local.private_azs :
    az => contains(local.nat_gateway_azs, az) ? az : local.nat_gateway_azs[0]
    if local.create_nat_gateways
  }
}
```

```hcl
resource "aws_eip" "nat" {
  for_each = local.nat_gateways
  domain   = "vpc"
  tags     = merge(local.tags, { Name = "${var.name}-nat-${each.key}" })

  depends_on = [aws_internet_gateway.this]
}

resource "aws_nat_gateway" "this" {
  for_each      = local.nat_gateways
  allocation_id = aws_eip.nat[each.key].id
  subnet_id     = aws_subnet.public[each.value.subnet_key].id
  tags          = merge(local.tags, { Name = "${var.name}-nat-${each.key}" })

  depends_on = [aws_internet_gateway.this]
}
```

What happens on a toggle:

| Change | Plan effect |
|---|---|
| `single_nat_gateway` true to false | +EIP/+NAT for the other public AZs. `aws_route.private_nat_gateway[az]` **updates in place** (`nat_gateway_id` changes; route targets use ReplaceRoute, so no RT churn). Anchor NAT unchanged. |
| false to true | -EIP/-NAT in non-anchor AZs. Routes update in place to the anchor. Terraform orders the route updates before the NAT destroys through dependencies. |
| `enable_nat_gateway` false to true | Only adds resources. Private RTs already exist (see 3), so only routes are added. |

Guards (preconditions or validations):
- If `enable_nat_gateway` is true and `private_subnets` is not empty, `public_subnets` must not be empty. Without this, `nat_gateway_azs[0]` fails with an index error. Put this in a `lifecycle.precondition` on `aws_route_table.private` or in a `check`.
- Optionally, when `!single_nat_gateway`, warn in a `check` block if a private AZ has no public subnet. The code above falls back to the anchor NAT, which works but crosses AZs. A `check` warns without blocking.

Pitfall: NAT placement depends on the *lexically first* public key in each AZ. If someone later adds a public subnet whose key sorts earlier in that AZ (for example `edge-a` next to `web-a`), `subnet_id` changes and forces **replacement of that NAT and its EIP**, which means a new public IP. Document this in the variable description. If it becomes a real problem, a later option is an optional `nat_gateway = optional(bool)` flag on public subnet objects that pins the host explicitly (see Alternatives).

#### (3) Route table granularity

| Tier | RTs | Keyed by | Default route | Rationale |
|---|---|---|---|---|
| public | 1 (`aws_route_table.public`) | singleton | `0.0.0.0/0` to IGW (`aws_route.public_internet_gateway`) | IGW is regional, so per-AZ RTs add nothing. Matches the terraform-aws-modules default. |
| private | 1 per private AZ (`aws_route_table.private`) | **AZ** | `0.0.0.0/0` to `aws_nat_gateway.this[local.private_nat_gateway_az[az]]` when NAT enabled | NAT is zonal. Keeping per-AZ RTs **even in single-NAT mode** means toggles only move route targets and never destroy or create RTs or rewrite associations. This fixes the terraform-aws-modules churn. Per *AZ* rather than per *subnet* because every subnet in an AZ has the same egress need, which gives fewer RTs. |
| database | 1 (`aws_route_table.database`) | singleton | none | Isolated. With no zonal target, per-AZ RTs add nothing. |
| intra | 1 (`aws_route_table.intra`) | singleton | none | Same as database. terraform-aws-modules also defaults intra to one RT. |

Keep database and intra as separate RTs rather than one merged isolated RT. It costs nothing, the Name tags stay clear, and future per-tier routes (for example TGW routes only for intra) stay possible without a breaking change.

```hcl
locals {
  create_public_route_table   = length(var.public_subnets) > 0
  create_database_route_table = length(var.database_subnets) > 0
  create_intra_route_table    = length(var.intra_subnets) > 0
}

resource "aws_route_table" "private" {
  for_each = toset(local.private_azs)
  vpc_id   = aws_vpc.this.id
  tags     = merge(local.tags, { Name = "${var.name}-private-${each.key}" })
}

resource "aws_route" "private_nat_gateway" {
  for_each               = local.private_nat_gateway_az # private AZ => NAT AZ
  route_table_id         = aws_route_table.private[each.key].id
  destination_cidr_block = "0.0.0.0/0"
  nat_gateway_id         = aws_nat_gateway.this[each.value].id
}

resource "aws_route_table_association" "private" {
  for_each       = var.private_subnets # keyed by subnet short name
  subnet_id      = aws_subnet.private[each.key].id
  route_table_id = aws_route_table.private[each.value.availability_zone].id
}
```

Conditional singleton route tables (public, database, intra) need a create/skip switch. The convention says "for_each, never count" for **subnets**. For conditional singletons, either use `count = local.create_x ? 1 : 0` and reference `aws_route_table.database[0]`, or use `for_each = local.create_x ? toset(["this"]) : toset([])`. The design agent should pick one and apply it consistently. Also, `this` is reserved for true singletons (`aws_vpc.this`, `aws_internet_gateway.this`, `aws_nat_gateway.this` since it is the only NAT resource). Route tables need tier names (`public`, `private`, `database`, `intra`) because several exist.

Do not mix inline `route {}` blocks on `aws_route_table` with separate `aws_route` resources. Use `aws_route` only, following the provider docs note.

#### (4) Gateway endpoints attached with for_each

Build a map from **fixed string keys** to RT ids. The keys come from locals or input variables, never from resource ids. The values can be unknown at plan time. Only for_each *keys* must be known.

```hcl
locals {
  # rt-key => route table id. Keys are static strings. Values may be unknown at plan time (fine).
  route_table_ids = merge(
    local.create_public_route_table ? { public = aws_route_table.public[0].id } : {},
    { for az in local.private_azs : "private-${az}" => aws_route_table.private[az].id },
    local.create_database_route_table ? { database = aws_route_table.database[0].id } : {},
    local.create_intra_route_table ? { intra = aws_route_table.intra[0].id } : {},
  )

  # Which RTs each gateway endpoint attaches to. Default: all tiers (lets isolated tiers reach S3/DynamoDB).
  gateway_endpoint_route_tables = {
    for pair in setproduct(sort(tolist(var.gateway_endpoints)), sort(keys(local.route_table_ids))) :
    "${pair[0]}/${pair[1]}" => {
      service = pair[0]
      rt_key  = pair[1]
    }
  }
}

data "aws_region" "current" {}

resource "aws_vpc_endpoint" "gateway" {
  for_each          = var.gateway_endpoints # e.g. toset(["s3", "dynamodb"])
  vpc_id            = aws_vpc.this.id
  service_name      = "com.amazonaws.${data.aws_region.current.region}.${each.key}"
  vpc_endpoint_type = "Gateway"
  tags              = merge(local.tags, { Name = "${var.name}-${each.key}" })
  # NO inline route_table_ids: it conflicts with the association resource below.
}

resource "aws_vpc_endpoint_route_table_association" "gateway" {
  for_each        = local.gateway_endpoint_route_tables
  vpc_endpoint_id = aws_vpc_endpoint.gateway[each.value.service].id
  route_table_id  = local.route_table_ids[each.value.rt_key]
}
```

Notes:
- `keys(local.route_table_ids)` is known at plan time even though the values are not. The keys depend only on `local.create_*` and `local.private_azs`, which come from variables. Terraform checks for_each key knowability, not value knowability.
- In hashicorp/aws 6.x, use `data.aws_region.current.region`. The `name` attribute is deprecated.
- If per-tier opt-out is needed later, change `gateway_endpoints` to `map(object({ route_table_tiers = optional(set(string), ["public","private","database","intra"]) }))` and filter `rt_key` by tier prefix. The keys stay the same.
- The alternative (inline `route_table_ids = values(local.route_table_ids)` on `aws_vpc_endpoint`) is simpler. However, every RT change becomes an in-place diff on the endpoint, you lose per-RT addressing and import, and it cannot be mixed with association resources.

#### (5) Output shapes

The registry modules take two approaches: terraform-aws-modules exports **lists** (index-ordered), and aws-ia exports **maps keyed by AZ** (plus a few flat lists). For our design, output maps keyed by the **same keys as the resources**, so consumers can do `module.vpc.private_subnet_ids["app-a"]`, and add `values()` for list use.

```hcl
output "azs"                    { value = local.azs }                                               # list(string)
output "public_subnet_ids"      { value = { for k, s in aws_subnet.public : k => s.id } }          # map(string) by subnet name
output "public_subnet_arns"     { value = { for k, s in aws_subnet.public : k => s.arn } }
output "public_subnet_cidr_blocks" { value = { for k, s in aws_subnet.public : k => s.cidr_block } }
# ...same trio for private / database / intra...
output "public_route_table_id"   { value = try(aws_route_table.public[0].id, null) }                # string or null
output "private_route_table_ids" { value = { for az, rt in aws_route_table.private : az => rt.id } } # map(string) by AZ
output "database_route_table_id" { value = try(aws_route_table.database[0].id, null) }
output "intra_route_table_id"    { value = try(aws_route_table.intra[0].id, null) }
output "nat_gateway_ids"         { value = { for az, n in aws_nat_gateway.this : az => n.id } }     # map(string) by AZ
output "nat_public_ips"          { value = { for az, e in aws_eip.nat : az => e.public_ip } }       # map(string) by AZ
output "gateway_endpoint_ids"    { value = { for svc, e in aws_vpc_endpoint.gateway : svc => e.id } } # map(string) by service
```

Consumer idioms: `subnet_ids = values(module.vpc.database_subnet_ids)` for `aws_db_subnet_group`, and `module.vpc.private_route_table_ids[each.value.availability_zone]` to add routes. Consider also `private_nat_gateway_id_by_az` (the `private_nat_gateway_az` map resolved to ids). This mirrors aws-ia `natgw_id_per_az` and helps secondary-CIDR or extra-subnet consumers.

---

### 3. for_each pitfalls with unknown values (plan-time)

1. **Never key on computed attributes.** `for_each = toset(aws_subnet.private[*].id)` or keys built from `aws_nat_gateway.this[*].id` fail with *"The for_each value depends on resource attributes that cannot be determined until apply"*. All keys must come from subnet names, AZ names, tier names, or service names.
2. **Unknown values are fine; unknown keys are not.** `local.route_table_ids` has unknown values and known keys, which is valid in `for_each`. If you `merge()` in a map whose *keys* come from a data source or resource output, that breaks.
3. **AZ inputs from a data source.** If a caller passes `availability_zone = data.aws_availability_zones.x.names[0]`, it is known at plan time *unless* the data source has `depends_on` on a managed resource or reads unknown arguments. In that case the read is deferred and every AZ-keyed for_each fails. Document that AZ values must be known at plan time.
4. **`setproduct`/`flatten` return lists.** Always turn them into a map with unique string keys (`"${svc}/${rt}"`) before `for_each`. `toset()` of objects gives unstable, opaque keys.
5. **Index into possibly-empty collections.** `local.public_azs[0]` or `local.nat_gateway_azs[0]` fail when empty. Guard with `local.create_nat_gateways` or a conditional, as above, and add preconditions with clear messages.
6. **ForceNew attributes in the NAT value object.** `aws_nat_gateway.subnet_id` is ForceNew. Anything that changes the chosen host subnet key (renames, an earlier-sorting key added in the same AZ) replaces the NAT and changes its EIP. Keeping the NAT key by AZ ensures only that AZ's NAT is affected.
7. **Mode switches must not change keys.** terraform-aws-modules changes *counts* when `single_nat_gateway` flips, which reshuffles RTs and associations. Our design avoids this by keeping private RTs keyed by AZ unconditionally and choosing the single NAT from the per-AZ key set.
8. **Endpoint association conflict.** Do not combine inline `route_table_ids` on `aws_vpc_endpoint` with `aws_vpc_endpoint_route_table_association` for the same endpoint.
9. **Subnet key uniqueness across tiers.** Per-tier resources allow `app-a` in both private and intra. If a combined `subnet_ids` output (or a flattened `"tier/name"` map) is ever added, validate cross-tier uniqueness or namespace the keys as `"${tier}/${name}"`.

### Rationale

- aws-ia/vpc (verified) shows that AZ-keyed NAT and EIP with `single_az = [azs[0]]` plus a `try(nat[az], nat[anchor])` lookup makes the single/all switch purely additive. We take this directly.
- terraform-aws-modules/vpc (216M downloads) sets the default tier topology: one public RT, private RTs tied to NAT count, database optionally sharing private RTs, one intra RT, and gateway endpoints attached by passing RT id lists. Its count/index coupling is the exact problem our map design exists to avoid. Its `single_nat_gateway` behavior (collapsing private RTs to one) is the churn source we remove by keeping per-AZ private RTs.
- The AWS NAT gateway guidance favors same-AZ NAT routing for AZ independence. Keying private RTs by AZ expresses that exactly. Per-subnet RTs would duplicate identical tables.
- The provider docs confirm `aws_vpc_endpoint_route_table_association` as a standalone resource (import ID `vpce/rtb`), and confirm that `aws_nat_gateway.subnet_id` applies to zonal NATs only.

### Alternatives Considered

| Alternative | Why Not |
| --- | --- |
| Private RT per subnet (aws-ia style, keyed by subnet name) | Subnets in the same AZ get identical RTs. More resources and no routing benefit, since NAT choice is per AZ. Only worth it if per-subnet custom routes become a requirement. |
| Collapse private RTs to one when `single_nat_gateway` (terraform-aws-modules) | Switching destroys and creates RTs and rewrites every association. Per-AZ RTs cost nothing and make the switch an in-place route update. |
| Database subnets share private RTs (terraform-aws-modules default) | Gives database subnets a NAT default route, which breaks the isolated-tier requirement. |
| Per-AZ database/intra RTs | No zonal targets exist for isolated tiers, so this adds resources with no difference in behavior. |
| Explicit `nat_gateway = true` flag per public subnet | Pins placement exactly and avoids the "earlier key sorts first" replacement risk, but adds input surface and validation (one per AZ). A reasonable later addition. Lexically-first is a sensible zero-config default. |
| Single NAT keyed by a constant (`"this"`) rather than AZ | Switching to per-AZ would destroy and recreate the NAT and its EIP (new public IP). AZ keys avoid that. |
| Regional NAT gateway (`availability_mode = "regional"`, hashicorp/aws 6.x) | One resource spans AZs and auto-expands, which removes the placement question entirely. However it is new, uses a different routing model (auto-created RT and `vpc_id` instead of `subnet_id`), and switching zonal/regional forces recreation. Keep as a future option. |
| Inline `route_table_ids` on `aws_vpc_endpoint` | Simpler, but per-RT addressing and import are lost, it cannot coexist with association resources, and every RT change modifies the endpoint. |
| One resource block across all tiers (flattened `"tier/name"` keys) | Less repetition, but resource addresses are harder to read and the per-tier differences (`map_public_ip_on_launch`, RT target) end up as conditionals. Per-tier blocks match the per-tier input variables. |

### Sources

- Registry: terraform-aws-modules/vpc/aws 6.7.3 — https://registry.terraform.io/modules/terraform-aws-modules/vpc/aws/latest ; source `main.tf` (`nat_gateway_count`, `aws_nat_gateway.this`, `aws_route_table.private|database|intra`), `outputs.tf`, `modules/vpc-endpoints/main.tf` — https://github.com/terraform-aws-modules/terraform-aws-vpc
- Registry: aws-ia/vpc/aws 4.9.0 (verified) — https://registry.terraform.io/modules/aws-ia/vpc/aws/latest ; source `data.tf` (`nat_options`, `nat_configuration`, `nat_per_az`, `private_per_az`) and `main.tf` (`aws_nat_gateway.main`, `aws_route.private_to_nat`) — https://github.com/aws-ia/terraform-aws-vpc
- Provider docs (hashicorp/aws 6.66.0): `aws_nat_gateway` (zonal/regional `availability_mode`, `depends_on` IGW, timeouts), `aws_vpc_endpoint_route_table_association`, `aws_vpc_endpoint`, `aws_route`, `aws_route_table`
- AWS docs: NAT gateways, AZ-independent architecture — https://docs.aws.amazon.com/vpc/latest/userguide/vpc-nat-gateway.html ; Gateway endpoints — https://docs.aws.amazon.com/vpc/latest/privatelink/gateway-endpoints.html
- Terraform docs: for_each limitations (keys must be known) — https://developer.hashicorp.com/terraform/language/meta-arguments/for_each#limitations-on-values-used-in-for_each
