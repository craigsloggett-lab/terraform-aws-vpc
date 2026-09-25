## Research: hashicorp/aws 5.x (5.100.0) resource schemas and gotchas for terraform-aws-vpc

Scope: hashicorp/aws pinned `>= 5.0, < 6.0`, Terraform `>= 1.14`. All schemas below were read from the
registry docs for **hashicorp/aws 5.100.0** (latest 5.x). 6.x differences were checked against the
6.x docs and the official Version 6 Upgrade Guide.

### Decision

Use standalone resources (`aws_route`, `aws_route_table_association`, `aws_vpc_endpoint_route_table_association`,
`aws_iam_role_policy`) rather than inline/exclusive arguments, set `aws_eip.domain = "vpc"`, use
`aws_flow_log.log_destination` (never `log_group_name`), and write only syntax that is valid and
non-deprecated in 5.x — with one unavoidable exception: `data.aws_region.current.name` (the 5.x-only
spelling; `region` does not exist until 6.0).

### Resources Identified

- **Primary Resource**: `aws_vpc`
- **Supporting Resources**: `aws_subnet`, `aws_internet_gateway`, `aws_eip`, `aws_nat_gateway`,
  `aws_route_table`, `aws_route`, `aws_route_table_association`, `aws_vpc_endpoint` (Gateway),
  `aws_vpc_endpoint_route_table_association`, `aws_flow_log`, `aws_cloudwatch_log_group`, `aws_iam_role`,
  `aws_iam_role_policy`, `aws_default_security_group`, `aws_db_subnet_group`;
  data: `aws_iam_policy_document`, `aws_region`, `aws_caller_identity`
- **Key Outputs**: `aws_vpc.id`/`arn`/`cidr_block`, subnet `id`s/`arn`s, `aws_nat_gateway.public_ip`,
  `aws_vpc_endpoint.id`/`prefix_list_id`, `aws_flow_log.id`, `aws_cloudwatch_log_group.arn`,
  `aws_db_subnet_group.name` (== `id`)/`arn`
- **Security Considerations**: flow logs to KMS-encrypted CWL group with finite retention; least-privilege
  flow-log role with confused-deputy conditions; default SG stripped of all rules.

---

### 1. `aws_vpc`

Doc: https://registry.terraform.io/providers/hashicorp/aws/5.100.0/docs/resources/vpc

| Argument | Notes (5.100.0) |
|---|---|
| `cidr_block` | Optional (can come from IPAM via `ipv4_ipam_pool_id` + `ipv4_netmask_length`). Module sets it explicitly. |
| `instance_tenancy` | `default` (default) or `dedicated` (costly). |
| `enable_dns_support` | Optional bool, **defaults `true`**. |
| `enable_dns_hostnames` | Optional bool, **defaults `false`** — must be set `true` explicitly (needed for private DNS on interface endpoints, RDS endpoint resolution, etc.). |
| `enable_network_address_usage_metrics` | default `false`. |
| `assign_generated_ipv6_cidr_block` | default `false`; conflicts with `ipv6_ipam_pool_id`. |
| `tags` | merges with provider `default_tags`. |

Attributes: `id`, `arn`, `owner_id`, `main_route_table_id`, `default_route_table_id`,
`default_security_group_id`, `default_network_acl_id`, `dhcp_options_id`, `ipv6_association_id`, `tags_all`.
No timeouts block. Import by VPC id.

```hcl
resource "aws_vpc" "this" {
  cidr_block           = var.cidr_block
  enable_dns_support   = true
  enable_dns_hostnames = true # default is false

  tags = merge(var.tags, { Name = var.name })
}
```

### 2. `aws_subnet`

Doc: https://registry.terraform.io/providers/hashicorp/aws/5.100.0/docs/resources/subnet

- `vpc_id` (Required); `cidr_block`; `availability_zone` **or** `availability_zone_id` (the latter not
  supported in all regions/partitions — prefer `availability_zone`).
- `map_public_ip_on_launch` default `false` — keep `false` even on public subnets unless required
  (NAT GW uses an EIP, not auto-assigned IPs). Security Hub EC2.15 flags `true`.
- `assign_ipv6_address_on_creation`, `ipv6_cidr_block` (/64), `ipv6_native`, `enable_dns64`,
  `private_dns_hostname_type_on_launch` (`ip-name` | `resource-name`),
  `enable_resource_name_dns_a_record_on_launch` — all optional, default false.
- Attributes: `id`, `arn`, `owner_id`, `ipv6_cidr_block_association_id`, `tags_all`.
- Timeouts: `create` 10m, `delete` 20m (Lambda ENIs can hold deletes up to ~45m).

```hcl
resource "aws_subnet" "private" {
  for_each = local.private_subnets # keyed by AZ name, stable keys

  vpc_id                  = aws_vpc.this.id
  cidr_block              = each.value.cidr_block
  availability_zone       = each.key
  map_public_ip_on_launch = false

  tags = merge(var.tags, { Name = "${var.name}-private-${each.key}", Tier = "private" })
}
```

### 3. `aws_internet_gateway`

Doc: https://registry.terraform.io/providers/hashicorp/aws/5.100.0/docs/resources/internet_gateway

- `vpc_id` (Optional — attaches inline; alternative is `aws_internet_gateway_attachment`, don't mix), `tags`.
- Attributes: `id`, `arn`, `owner_id`, `tags_all`. Timeouts create/update/delete 20m.
- Doc guidance: resources that need public reachability (EIPs, NAT GWs) should `depends_on` the IGW.

### 4. `aws_eip` — `domain = "vpc"` vs deprecated `vpc = true`

Doc: https://registry.terraform.io/providers/hashicorp/aws/5.100.0/docs/resources/eip

- `domain` (Optional) — "Indicates if this EIP is for use in VPC (`vpc`)". **Use this.**
- `vpc` — **Deprecated in 5.x** ("Use `domain` instead"); **removed in 6.0** (upgrade guide:
  "Remove `vpc`—it is no longer supported"). Never use.
- Other args: `network_border_group`, `public_ipv4_pool`, `ipam_pool_id`, `address`, `instance`,
  `network_interface`, `associate_with_private_ip`, `customer_owned_ipv4_pool`, `tags`.
- Doc gotchas: (a) EIP may require IGW first → `depends_on = [aws_internet_gateway.this]`;
  (b) **do not** set `network_interface`/`instance` for NAT GW EIPs — pass `allocation_id` to the NAT GW
  instead, otherwise `AuthFailure`.
- Attributes: `id` (= allocation id), `allocation_id`, `public_ip`, `public_dns`, `private_ip`,
  `association_id`, `tags_all`. Timeouts: read 15m, update 5m, delete 3m.

```hcl
resource "aws_eip" "nat" {
  for_each = local.nat_azs

  domain = "vpc"
  tags   = merge(var.tags, { Name = "${var.name}-nat-${each.key}" })

  depends_on = [aws_internet_gateway.this]
}
```

### 5. `aws_nat_gateway`

Doc: https://registry.terraform.io/providers/hashicorp/aws/5.100.0/docs/resources/nat_gateway

- `subnet_id` (Required — must be a **public** subnet for public NAT).
- `allocation_id` — required when `connectivity_type = "public"` (default `public`; other value `private`).
- Optional: `private_ip`, `secondary_allocation_ids`, `secondary_private_ip_addresses`,
  `secondary_private_ip_address_count` (private NAT only), `tags`.
- Attributes: `id`, `public_ip`, `network_interface_id`, `association_id`, `tags_all`.
- Timeouts: create 10m, update 10m, **delete 30m**.
- Doc recommends explicit `depends_on = [aws_internet_gateway.this]`.

```hcl
resource "aws_nat_gateway" "this" {
  for_each = local.nat_azs

  allocation_id = aws_eip.nat[each.key].allocation_id
  subnet_id     = aws_subnet.public[each.key].id
  tags          = merge(var.tags, { Name = "${var.name}-${each.key}" })

  depends_on = [aws_internet_gateway.this]
}
```

### 6. `aws_route_table`, `aws_route`, `aws_route_table_association`

Docs:
- https://registry.terraform.io/providers/hashicorp/aws/5.100.0/docs/resources/route_table
- https://registry.terraform.io/providers/hashicorp/aws/5.100.0/docs/resources/route
- https://registry.terraform.io/providers/hashicorp/aws/5.100.0/docs/resources/route_table_association

**Gotcha 1 — inline vs standalone routes are mutually exclusive.** "You cannot use a Route Table with
in-line routes in conjunction with any Route resources. Doing so will cause a conflict ... and will
overwrite rules." `route` on `aws_route_table` is attribute-as-blocks: omitting it = ignore existing
routes; `route = []` = remove all. **Decision: omit `route` entirely on `aws_route_table` and use
`aws_route` exclusively.** This also keeps the table compatible with Gateway endpoint-managed routes
(prefix-list routes added by the endpoint are ignored when `route` is omitted).

**Gotcha 2 — wrong target argument causes perpetual diff.** IGW → `gateway_id`; NAT GW →
`nat_gateway_id` (never `gateway_id`). The API accepts either but returns the specific one.

**Gotcha 3 —** do not create `aws_route` with `vpc_endpoint_id` + `destination_prefix_list_id` for
Gateway endpoints; the doc says use `aws_vpc_endpoint_route_table_association` instead.

- `aws_route_table`: `vpc_id` (Required), `route` (avoid), `propagating_vgws` (avoid with
  `aws_vpn_gateway_route_propagation`), `tags`. Attributes `id`, `arn`, `owner_id`. Timeouts create 5m / update 2m / delete 5m.
- `aws_route`: `route_table_id` (Required); exactly one destination (`destination_cidr_block`,
  `destination_ipv6_cidr_block`, `destination_prefix_list_id`); exactly one target (`gateway_id`,
  `nat_gateway_id`, `egress_only_gateway_id`, `transit_gateway_id`, `vpc_endpoint_id`,
  `vpc_peering_connection_id`, `network_interface_id`, `local_gateway_id`, `carrier_gateway_id`,
  `core_network_arn`). Attributes `id` (`<rtb>_<dest>`), `origin`, `state`, `instance_id`. Timeouts 5m/2m/5m.
- `aws_route_table_association`: `route_table_id` (Required) + one of `subnet_id` / `gateway_id`
  (conflict). Attribute `id`. Associating an already-associated subnet errors (`Resource.AlreadyAssociated`).

```hcl
resource "aws_route_table" "private" {
  for_each = aws_subnet.private
  vpc_id   = aws_vpc.this.id
  tags     = merge(var.tags, { Name = "${var.name}-private-${each.key}" })
  # no inline `route` blocks — routes are managed with aws_route
}

resource "aws_route" "private_nat" {
  for_each = var.enable_nat_gateway ? aws_route_table.private : {}

  route_table_id         = each.value.id
  destination_cidr_block = "0.0.0.0/0"
  nat_gateway_id         = aws_nat_gateway.this[local.nat_az_for[each.key]].id # NOT gateway_id
}

resource "aws_route" "public_internet" {
  route_table_id         = aws_route_table.public.id
  destination_cidr_block = "0.0.0.0/0"
  gateway_id             = aws_internet_gateway.this.id
}

resource "aws_route_table_association" "private" {
  for_each       = aws_subnet.private
  subnet_id      = each.value.id
  route_table_id = aws_route_table.private[each.key].id
}
```

### 7. `aws_vpc_endpoint` (Gateway) — `route_table_ids` vs `aws_vpc_endpoint_route_table_association`

Docs:
- https://registry.terraform.io/providers/hashicorp/aws/5.100.0/docs/resources/vpc_endpoint
- https://registry.terraform.io/providers/hashicorp/aws/5.100.0/docs/resources/vpc_endpoint_route_table_association

- `vpc_id` (Required); exactly one of `service_name` / `resource_configuration_arn` / `service_network_arn`.
- `vpc_endpoint_type` default **`Gateway`** (set it explicitly for clarity).
- `route_table_ids` — "Applicable for endpoints of type `Gateway`".
- `policy` — JSON; **defaults to full access**. Gateway endpoints support policies.
- `private_dns_enabled`, `subnet_ids`, `security_group_ids`, `dns_options`, `ip_address_type` — Interface-only; don't set for Gateway.
- Attributes: `id`, `arn`, `prefix_list_id` (Gateway), `cidr_blocks` (Gateway), `owner_id`, `state`, `tags_all`.
- Timeouts: create/update/delete 10m.
- **Gotcha:** "Do not use the same resource ID in both a VPC Endpoint resource and a VPC Endpoint
  Association resource. Doing so will cause a conflict of associations and will overwrite the association."
  → pick one. `aws_vpc_endpoint_route_table_association` (`route_table_id`, `vpc_endpoint_id`, both
  Required; import `vpce-xxx/rtb-yyy`) is better when the set of route tables is keyed/dynamic (per-AZ
  `for_each`), because adding/removing one AZ's table touches one association rather than updating the
  endpoint in place. `route_table_ids` is simpler when the list is static. **Recommendation:** use
  `route_table_ids` on the endpoint (single resource, fewer objects) unless the design needs per-table
  lifecycle; never both.

```hcl
data "aws_region" "current" {}

resource "aws_vpc_endpoint" "s3" {
  vpc_id            = aws_vpc.this.id
  service_name      = "com.amazonaws.${data.aws_region.current.name}.s3" # 5.x: .name
  vpc_endpoint_type = "Gateway"
  route_table_ids   = [for rt in aws_route_table.private : rt.id]

  tags = merge(var.tags, { Name = "${var.name}-s3" })
}
```

### 8. `aws_flow_log`

Doc: https://registry.terraform.io/providers/hashicorp/aws/5.100.0/docs/resources/flow_log

| Argument | Notes |
|---|---|
| `traffic_type` | **Required**. `ACCEPT` \| `REJECT` \| `ALL`. |
| `log_destination` | ARN of destination. **Use this.** |
| `log_group_name` | **Deprecated in 5.x**; **removed in 6.0** (upgrade guide). Never use. |
| `log_destination_type` | `cloud-watch-logs` (default) \| `s3` \| `kinesis-data-firehose`. |
| `iam_role_arn` | Required in practice for `cloud-watch-logs`; omit for S3. |
| `vpc_id` / `subnet_id` / `eni_id` / `transit_gateway_id` / `transit_gateway_attachment_id` | Exactly one required. |
| `max_aggregation_interval` | `60` or `600` (default `600`); must be `60` for TGW sources. |
| `log_format` | Custom format; escape `$${field}` in HCL. |
| `destination_options` | S3 only: `file_format` (`plain-text`/`parquet`), `hive_compatible_partitions`, `per_hour_partition`. |
| `deliver_cross_account_role` | optional. |

Attributes: `id`, `arn`, `tags_all`. No timeouts block.

**Gotcha:** `aws_cloudwatch_log_group.arn` is returned *without* the `:*` suffix, which is what
`log_destination` expects — pass it directly.

```hcl
resource "aws_flow_log" "this" {
  count = var.enable_flow_logs ? 1 : 0

  vpc_id                   = aws_vpc.this.id
  traffic_type             = "ALL"
  log_destination_type     = "cloud-watch-logs"
  log_destination          = aws_cloudwatch_log_group.flow_logs[0].arn
  iam_role_arn             = aws_iam_role.flow_logs[0].arn
  max_aggregation_interval = 60

  tags = merge(var.tags, { Name = "${var.name}-flow-logs" })
}
```

### 9. `aws_cloudwatch_log_group`

Doc: https://registry.terraform.io/providers/hashicorp/aws/5.100.0/docs/resources/cloudwatch_log_group

- `name` / `name_prefix` (Forces new; conflict).
- `retention_in_days` — **allowed values: 0, 1, 3, 5, 7, 14, 30, 60, 90, 120, 150, 180, 365, 400, 545,
  731, 1096, 1827, 2192, 2557, 2922, 3288, 3653** (0 = never expire). Add a `validation` block with
  `contains([...], var.flow_log_retention_in_days)`. CIS/Security Hub CloudWatch.16 expects >= 365.
- `kms_key_id` — **ARN** of KMS key. The key policy must allow the `logs.<region>.amazonaws.com`
  service principal (`kms:Encrypt*`, `kms:Decrypt*`, `kms:ReEncrypt*`, `kms:GenerateDataKey*`,
  `kms:Describe*`) with condition `ArnLike kms:EncryptionContext:aws:logs:arn =
  arn:aws:logs:<region>:<account>:log-group:<name>` — otherwise create fails.
- `log_group_class` `STANDARD` | `INFREQUENT_ACCESS` (Infrequent Access does not support subscription
  filters etc.; keep `STANDARD` for flow logs unless explicitly chosen).
- `skip_destroy` — optional; keep default `false` for a module (test teardown).
- Attributes: `arn` (no `:*`), `tags_all`. Import by name.

```hcl
resource "aws_cloudwatch_log_group" "flow_logs" {
  count = var.enable_flow_logs ? 1 : 0

  name              = "/aws/vpc-flow-logs/${var.name}"
  retention_in_days = var.flow_log_retention_in_days # validated against allowed list
  kms_key_id        = var.flow_log_kms_key_arn       # null => AWS-owned key encryption

  tags = var.tags
}
```

### 10. `aws_iam_role`, `aws_iam_role_policy`, `aws_iam_policy_document`

Docs:
- https://registry.terraform.io/providers/hashicorp/aws/5.100.0/docs/resources/iam_role
- https://registry.terraform.io/providers/hashicorp/aws/5.100.0/docs/resources/iam_role_policy
- https://registry.terraform.io/providers/hashicorp/aws/5.100.0/docs/data-sources/iam_policy_document
- AWS: https://docs.aws.amazon.com/vpc/latest/userguide/flow-logs-iam-role.html

- `aws_iam_role`: `assume_role_policy` (Required); `name`/`name_prefix` (Forces new), `path`,
  `description`, `max_session_duration`, `permissions_boundary`, `force_detach_policies`, `tags`.
  **`inline_policy` and `managed_policy_arns` are Deprecated in 5.x** (exclusive management) — do not
  use; use `aws_iam_role_policy` instead (the two conflict: permanent diff). Attributes: `arn`, `id`
  (= name), `name`, `unique_id`, `create_date`, `tags_all`.
- `aws_iam_role_policy`: `role` (Required, role **name** — pass `aws_iam_role.x.id` or `.name`),
  `policy` (Required JSON), `name`/`name_prefix`. `id` = `role:policy`.
- `aws_iam_policy_document`: `statement { sid, effect (default Allow), actions, not_actions, resources,
  not_resources, principals { type, identifiers }, not_principals, condition { test, variable, values } }`,
  `source_policy_documents`, `override_policy_documents`, `version` (default `2012-10-17`), `policy_id`.
  Outputs `json`, `minified_json`. Use `&{...}` for IAM policy variables.
- Scope: the provider doc example grants `logs:*` on `"*"` including `CreateLogGroup` — too broad.
  The module creates the group itself, so drop `CreateLogGroup` and scope to the group ARN. Add
  confused-deputy conditions on the trust policy (`aws:SourceAccount`, `aws:SourceArn`), which the AWS
  flow-logs IAM role page recommends.

```hcl
data "aws_caller_identity" "current" {}

data "aws_iam_policy_document" "flow_logs_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["vpc-flow-logs.amazonaws.com"]
    }
    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [data.aws_caller_identity.current.account_id]
    }
    condition {
      test     = "ArnLike"
      variable = "aws:SourceArn"
      values   = ["arn:aws:ec2:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}:vpc-flow-log/*"]
    }
  }
}

data "aws_iam_policy_document" "flow_logs" {
  statement {
    actions = [
      "logs:CreateLogStream",
      "logs:PutLogEvents",
      "logs:DescribeLogGroups",
      "logs:DescribeLogStreams",
    ]
    resources = [
      aws_cloudwatch_log_group.flow_logs[0].arn,
      "${aws_cloudwatch_log_group.flow_logs[0].arn}:*",
    ]
  }
}

resource "aws_iam_role" "flow_logs" {
  count              = var.enable_flow_logs ? 1 : 0
  name_prefix        = "${var.name}-flow-logs-"
  assume_role_policy = data.aws_iam_policy_document.flow_logs_assume.json
  tags               = var.tags
}

resource "aws_iam_role_policy" "flow_logs" {
  count  = var.enable_flow_logs ? 1 : 0
  name   = "flow-logs-to-cloudwatch"
  role   = aws_iam_role.flow_logs[0].id
  policy = data.aws_iam_policy_document.flow_logs.json
}
```

Note: use `data.aws_partition.current.partition` instead of hard-coded `arn:aws` if GovCloud/China
support is in scope. Also, `logs:DescribeLogGroups` does not always support resource-level scoping. If
flow-log delivery shows `access error`, widen only that action to
`arn:aws:logs:<region>:<account>:log-group:*`. Confirm this during the sandbox apply.

### 11. `aws_default_security_group` — does omitting blocks strip rules?

Doc: https://registry.terraform.io/providers/hashicorp/aws/5.100.0/docs/resources/default_security_group

**Yes.** Direct from the doc: "When Terraform first begins managing the default security group, it
**immediately removes all ingress and egress rules in the Security Group**. It then creates any rules
specified in the configuration." `ingress`/`egress` are attribute-as-blocks and "treated as absolute";
the doc's "deny all egress" example works by *omitting* `egress`. So a resource with only `vpc_id` +
`tags` leaves the default SG with **zero rules** (CIS AWS 5.4 / Security Hub EC2.2), and any
out-of-band rule addition shows as drift.

Other gotchas:
- Incompatible with `aws_security_group_rule` / `aws_vpc_security_group_*_rule` targeting the default SG.
- Removing the resource from config (or destroying) does **not** delete the SG or restore rules; it only
  drops it from state. Changing `vpc_id` doesn't restore rules either.
- Note: Interface VPC endpoints created without `security_group_ids` fall back to the default SG — with
  zero rules they would be unreachable. This matters only if Interface endpoints are added later.
- Attributes: `id`, `arn`, `name`, `description`, `owner_id`, `tags_all`.

```hcl
resource "aws_default_security_group" "this" {
  vpc_id = aws_vpc.this.id
  # No ingress/egress blocks => all rules removed and kept removed (CIS 5.4)
  tags = merge(var.tags, { Name = "${var.name}-default-deny-all" })
}
```

### 12. `aws_db_subnet_group`

Doc: https://registry.terraform.io/providers/hashicorp/aws/5.100.0/docs/resources/db_subnet_group

- `subnet_ids` (Required, list). `name` / `name_prefix` (Forces new; conflict). AWS lowercases names
  (use lowercase input to avoid diffs). `description` default "Managed by Terraform" (set a real one).
  `tags`.
- RDS requires subnets in **>= 2 AZs** (API error otherwise) — validate AZ count when enabled.
- Attributes: `id` (= name), `arn`, `vpc_id`, `supported_network_types`, `tags_all`. Import by name.

```hcl
resource "aws_db_subnet_group" "this" {
  count = var.create_database_subnet_group ? 1 : 0

  name        = lower("${var.name}-database")
  description = "Database subnet group for ${var.name}"
  subnet_ids  = [for s in aws_subnet.database : s.id]
  tags        = var.tags
}
```

### 13. Data sources `aws_region` and `aws_caller_identity`

Docs:
- 5.x: https://registry.terraform.io/providers/hashicorp/aws/5.100.0/docs/data-sources/region
- 6.x: https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/region
- https://registry.terraform.io/providers/hashicorp/aws/5.100.0/docs/data-sources/caller_identity

`aws_region` in **5.100.0**: args `name`, `endpoint`; attrs `name`, `endpoint`, `description`, `id`
(= name). **There is no `region` attribute in 5.x.** In **6.x**: `region` added; `name` **Deprecated**
("Use `region` instead"); `id` **Deprecated**. → With the `< 6.0` pin, use
`data.aws_region.current.name`. It still works in 6.x but logs a deprecation warning, which is the
thing to change when the module moves to 6.x.

`aws_caller_identity` (5.x): no args; attrs `account_id`, `arn`, `user_id`, `id`. Use `account_id`
(not `id`).

---

### 5.x vs 6.x — things the module MUST avoid / be aware of

| Item | 5.x (target) | 6.x | Module rule |
|---|---|---|---|
| `aws_eip.vpc` | Deprecated | **Removed** | Use `domain = "vpc"` only |
| `aws_flow_log.log_group_name` | Deprecated | **Removed** | Use `log_destination` (ARN) only |
| `data.aws_region.*.name` | Current | Deprecated → `region` | Use `.name` (the only 5.x option). `.region` would fail in 5.x. |
| `data.aws_region.*.id` | Works | Deprecated | Don't use |
| Per-resource `region` argument ("Enhanced Region Support") | **Not present** | Added to most resources | Never set `region = ...` on resources/data sources — invalid in 5.x |
| `aws_iam_role.inline_policy` / `managed_policy_arns` | Deprecated | Deprecated | Use `aws_iam_role_policy` |
| Nullable-bool 0/1 validation | lenient | strict | Always use `true`/`false` literals |

None of the other resources above (`aws_vpc`, `aws_subnet`, `aws_internet_gateway`, `aws_nat_gateway`,
`aws_route*`, `aws_vpc_endpoint*`, `aws_cloudwatch_log_group`, `aws_default_security_group`,
`aws_db_subnet_group`, `aws_caller_identity`) have breaking changes listed in the v6 upgrade guide.

### Rationale

Every schema point above comes from the 5.100.0 registry pages. Deprecations and removals were checked
against the official v6 Upgrade Guide. Using standalone `aws_route` avoids the documented inline-route
conflict and works alongside Gateway endpoint prefix-list routes. The `aws_default_security_group`
behaviour (strip everything, recreate only what is declared) is stated in the provider docs, so a
block-less resource is the supported way to meet CIS 5.4.

### Alternatives Considered

| Alternative | Why Not |
|---|---|
| Inline `route {}` blocks on `aws_route_table` | Can't mix with `aws_route`. Attribute-as-blocks semantics are easy to get wrong. Harder to make conditional (NAT on/off). |
| `aws_vpc_endpoint_route_table_association` **and** `route_table_ids` | Doc says they conflict and overwrite each other. Pick one. |
| `aws_eip { vpc = true }` | Deprecated in 5.x, removed in 6.0 |
| `aws_flow_log { log_group_name = ... }` | Deprecated in 5.x, removed in 6.0 |
| `data.aws_region.current.region` | Attribute doesn't exist until 6.0. Fails on the pinned range. |
| `aws_iam_role.inline_policy` | Deprecated in 5.x. Conflicts with `aws_iam_role_policy`. |
| Flow-log role policy from the doc example (`logs:*`-style on `"*"`, incl. CreateLogGroup) | Over-privileged. The module owns the log group, so scope to its ARN. |

### Sources

- https://registry.terraform.io/providers/hashicorp/aws/5.100.0/docs/resources/vpc
- https://registry.terraform.io/providers/hashicorp/aws/5.100.0/docs/resources/subnet
- https://registry.terraform.io/providers/hashicorp/aws/5.100.0/docs/resources/internet_gateway
- https://registry.terraform.io/providers/hashicorp/aws/5.100.0/docs/resources/eip
- https://registry.terraform.io/providers/hashicorp/aws/5.100.0/docs/resources/nat_gateway
- https://registry.terraform.io/providers/hashicorp/aws/5.100.0/docs/resources/route_table
- https://registry.terraform.io/providers/hashicorp/aws/5.100.0/docs/resources/route
- https://registry.terraform.io/providers/hashicorp/aws/5.100.0/docs/resources/route_table_association
- https://registry.terraform.io/providers/hashicorp/aws/5.100.0/docs/resources/vpc_endpoint
- https://registry.terraform.io/providers/hashicorp/aws/5.100.0/docs/resources/vpc_endpoint_route_table_association
- https://registry.terraform.io/providers/hashicorp/aws/5.100.0/docs/resources/flow_log
- https://registry.terraform.io/providers/hashicorp/aws/5.100.0/docs/resources/cloudwatch_log_group
- https://registry.terraform.io/providers/hashicorp/aws/5.100.0/docs/resources/iam_role
- https://registry.terraform.io/providers/hashicorp/aws/5.100.0/docs/resources/iam_role_policy
- https://registry.terraform.io/providers/hashicorp/aws/5.100.0/docs/data-sources/iam_policy_document
- https://registry.terraform.io/providers/hashicorp/aws/5.100.0/docs/resources/default_security_group
- https://registry.terraform.io/providers/hashicorp/aws/5.100.0/docs/resources/db_subnet_group
- https://registry.terraform.io/providers/hashicorp/aws/5.100.0/docs/data-sources/region
- https://registry.terraform.io/providers/hashicorp/aws/5.100.0/docs/data-sources/caller_identity
- https://registry.terraform.io/providers/hashicorp/aws/latest/docs/guides/version-6-upgrade
- https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/region (6.x)
- https://docs.aws.amazon.com/vpc/latest/userguide/flow-logs-iam-role.html
- https://docs.aws.amazon.com/AmazonCloudWatch/latest/logs/encrypt-log-data-kms.html
- https://docs.aws.amazon.com/vpc/latest/userguide/default-security-group.html
