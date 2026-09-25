# Module Design: terraform-aws-vpc

**Branch**: 003-vpc
**Date**: 2026-09-26
**Status**: Draft
**Provider**: hashicorp/aws >= 5.0, < 6.0
**Terraform**: >= 1.14

---

## Table of Contents

1. [Purpose & Requirements](#1-purpose--requirements)
2. [Resources & Architecture](#2-resources--architecture)
3. [Interface Contract](#3-interface-contract)
4. [Security Controls](#4-security-controls)
5. [Test Scenarios](#5-test-scenarios)
6. [Implementation Checklist](#6-implementation-checklist)
7. [Open Questions](#7-open-questions)

---

## 1. Purpose & Requirements

This module gives platform and application teams one IPv4 virtual network per call. The network is secure by default and has up to four tiers. **Public** hosts internet-facing load balancers and the egress gateways. **Private** holds workloads that need outbound-only internet access. **Database** holds data stores and has no internet path. **Intra** holds fully isolated workloads. Each team currently hand-builds its networks, so address plans, egress resilience, traffic logging and default firewall posture differ from team to team. With this module, a consumer names the network and gives its address range. That alone produces a compliant baseline: traffic logging is on, the default firewall is closed, and no address is public unless requested. Consumers then add named subnets per tier without renumbering the ones that already exist.

**Scope boundary**: These are out of scope for v1: IPv6 and dual-stack, custom network ACLs (including managing the default network ACL; see Open Questions), interface (PrivateLink) endpoints, gateway endpoint policies, secondary CIDRs and IPAM, Transit Gateway, peering, VPN and Direct Connect, regional (multi-AZ) NAT, flow log destinations other than CloudWatch Logs, creating KMS keys, and AWS provider 6.x.

### Requirements

**Functional requirements**:

- FR-01: The consumer must supply only a network name and an IPv4 address range. Every other input has a working default.
- FR-02: The network must resolve DNS names, and instances must receive DNS hostnames.
- FR-03: The consumer declares subnets per tier (public, private, database, intra) as named entries, each with an address range, an availability zone and optional tags. Adding or removing one entry must not change or recreate any other subnet.
- FR-04: Public subnets route to the internet through an internet gateway. The gateway exists only when at least one public subnet is declared.
- FR-05: Private subnets have outbound-only internet access through NAT. By default each availability zone that holds private subnets gets its own NAT, placed in a public subnet in the same zone. As an opt-in cost saver, a single NAT can serve every zone. Switching between the two modes must never replace the NAT that remains.
- FR-06: Database and intra subnets must have no route to the internet or to NAT.
- FR-07: The consumer can opt in to private, route-based access to S3 and/or DynamoDB for every non-public tier. The public tier is never attached.
- FR-08: Network traffic metadata (accepted and rejected) is logged to a log group owned by the module. Logging is on by default, retention is configurable (default 365 days), aggregation is configurable, and a customer-managed encryption key is optional.
- FR-09: The network's default firewall group must allow no inbound or outbound traffic.
- FR-10: When database subnets span at least two availability zones, the module can produce a database subnet grouping, which is on by default.
- FR-11: The module rejects invalid inputs with clear messages before any change is made. That covers malformed or out-of-range address ranges, subnets outside the network range, duplicate or overlapping subnets, private subnets that NAT cannot serve, invalid zone names, unsupported retention or aggregation values, malformed key identifiers and reserved tag keys.
- FR-12: The module exposes identifiers for everything it creates. Per-subnet values are keyed by subnet name. Per-zone values are keyed by availability zone.
- FR-13: Every taggable object carries `Name` and `ManagedBy = "terraform"` plus the consumer's tags.

**Non-functional requirements**:

- NFR-01: With nothing but the required inputs, the network passes CIS AWS Foundations v3.0 3.7 (flow logs) and 5.4 (default security group), and AWS Security Hub FSBP EC2.2, EC2.6, EC2.15 and CloudWatch.16.
- NFR-02: The default egress path survives the loss of one availability zone (NAT per zone).
- NFR-03: Plans must be deterministic and stable. Every repeated object is keyed by a value the consumer supplied (subnet name, availability zone, service name), never by list position.
- NFR-04: Provider compatibility is `hashicorp/aws >= 5.0, < 6.0` and Terraform `>= 1.14`. Moving to provider 6.x is a separate, scheduled change.
- NFR-05: Unit tests run with no cloud credentials.
- NFR-06: The deploying principal needs `iam:PassRole` for the flow log role. The module never handles credentials.

---

## 2. Resources & Architecture

### Architectural Decisions

**Provider pin**: `hashicorp/aws` `>= 5.0, < 6.0`, `required_version = ">= 1.14"`. The module uses only syntax that is valid in 5.x: `aws_eip.domain = "vpc"`, `aws_flow_log.log_destination`, `data.aws_region.current.name`, no per-resource `region` argument, and no `aws_iam_role.inline_policy` or `managed_policy_arns`. *Rationale*: this was a user decision. 6.x removes `aws_eip.vpc` and `aws_flow_log.log_group_name` and renames `aws_region.name` to `region`, and the upgrade is scheduled separately. *Source*: research-provider-docs.md, "5.x vs 6.x" table (hashicorp/aws 5.100.0 docs and the Version 6 Upgrade Guide). *Rejected*: `>= 5.0` alone, because it would resolve to 6.x, where `data.aws_region.current.name` is deprecated and future 6.x behaviour is untested. See the CONSTITUTION DEVIATION entry in Open Questions.

**Subnet modelling**: there is one input map per tier, keyed by subnet short name, with entries `{ cidr_block, availability_zone, tags = optional(map(string), {}) }` and `nullable = false`. Each tier gets its own `aws_subnet` resource with `for_each` over its map. *Rationale*: keys come straight from input, so they are known at plan and stable. Adding or removing one subnet touches only that address. Separate blocks per tier keep addresses readable (`aws_subnet.private["app-a"]`) and keep tier behaviour (public IP mapping, route table) free of conditionals. *Source*: research-registry-patterns.md §2 and "Alternatives" (one block per tier), and research-edge-cases.md E17 (`nullable = false` turns `null` into `{}`). *Rejected*: list inputs with `count` (terraform-aws-modules style), because index coupling renumbers subnets. A single flattened `"tier/name"` resource was also rejected because it makes addresses harder to read and needs per-tier conditionals.

**Conditional singletons use `count = <cond> ? 1 : 0`**: this covers the IGW, the public, database and intra route tables, the public IGW route, the database subnet group, and the four flow log resources and their two policy documents. Repeated objects always use `for_each`. *Rationale*: constitution §2.5 allows "conditional creation via `count` or `for_each`", and §2.4 prescribes the `try(resource[0].attr, null)` output idiom, which assumes `count`. The rule "never count for multiples" is respected because a 0/1 toggle has no index shifting. *Source*: research-edge-cases.md "Resources Identified" (the IGW, public RT and flow log resources use `count`), and research-registry-patterns.md §3 (pick one mechanism and apply it consistently). *Rejected*: `for_each = cond ? toset(["this"]) : []`. It gives addresses like `aws_iam_role.flow_logs["this"]`, adds noise, and has no stability benefit for 0/1 objects.

**Naming rule**: a resource is named `this` when at most one instance of that type can exist and it is the primary object for its purpose (VPC, default SG, IGW, DB subnet group, flow log, NAT gateway resource block). When a type exists in several tiers, the block is named by tier (`public`, `private`, `database`, `intra`). That applies to route tables, subnets and associations, where `this` could not be unique. Flow log support resources are named `flow_logs`. Gateway endpoints and their associations are named `gateway`, and NAT EIPs are named `nat`. *Source*: constitution §2.2, and research-registry-patterns.md §3 (route tables need tier names). *Rejected*: `aws_route_table.this` with a tier key, because it mixes a per-AZ private tier with singleton tiers under one `for_each`.

**NAT placement and keying**: `aws_eip.nat` and `aws_nat_gateway.this` use `for_each` keyed by **AZ name**, and exist only when `private_subnets` is non-empty. In per-AZ mode (default), NAT AZs = the distinct private-subnet AZs. With `single_nat_gateway = true`, NAT AZs = `[first sorted public AZ]`. Each NAT sits in the public subnet whose **key sorts first lexically** within that AZ. Each private AZ routes to its own AZ's NAT if one exists, otherwise to the single NAT. *Rationale*: AZ keys mean that switching `single_nat_gateway` only adds or removes the non-anchor NATs, and routes change in place (aws-ia/vpc pattern). Per-AZ NAT is AWS's AZ-independence guidance. Locals must filter defensively (skip AZs without a public subnet, guard `[0]` on empty lists) so that invalid combinations surface only through the precondition and never as a `for_each` lookup error. *Source*: research-registry-patterns.md §2(2) (aws-ia `nat_options` / `nat_per_az`), research-aws-best-practices.md §5, and research-edge-cases.md E10, E11 and E12. *Rejected*: a NAT keyed by a constant `"this"`, because switching modes would replace it and change its EIP. terraform-aws-modules' index placement was also rejected. Placing NAT in every public AZ was rejected too, because AZs with no private subnets would pay for NAT they don't use. Note: if an anchor AZ has public subnets but no private subnets, switching to per-AZ mode removes the anchor NAT. This is accepted because routes update in place.

**No separate `enable_nat_gateway` toggle**: NAT exists if and only if private subnets exist. *Rationale*: the private tier is by definition the tier with NAT egress. Subnets that need no egress belong in `intra_subnets`. A variable validation requires at least one public subnet whenever private subnets are declared. *Source*: research-edge-cases.md E9 and E14. *Rejected*: `enable_nat_gateway`, because it would let "private" silently mean "isolated" and duplicate the intra tier.

**Route table topology**: there is one public RT (`0.0.0.0/0` to the IGW via a standalone `aws_route`). Private RTs are **one per private AZ**, keyed by AZ, in both NAT modes, each with a standalone `aws_route` to `0.0.0.0/0` via NAT. There is one database RT and one intra RT, **neither with any route beyond `local`**. Every subnet is explicitly associated with its tier's RT through a per-tier `aws_route_table_association` with `for_each` keyed by subnet name. Private associations select `aws_route_table.private[<subnet AZ>]`. RTs never use inline `route` blocks. *Rationale*: per-AZ private RTs make NAT mode switches a pure route update, with no RT or association churn. Standalone routes avoid the documented conflict between inline routes and route resources and coexist with the prefix-list routes that gateway endpoints manage. Explicit associations mean no subnet falls back to the main RT. *Source*: research-registry-patterns.md §2(3), and research-provider-docs.md §6 (Gotcha 1 on inline and standalone routes, and Gotcha 2 on `nat_gateway_id` versus `gateway_id`). *Rejected*: collapsing private RTs to one in single-NAT mode (churn); database subnets sharing private RTs (gives them a NAT route, which breaks isolation); per-AZ database and intra RTs (no zonal targets).

**Gateway endpoints**: `gateway_endpoints` is a `set(string)` that is a subset of `["s3", "dynamodb"]`, default `[]`. `aws_vpc_endpoint.gateway` uses `for_each` by service with `vpc_endpoint_type = "Gateway"` and `service_name = "com.amazonaws.${data.aws_region.current.name}.<svc>"`. Attachment uses `aws_vpc_endpoint_route_table_association.gateway` with `for_each` over `setproduct(services, non-public RT keys)`, keyed `"<svc>/<rt-key>"`, where the RT keys are `private-<az>`, `database` and `intra`. `route_table_ids` is **never** set on the endpoint. *Rationale*: association keys are static strings, so they are known at plan. Adding or removing an AZ touches one association, and each association can be imported (`vpce/rtb`). Isolated tiers can reach S3 and DynamoDB without internet. *Source*: research-registry-patterns.md §2(4), research-provider-docs.md §7 (setting both causes a conflict), and research-aws-best-practices.md §1 ("Private access to AWS services"). *Rejected*: inline `route_table_ids`, because every RT change diffs the endpoint and it cannot coexist with associations. Attaching the public RT was rejected as unnecessary exposure of the prefix-list route to the internet-facing tier.

**Flow logs**: `enable_flow_logs` (default `true`) gates `aws_cloudwatch_log_group.flow_logs`, `aws_iam_role.flow_logs`, `aws_iam_role_policy.flow_logs`, `aws_flow_log.this` and the two `aws_iam_policy_document` data sources. Flow log settings: `traffic_type = "ALL"` (hardcoded), `log_destination_type = "cloud-watch-logs"`, `log_destination` = the log group ARN, and `max_aggregation_interval` from input. The log group name is deterministic (`/aws/vpc-flow-logs/<name>`), so consumers can write the KMS key policy before they apply. The IAM permissions policy is built from a **locally constructed** log group ARN (`arn:<partition>:logs:<region>:<account>:log-group:/aws/vpc-flow-logs/<name>` and the same with `:*`). *Rationale*: user decisions (ALL traffic, confused-deputy conditions, scoping to the group, no `logs:CreateLogGroup`). Building the ARN from `aws_partition`, `aws_region` and `aws_caller_identity` keeps the policy document fully known at plan, both for mock tests and for acceptance-time JSON inspection. It also avoids hard-coding `arn:aws`. *Source*: research-aws-best-practices.md §2 and §6, research-provider-docs.md §8, §9 and §10 (`log_destination` expects the ARN without `:*`, and the `:*` resource is needed for log streams), and research-edge-cases.md P1 and P5. *Rejected*: an S3 destination (out of scope). The provider doc's example policy (`Resource: "*"` plus `CreateLogGroup`) was rejected as over-privileged. `name_prefix` on the role was rejected in favour of an idempotent name (constitution §2.2), `"<name>-flow-logs-<region>"`, which includes the region because IAM is global.

**Default security group**: `aws_default_security_group.this` sets `ingress = []` and `egress = []` explicitly, with no toggle. *Rationale*: when Terraform adopts the default SG it removes all rules and keeps them removed (CIS 5.4 / EC2.2). Setting empty lists explicitly (the attributes-as-blocks form) makes intent visible and makes the planned value known and empty, so it can be tested. *Source*: research-provider-docs.md §11 and research-aws-best-practices.md §1 (EC2.2). *Rejected*: omitting the blocks (same effect, but the planned value may be unknown under mocks); a toggle to keep AWS's default rules (never a secure option).

**Public IP auto-assignment**: `map_public_ip_on_launch` (default `false`) applies only to public subnets. The other tiers hardcode `false`. *Source*: research-aws-best-practices.md §4 (EC2.15, public IPv4 charges; NAT and ALB don't need it). *Rejected*: the terraform-aws-modules default of `true`.

**Database subnet group**: `aws_db_subnet_group.this` is created when `create_database_subnet_group && length(database_subnets) > 0`. Its name is `lower("<name>-database")`. A variable validation requires at least 2 distinct AZs when the group will be created. *Source*: research-provider-docs.md §12 (RDS requires at least 2 AZs; names are lowercased). *Rejected*: always creating the group, which fails the API for single-AZ database tiers.

**Validation placement**: rules about a single variable, or across variables, live in `variable` `validation` blocks. That includes CIDR validity, host bits and prefix range; subnet containment in the VPC CIDR (the `cidrhost`/`format` idiom, because `cidrcontains` does not exist); AZ name format; private-requires-public; database multi-AZ; the retention and interval allow-lists; the KMS ARN format; and reserved tag keys. Rules that compare all tiers at once live in `lifecycle.precondition` on `aws_vpc.this`: duplicate CIDRs, pairwise overlap, and private AZ without a public subnet when `single_nat_gateway = false`. Preconditions reference only input-derived locals. Every `split`/`cidrhost` in a validation is wrapped in `try(..., false)`. No `check` blocks are used. *Source*: research-edge-cases.md §1, §2 (E1–E21) and §3, plus pitfalls P8 and P9. *Rejected*: an advisory `check` for retention below 365, because it fails `terraform test` runs unless every such run expects it, and 365 is already the default.

**Tag merging**: `local.common_tags = merge({ ManagedBy = "terraform" }, var.tags)`, so consumer tags win for everything except `Name`. Resources then use `merge(local.common_tags, { Name = <per-resource name> })`. Subnets use `merge(local.common_tags, { Name = ... }, each.value.tags)`, so per-subnet tags win, including `Name`. *Rationale*: constitution §3.3 requires `Name` and `ManagedBy`, with consumer precedence. A module-wide `Name` in `var.tags` would stamp one name on every object, so per-resource `Name` overrides it. Per-subnet tags are instance-specific consumer intent, for example Kubernetes ELB role tags. *Source*: constitution §3.3, and research-registry-patterns.md §2 (`local.tags`).

**File split**: `main.tf` (VPC, default SG, subnets, DB subnet group), `routing.tf` (IGW, EIP, NAT, route tables, routes, associations), `endpoints.tf`, `flow_logs.tf`, `data.tf`, `locals.tf`, `variables.tf`, `outputs.tf`, `versions.tf`. *Source*: constitution §2.1 (logical grouping, at most 500 lines per file).

### Resource Inventory

| Resource Type | Logical Name | Conditional | Depends On | Key Configuration | Schema Notes |
|---|---|---|---|---|---|
| `aws_vpc` | `this` | always | -- | `cidr_block = var.cidr_block`; `enable_dns_support = true`; `enable_dns_hostnames = true` (provider default is false); 3 `lifecycle.precondition`s (duplicate CIDRs, overlap, private-AZ NAT coverage); tags Name = `var.name` | -- |
| `aws_default_security_group` | `this` | always | `aws_vpc.this` | `vpc_id`; `ingress = []`; `egress = []` (strips all rules, CIS 5.4); Name `<name>-default` | `ingress` and `egress` are sets (attributes-as-blocks) |
| `aws_subnet` | `public` | `for_each = var.public_subnets` | `aws_vpc.this` | `cidr_block`, `availability_zone` from entry; `map_public_ip_on_launch = var.map_public_ip_on_launch`; Name `<name>-public-<key>` | -- |
| `aws_subnet` | `private` | `for_each = var.private_subnets` | `aws_vpc.this` | `map_public_ip_on_launch = false`; Name `<name>-private-<key>` | -- |
| `aws_subnet` | `database` | `for_each = var.database_subnets` | `aws_vpc.this` | `map_public_ip_on_launch = false`; Name `<name>-database-<key>` | -- |
| `aws_subnet` | `intra` | `for_each = var.intra_subnets` | `aws_vpc.this` | `map_public_ip_on_launch = false`; Name `<name>-intra-<key>` | -- |
| `aws_db_subnet_group` | `this` | `count`: `var.create_database_subnet_group && length(var.database_subnets) > 0` | `aws_subnet.database` | `name = lower("<name>-database")`; `description = "Database subnet group for <name>"`; `subnet_ids` = all database subnet IDs | `subnet_ids` is a set |
| `aws_internet_gateway` | `this` | `count`: `length(var.public_subnets) > 0` | `aws_vpc.this` | `vpc_id` inline (no `aws_internet_gateway_attachment`); Name `<name>` | -- |
| `aws_eip` | `nat` | `for_each = local.nat_gateways` (AZ keys) | `aws_internet_gateway.this` (explicit `depends_on`) | `domain = "vpc"` (never `vpc = true`); no `instance`/`network_interface`; Name `<name>-nat-<az>` | -- |
| `aws_nat_gateway` | `this` | `for_each = local.nat_gateways` (AZ keys) | `aws_eip.nat`, `aws_subnet.public`, `aws_internet_gateway.this` (explicit `depends_on`) | `connectivity_type = "public"`; `allocation_id = aws_eip.nat[az].allocation_id`; `subnet_id` = the public subnet whose key sorts first in that AZ (ForceNew); Name `<name>-nat-<az>` | -- |
| `aws_route_table` | `public` | `count`: `length(var.public_subnets) > 0` | `aws_vpc.this` | no inline `route`; Name `<name>-public` | `route` is a set (unused, must stay omitted) |
| `aws_route_table` | `private` | `for_each = toset(local.private_azs)` | `aws_vpc.this` | no inline `route`; Name `<name>-private-<az>` | `route` is a set (unused) |
| `aws_route_table` | `database` | `count`: `length(var.database_subnets) > 0` | `aws_vpc.this` | no routes at all (isolated); Name `<name>-database` | `route` is a set (unused) |
| `aws_route_table` | `intra` | `count`: `length(var.intra_subnets) > 0` | `aws_vpc.this` | no routes at all (isolated); Name `<name>-intra` | `route` is a set (unused) |
| `aws_route` | `public_internet_gateway` | `count`: `length(var.public_subnets) > 0` | `aws_route_table.public`, `aws_internet_gateway.this` | `destination_cidr_block = "0.0.0.0/0"`; `gateway_id` = IGW | -- |
| `aws_route` | `private_nat_gateway` | `for_each = local.private_nat_gateway_az` (private AZ => NAT AZ) | `aws_route_table.private`, `aws_nat_gateway.this` | `destination_cidr_block = "0.0.0.0/0"`; `nat_gateway_id` (never `gateway_id`, which causes a perpetual diff) | -- |
| `aws_route_table_association` | `public` | `for_each = var.public_subnets` | `aws_subnet.public`, `aws_route_table.public` | `route_table_id = aws_route_table.public[0].id` | -- |
| `aws_route_table_association` | `private` | `for_each = var.private_subnets` | `aws_subnet.private`, `aws_route_table.private` | `route_table_id = aws_route_table.private[each.value.availability_zone].id` | -- |
| `aws_route_table_association` | `database` | `for_each = var.database_subnets` | `aws_subnet.database`, `aws_route_table.database` | `route_table_id = aws_route_table.database[0].id` | -- |
| `aws_route_table_association` | `intra` | `for_each = var.intra_subnets` | `aws_subnet.intra`, `aws_route_table.intra` | `route_table_id = aws_route_table.intra[0].id` | -- |
| `aws_vpc_endpoint` | `gateway` | `for_each = var.gateway_endpoints` | `aws_vpc.this`, `data.aws_region.current` | `vpc_endpoint_type = "Gateway"`; `service_name = "com.amazonaws.<region name>.<svc>"`; **no** `route_table_ids`, no `policy` (AWS default full-access); Name `<name>-<svc>` | `route_table_ids` is a set (must stay unset) |
| `aws_vpc_endpoint_route_table_association` | `gateway` | `for_each = local.gateway_endpoint_route_tables` (keys `"<svc>/<rt-key>"`, rt-key in `private-<az>`, `database`, `intra`) | `aws_vpc_endpoint.gateway`, `aws_route_table.private` / `.database` / `.intra` | `vpc_endpoint_id`, `route_table_id` (both required) | -- |
| `aws_cloudwatch_log_group` | `flow_logs` | `count`: `var.enable_flow_logs` | -- | `name = "/aws/vpc-flow-logs/<name>"`; `retention_in_days = var.flow_log_retention_in_days`; `kms_key_id = var.kms_key_id` (ARN or null); `log_group_class` left at default `STANDARD`; `skip_destroy` default false | -- |
| `aws_iam_role` | `flow_logs` | `count`: `var.enable_flow_logs` | `data.aws_iam_policy_document.flow_logs_assume` | `name = "<name>-flow-logs-<region name>"`; `assume_role_policy` = trust doc JSON; no `inline_policy`/`managed_policy_arns` (deprecated in 5.x) | `inline_policy` is a set (unused) |
| `aws_iam_role_policy` | `flow_logs` | `count`: `var.enable_flow_logs` | `aws_iam_role.flow_logs`, `data.aws_iam_policy_document.flow_logs` | `name = "flow-logs-to-cloudwatch"`; `role = aws_iam_role.flow_logs[0].id` | -- |
| `aws_flow_log` | `this` | `count`: `var.enable_flow_logs` | `aws_vpc.this`, `aws_cloudwatch_log_group.flow_logs`, `aws_iam_role.flow_logs` | `vpc_id`; `traffic_type = "ALL"`; `log_destination_type = "cloud-watch-logs"`; `log_destination = aws_cloudwatch_log_group.flow_logs[0].arn` (never `log_group_name`); `iam_role_arn`; `max_aggregation_interval = var.flow_log_max_aggregation_interval`; Name `<name>-flow-logs` | `destination_options` is a list (S3 only, unused) |
| `data.aws_region` | `current` | always | -- | 5.x attribute `name` (not `region`) | -- |
| `data.aws_caller_identity` | `current` | always | -- | use `account_id` | -- |
| `data.aws_partition` | `current` | always | -- | use `partition` for ARNs (no hard-coded `arn:aws`) | -- |
| `data.aws_iam_policy_document` | `flow_logs_assume` | `count`: `var.enable_flow_logs` | `data.aws_region.current`, `data.aws_caller_identity.current`, `data.aws_partition.current` | one statement: `sts:AssumeRole`; principal Service `vpc-flow-logs.amazonaws.com`; condition `StringEquals aws:SourceAccount = <account>`; condition `ArnLike aws:SourceArn = arn:<partition>:ec2:<region>:<account>:vpc-flow-log/*` | `statement` is a list; `principals`, `condition`, `actions` are sets |
| `data.aws_iam_policy_document` | `flow_logs` | `count`: `var.enable_flow_logs` | `data.aws_region.current`, `data.aws_caller_identity.current`, `data.aws_partition.current` | one statement: actions `logs:CreateLogStream`, `logs:PutLogEvents`, `logs:DescribeLogGroups`, `logs:DescribeLogStreams`; resources = `local.flow_log_group_arn` and `"${local.flow_log_group_arn}:*"`; **no** `logs:CreateLogGroup`, no `*` | `statement` is a list; `actions`, `resources` are sets |

**Derived locals** (`locals.tf`, all built from input variables only, so keys are known at plan): `common_tags`; `public_azs`, `private_azs`, `database_azs`, `intra_azs` (sorted, distinct); `azs` (sorted union); `all_subnet_cidrs` (concat of all tiers); `public_subnet_key_by_az` (AZ => lexically first public key); `nat_gateway_azs` and `nat_gateways` (AZ => `{ subnet_key }`); `private_nat_gateway_az` (private AZ => NAT AZ, empty when no NAT); `flow_log_group_name`; `flow_log_group_arn`; `non_public_route_table_ids` (rt-key => RT id); `gateway_endpoint_route_tables` ("<svc>/<rt-key>" => `{ service, rt_key }`).

---

## 3. Interface Contract

### Inputs

Subnet entry type (the same for all four tiers): `map(object({ cidr_block = string, availability_zone = string, tags = optional(map(string), {}) }))`, `nullable = false`.

| Variable | Type | Required | Default | Validation | Sensitive | Description |
|---|---|---|---|---|---|---|
| `name` | `string` | Yes | -- | Matches `^[A-Za-z0-9][A-Za-z0-9-]{0,31}$` (1–32 chars, letters, digits and hyphens, starting with a letter or digit; keeps the derived IAM role name within 64 chars) | No | Name of the VPC. Used as the `Name` tag and as the prefix for every derived resource name and the flow log group. |
| `cidr_block` | `string` | Yes | -- | (1) `can(cidrnetmask(v))`, i.e. valid IPv4 CIDR; (2) network address with no host bits: `cidrhost(v,0) == split("/",v)[0]`; (3) prefix between /16 and /28 | No | IPv4 CIDR block for the VPC, e.g. `10.0.0.0/16`. |
| `public_subnets` | subnet map | No | `{}` | For every entry: (1) valid IPv4 network CIDR with prefix /16–/28 and no host bits; (2) within `var.cidr_block` (cidrhost containment idiom, wrapped in `try`); (3) `availability_zone` matches `^[a-z]{2}(-[a-z]+)+-[0-9]+[a-z]$` (AZ names, not AZ IDs) | No | Public subnets keyed by short name. They route to the internet gateway and host NAT gateways. In each AZ, the NAT goes in the subnet whose key sorts first. Adding a key that sorts earlier in the same AZ replaces that AZ's NAT and EIP. AZ values must be known at plan. |
| `private_subnets` | subnet map | No | `{}` | Rules (1)–(3) as for `public_subnets`, plus (4) `length(var.private_subnets) == 0 \|\| length(var.public_subnets) > 0` | No | Private subnets keyed by short name. They get outbound-only internet access through a NAT gateway (one route table per AZ). |
| `database_subnets` | subnet map | No | `{}` | Rules (1)–(3) as for `public_subnets`, plus (4) `!var.create_database_subnet_group \|\| length(var.database_subnets) == 0 \|\| length(distinct([for s in values(var.database_subnets) : s.availability_zone])) >= 2` | No | Isolated database subnets keyed by short name. They have no internet or NAT route. |
| `intra_subnets` | subnet map | No | `{}` | Rules (1)–(3) as for `public_subnets` | No | Fully isolated subnets keyed by short name. They have no internet or NAT route. |
| `map_public_ip_on_launch` | `bool` | No | `false` | -- | No | Auto-assign public IPv4 addresses to instances launched in **public** subnets. `true` fails Security Hub EC2.15. Other tiers always use `false`. |
| `single_nat_gateway` | `bool` | No | `false` | -- | No | Use one NAT gateway (in the first sorted public AZ) for all private subnets instead of one per AZ. This lowers cost but gives up AZ resilience. |
| `gateway_endpoints` | `set(string)` | No | `[]` | `alltrue([for s in v : contains(["s3", "dynamodb"], s)])` | No | Gateway VPC endpoints to create and attach to every private, database and intra route table (never the public one). Allowed: `s3`, `dynamodb`. |
| `create_database_subnet_group` | `bool` | No | `true` | -- | No | Create a DB subnet group from the database subnets. Only takes effect when `database_subnets` is non-empty. Requires at least 2 AZs. |
| `enable_flow_logs` | `bool` | No | `true` | -- | No | Enable VPC flow logs (all traffic) to a CloudWatch Logs group created by this module. Disabling fails CIS 3.7 / Security Hub EC2.6. |
| `flow_log_retention_in_days` | `number` | No | `365` | `contains([0,1,3,5,7,14,30,60,90,120,150,180,365,400,545,731,1096,1827,2192,2557,2922,3288,3653], v)` | No | Retention for the flow log group in days. `0` means never expire. Values under 365 fail Security Hub CloudWatch.16. |
| `flow_log_max_aggregation_interval` | `number` | No | `600` | `contains([60, 600], v)` | No | Maximum interval in seconds over which a flow is captured and aggregated into one record. |
| `kms_key_id` | `string` | No | `null` | `v == null \|\| can(regex("^arn:aws[a-z-]*:kms:[a-z0-9-]+:[0-9]{12}:key/.+$", v))` | No | ARN of a customer-managed symmetric KMS key used to encrypt the flow log group. `null` uses CloudWatch Logs service-managed encryption. The key policy must allow `logs.<region>.amazonaws.com` for log group `/aws/vpc-flow-logs/<name>`. |
| `tags` | `map(string)` | No | `{}` | `alltrue([for k in keys(v) : !startswith(lower(k), "aws:")])` | No | Tags for every taggable resource. They override `ManagedBy`. `Name` is set per resource and is not overridden from here. |

### Outputs

| Output | Type | Conditional On | Description |
|---|---|---|---|
| `vpc_id` | `string` | always | ID of the VPC. |
| `vpc_arn` | `string` | always | ARN of the VPC. |
| `vpc_cidr_block` | `string` | always | IPv4 CIDR block of the VPC. |
| `azs` | `list(string)` | always (empty when no subnets) | Sorted, distinct AZs used by any subnet. |
| `public_subnet_ids` | `map(string)` | always (empty map when none) | Public subnet IDs keyed by subnet name. |
| `public_subnet_arns` | `map(string)` | always | Public subnet ARNs keyed by subnet name. |
| `public_subnet_cidr_blocks` | `map(string)` | always | Public subnet CIDR blocks keyed by subnet name. |
| `private_subnet_ids` | `map(string)` | always | Private subnet IDs keyed by subnet name. |
| `private_subnet_arns` | `map(string)` | always | Private subnet ARNs keyed by subnet name. |
| `private_subnet_cidr_blocks` | `map(string)` | always | Private subnet CIDR blocks keyed by subnet name. |
| `database_subnet_ids` | `map(string)` | always | Database subnet IDs keyed by subnet name. |
| `database_subnet_arns` | `map(string)` | always | Database subnet ARNs keyed by subnet name. |
| `database_subnet_cidr_blocks` | `map(string)` | always | Database subnet CIDR blocks keyed by subnet name. |
| `intra_subnet_ids` | `map(string)` | always | Intra subnet IDs keyed by subnet name. |
| `intra_subnet_arns` | `map(string)` | always | Intra subnet ARNs keyed by subnet name. |
| `intra_subnet_cidr_blocks` | `map(string)` | always | Intra subnet CIDR blocks keyed by subnet name. |
| `public_route_table_id` | `string` | `public_subnets` non-empty, else `null` | ID of the public route table. |
| `private_route_table_ids` | `map(string)` | always (empty map when no private subnets) | Private route table IDs keyed by AZ. |
| `database_route_table_id` | `string` | `database_subnets` non-empty, else `null` | ID of the database route table. |
| `intra_route_table_id` | `string` | `intra_subnets` non-empty, else `null` | ID of the intra route table. |
| `internet_gateway_id` | `string` | `public_subnets` non-empty, else `null` | ID of the internet gateway. |
| `nat_gateway_ids` | `map(string)` | `private_subnets` non-empty, else empty map | NAT gateway IDs keyed by AZ. |
| `nat_public_ips` | `map(string)` | `private_subnets` non-empty, else empty map | NAT gateway Elastic IP addresses keyed by AZ. |
| `default_security_group_id` | `string` | always | ID of the VPC default security group, which is managed with no rules. |
| `gateway_endpoint_ids` | `map(string)` | `gateway_endpoints`, else empty map | Gateway VPC endpoint IDs keyed by service (`s3`, `dynamodb`). |
| `flow_log_id` | `string` | `enable_flow_logs`, else `null` | ID of the VPC flow log. |
| `flow_log_cloudwatch_log_group_name` | `string` | `enable_flow_logs`, else `null` | Name of the flow log CloudWatch Logs group. |
| `flow_log_cloudwatch_log_group_arn` | `string` | `enable_flow_logs`, else `null` | ARN of the flow log CloudWatch Logs group. |
| `flow_log_iam_role_arn` | `string` | `enable_flow_logs`, else `null` | ARN of the IAM role used by VPC Flow Logs to publish to CloudWatch Logs. |
| `database_subnet_group_name` | `string` | `create_database_subnet_group` and `database_subnets` non-empty, else `null` | Name of the DB subnet group. |

Conditional singleton outputs use `try(<resource>[0].<attr>, null)` (constitution §2.4). Map outputs use `{ for k, r in <resource> : k => r.<attr> }`. No output is sensitive.

---

## 4. Security Controls

| Control | Enforcement | Configurable? | Reference |
|---|---|---|---|
| Encryption at rest (flow log data) | CloudWatch Logs always encrypts log data at rest. When `kms_key_id` is set, the flow log group uses that customer-managed key. The default `null` uses service-managed keys, because the module does not create keys. The consumer's key policy must grant `logs.<region>.amazonaws.com`, and the README gives the statement. | Yes: `kms_key_id` (validated as a KMS key ARN) | AWS Well-Architected SEC08-BP02 (Enforce encryption at rest); AWS Config `cloudwatch-log-group-encrypted` (satisfied only when `kms_key_id` is set) |
| Encryption in transit | N/A at the network-construct level. The module neither terminates nor carries application sessions, and flow log delivery is an AWS-internal service path. Opt-in gateway endpoints keep S3 and DynamoDB traffic on the AWS network instead of the internet. Application TLS is the consumer's responsibility. | Partially: `gateway_endpoints` (default `[]`) | AWS Well-Architected SEC09-BP02 (Enforce encryption in transit); SEC05-BP02 (Control traffic flow within your network layers) |
| Public access: default security group | The default SG is adopted with `ingress = []` and `egress = []`, which removes all rules and keeps them removed. It is hardcoded because no secure use exists for default-SG rules: consumers create purpose-built SGs. | No (hardcoded) | CIS AWS Foundations v3.0 5.4; Security Hub EC2.2 |
| Public access: public IP auto-assignment | `map_public_ip_on_launch = false` by default on public subnets. It is hardcoded `false` on private, database and intra subnets, because those tiers have no IGW route and a public IP there would be meaningless or risky. | Yes (public tier only): `map_public_ip_on_launch`, default `false` | Security Hub EC2.15 and EC2.9; AWS Well-Architected SEC05-BP01 |
| Public access: tier isolation | Only the public RT has an IGW route. Private RTs have only a NAT default route, which is egress-only. Database and intra RTs have no default route. Every subnet is explicitly associated, so none falls back to the main RT. This is hardcoded because it is the definition of each tier. | No (hardcoded per tier) | AWS Well-Architected SEC05-BP01 (Create network layers) |
| Public access: default network ACL | **Not managed in v1.** The AWS default NACL allows all traffic, which fails CIS 5.1 / EC2.21. Tracked as `[DEFERRED]` in Open Questions. | N/A (deferred) | CIS AWS Foundations v3.0 5.1; Security Hub EC2.21 |
| IAM least privilege (flow log role) | Trust: only `vpc-flow-logs.amazonaws.com`, with `aws:SourceAccount` = the caller account and `aws:SourceArn` like `arn:<partition>:ec2:<region>:<account>:vpc-flow-log/*` (confused-deputy protection). Permissions: exactly 4 actions (`logs:CreateLogStream`, `logs:PutLogEvents`, `logs:DescribeLogGroups`, `logs:DescribeLogStreams`), scoped to this module's log group ARN and `ARN:*`. No `logs:CreateLogGroup`, no wildcard resource. This is hardcoded because there is no legitimate need for broader access. | No (hardcoded) | AWS Well-Architected SEC03-BP02 (Grant least privilege access); Security Hub IAM.1; IAM User Guide "Cross-service confused deputy prevention" |
| Logging: VPC flow logs | Enabled by default, with `traffic_type = "ALL"` (hardcoded, because it is a superset of the REJECT that CIS requires) to a module-owned CloudWatch Logs group. | Yes: `enable_flow_logs`, default `true` | CIS AWS Foundations v3.0 3.7; Security Hub EC2.6 |
| Logging: retention | 365 days by default, validated against the CloudWatch allowed set, including `0` (never expire). | Yes: `flow_log_retention_in_days`, default `365` | Security Hub CloudWatch.16; AWS Well-Architected SEC04-BP01 (Configure service and application logging) |
| Resilience: NAT egress | One NAT gateway per private-subnet AZ by default. Each private AZ routes to its own AZ's NAT. | Yes: `single_nat_gateway`, default `false` | AWS Well-Architected REL10-BP01 (Deploy the workload to multiple locations) |
| Tagging | All taggable resources get `Name` and `ManagedBy = "terraform"` merged with `var.tags`. Consumer tags take precedence except for `Name`. Keys with the reserved `aws:` prefix are rejected. | Yes: `tags` (additive) | Constitution §3.3; AWS Well-Architected COST03-BP02 (Add organization information to cost and usage) |
| Credentials | There are no provider blocks, credential variables or secrets. Provider configuration lives only in `examples/`. | No | Constitution §3.1; AWS Well-Architected SEC02-BP02 (Use temporary credentials) |

Every control except the deferred NACL row and the credentials row maps to at least one assertion in the Test Scenarios section. The credentials control is checked by `tflint` (`terraform_required_providers`) and by review: the root module has no `provider` block.

---

## 5. Test Scenarios

### Test Strategy

- **Module source**: tests run against the **root module directly**. `run` blocks never contain a `module {}` block. Assertions address resources as `aws_<type>.<name>...`.
- **Unit tests**: `command = plan` with this shared mock in each unit file:
  ```hcl
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
  ```
  `mock_data` is required for all four data sources. Without it, `service_name`, the role name and the policy ARNs become random strings, and the IAM JSON fails provider validation.
- **Files**:
  - `tests/unit_basic.tftest.hcl`: Secure Defaults.
  - `tests/unit_complete.tftest.hcl`: Full Features.
  - `tests/unit_edge_cases.tftest.hcl`: Feature Interactions.
  - `tests/unit_boundaries.tftest.hcl`: Validation Boundaries (positive).
  - `tests/unit_validation.tftest.hcl`: Validation Errors, **negative only**. They are split from the positive runs because a run that errors skips later runs (P7).
  - `tests/acceptance.tftest.hcl` and `tests/integration.tftest.hcl`: real provider, not run in this workflow.
- **File-level variables** for every unit file unless overridden: `name = "test"`, `cidr_block = "10.0.0.0/16"`.
- **Plan-time limitations**: IDs, ARNs, `public_ip`, and any attribute copied from another resource's computed attribute (`subnet_id`, `route_table_id`, `nat_gateway_id`, `vpc_id`, `log_destination`, `iam_role_arn`) are unknown under mocks. They are marked `[plan-unknown]`, and the test writer asserts key sets or lengths instead. Where a scenario must prove wiring, it uses a **run-level** `override_resource { target = ..., override_during = plan, values = { id = "..." } }` (P3/P6). Output maps have known keys and unknown values, so tests assert `keys(...)` and `length(...)`.
- **Set-typed blocks**: `aws_default_security_group.ingress` and `.egress` are sets, so use `length()`. In `aws_iam_policy_document`, `statement` is a list (`statement[0]`), while `principals` and `condition` are sets, so use `one()` or a `for` filter. `actions` and `resources` are sets of strings, so compare with `toset()`.

### Unit Tests

#### Scenario: Secure Defaults (basic)

**Purpose**: With only the required inputs, the module plans a VPC with DNS enabled, a closed default SG, least-privilege flow logs to an encrypted log group with 365-day retention, correct tags, and no subnet-dependent resources.
**File**: `tests/unit_basic.tftest.hcl`. **Example directory**: `examples/basic` (illustrative only; its file is not modified). **Command**: `plan` (mock providers)

**Inputs**:
```hcl
name       = "test"
cidr_block = "10.0.0.0/16"
```

**Assertions**:
1. VPC CIDR matches input: `aws_vpc.this.cidr_block == "10.0.0.0/16"`
2. DNS support is on: `aws_vpc.this.enable_dns_support == true`
3. DNS hostnames are on: `aws_vpc.this.enable_dns_hostnames == true`
4. Name tag: `aws_vpc.this.tags["Name"] == "test"`
5. ManagedBy tag: `aws_vpc.this.tags["ManagedBy"] == "terraform"`
6. Default SG has no ingress: `length(aws_default_security_group.this.ingress) == 0`
7. Default SG has no egress: `length(aws_default_security_group.this.egress) == 0`
8. Flow log is created by default: `length(aws_flow_log.this) == 1`
9. All traffic is captured: `aws_flow_log.this[0].traffic_type == "ALL"`
10. Destination is CloudWatch Logs: `aws_flow_log.this[0].log_destination_type == "cloud-watch-logs"`
11. Default aggregation interval: `aws_flow_log.this[0].max_aggregation_interval == 600`
12. Flow log destination is the module log group: `aws_flow_log.this[0].log_destination` `[plan-unknown]`. Substitute `length(aws_cloudwatch_log_group.flow_logs) == 1`.
13. Log group name is deterministic: `aws_cloudwatch_log_group.flow_logs[0].name == "/aws/vpc-flow-logs/test"`
14. Retention defaults to 365: `aws_cloudwatch_log_group.flow_logs[0].retention_in_days == 365`
15. No CMK by default (service-managed encryption): `aws_cloudwatch_log_group.flow_logs[0].kms_key_id == null`
16. Role name includes the region: `aws_iam_role.flow_logs[0].name == "test-flow-logs-us-east-1"`
17. Trust principal type: `one(data.aws_iam_policy_document.flow_logs_assume[0].statement[0].principals).type == "Service"`
18. Trust principal is only the flow logs service: `toset(one(data.aws_iam_policy_document.flow_logs_assume[0].statement[0].principals).identifiers) == toset(["vpc-flow-logs.amazonaws.com"])`
19. Trust action is AssumeRole only: `toset(data.aws_iam_policy_document.flow_logs_assume[0].statement[0].actions) == toset(["sts:AssumeRole"])`
20. SourceAccount condition: `contains(one([for c in data.aws_iam_policy_document.flow_logs_assume[0].statement[0].condition : c if c.variable == "aws:SourceAccount"]).values, "123456789012")`
21. SourceArn condition operator: `one([for c in data.aws_iam_policy_document.flow_logs_assume[0].statement[0].condition : c.test if c.variable == "aws:SourceArn"]) == "ArnLike"`
22. SourceArn condition value: `contains(one([for c in data.aws_iam_policy_document.flow_logs_assume[0].statement[0].condition : c if c.variable == "aws:SourceArn"]).values, "arn:aws:ec2:us-east-1:123456789012:vpc-flow-log/*")`
23. Permissions are exactly the four logs actions (no `CreateLogGroup`): `toset(data.aws_iam_policy_document.flow_logs[0].statement[0].actions) == toset(["logs:CreateLogStream", "logs:PutLogEvents", "logs:DescribeLogGroups", "logs:DescribeLogStreams"])`
24. Permissions are scoped to the module log group: `toset(data.aws_iam_policy_document.flow_logs[0].statement[0].resources) == toset(["arn:aws:logs:us-east-1:123456789012:log-group:/aws/vpc-flow-logs/test", "arn:aws:logs:us-east-1:123456789012:log-group:/aws/vpc-flow-logs/test:*"])`
25. Role policy is attached: `aws_iam_role_policy.flow_logs[0].name == "flow-logs-to-cloudwatch"`
26. No IGW without public subnets: `length(aws_internet_gateway.this) == 0`
27. No NAT without private subnets: `length(aws_nat_gateway.this) == 0`
28. No EIPs: `length(aws_eip.nat) == 0`
29. No gateway endpoints by default: `length(aws_vpc_endpoint.gateway) == 0`
30. No DB subnet group without database subnets: `length(aws_db_subnet_group.this) == 0`
31. Output CIDR: `output.vpc_cidr_block == "10.0.0.0/16"`
32. Output AZs is empty: `length(output.azs) == 0`
33. Output public RT id is null: `output.public_route_table_id == null`
34. Output log group name: `output.flow_log_cloudwatch_log_group_name == "/aws/vpc-flow-logs/test"`
35. Output VPC ID: `output.vpc_id` `[plan-unknown]`. Substitute assertion 1.

#### Scenario: Full Features (complete)

**Purpose**: With every tier across three AZs, per-AZ NAT, both gateway endpoints, a CMK, custom retention and aggregation, and tags, every optional resource is created, wired by the right keys, and still secure.
**File**: `tests/unit_complete.tftest.hcl`. **Example directory**: `examples/complete`. **Command**: `plan` (mock providers)

**Inputs**:
```hcl
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
```

**Assertions**:
1. Three public subnets: `length(aws_subnet.public) == 3`
2. Private subnet keys mirror input: `keys(aws_subnet.private) == ["app-a", "app-b", "app-c"]`
3. Two database subnets: `length(aws_subnet.database) == 2`
4. Two intra subnets: `length(aws_subnet.intra) == 2`
5. Subnet CIDR from input: `aws_subnet.public["web-b"].cidr_block == "10.0.1.0/24"`
6. Subnet AZ from input: `aws_subnet.private["app-c"].availability_zone == "us-east-1c"`
7. Public subnets do not auto-assign public IPs: `alltrue([for s in aws_subnet.public : s.map_public_ip_on_launch == false])`
8. Private subnets never auto-assign: `alltrue([for s in aws_subnet.private : s.map_public_ip_on_launch == false])`
9. Per-subnet tags are applied: `aws_subnet.public["web-a"].tags["kubernetes.io/role/elb"] == "1"`
10. Subnet Name convention: `aws_subnet.private["app-b"].tags["Name"] == "complete-private-app-b"`
11. Consumer tags propagate to subnets: `aws_subnet.database["db-a"].tags["Environment"] == "test"`
12. Consumer tags propagate to the VPC: `aws_vpc.this.tags["Owner"] == "platform"`
13. IGW is created: `length(aws_internet_gateway.this) == 1`
14. Public default route: `aws_route.public_internet_gateway[0].destination_cidr_block == "0.0.0.0/0"`
15. One NAT per private AZ: `toset(keys(aws_nat_gateway.this)) == toset(["us-east-1a", "us-east-1b", "us-east-1c"])`
16. NAT is public connectivity: `aws_nat_gateway.this["us-east-1a"].connectivity_type == "public"`
17. EIPs use the VPC domain: `alltrue([for e in aws_eip.nat : e.domain == "vpc"])`
18. EIP per NAT: `toset(keys(aws_eip.nat)) == toset(keys(aws_nat_gateway.this))`
19. Private RT per AZ: `keys(aws_route_table.private) == ["us-east-1a", "us-east-1b", "us-east-1c"]`
20. NAT route per private AZ: `length(aws_route.private_nat_gateway) == 3`
21. Private default route destination: `aws_route.private_nat_gateway["us-east-1b"].destination_cidr_block == "0.0.0.0/0"`
22. Private route target: `aws_route.private_nat_gateway["us-east-1b"].nat_gateway_id` `[plan-unknown]`. Wiring is proven in Feature Interactions sub-scenario 2.
23. Single database RT: `length(aws_route_table.database) == 1`
24. Single intra RT: `length(aws_route_table.intra) == 1`
25. Isolation: the only default routes are 1 public and 3 private. No route resource exists for database or intra: `length(aws_route.public_internet_gateway) + length(aws_route.private_nat_gateway) == 4`
26. Every public subnet is associated: `length(aws_route_table_association.public) == 3`
27. Every private subnet is associated: `keys(aws_route_table_association.private) == ["app-a", "app-b", "app-c"]`
28. Every database subnet is associated: `length(aws_route_table_association.database) == 2`
29. Every intra subnet is associated: `length(aws_route_table_association.intra) == 2`
30. Both endpoints are created: `toset(keys(aws_vpc_endpoint.gateway)) == toset(["s3", "dynamodb"])`
31. The S3 service name uses the region: `aws_vpc_endpoint.gateway["s3"].service_name == "com.amazonaws.us-east-1.s3"`
32. Endpoint type is Gateway: `aws_vpc_endpoint.gateway["dynamodb"].vpc_endpoint_type == "Gateway"`
33. Endpoint associations cover all 5 non-public RTs for both services: `toset(keys(aws_vpc_endpoint_route_table_association.gateway)) == toset(["s3/private-us-east-1a", "s3/private-us-east-1b", "s3/private-us-east-1c", "s3/database", "s3/intra", "dynamodb/private-us-east-1a", "dynamodb/private-us-east-1b", "dynamodb/private-us-east-1c", "dynamodb/database", "dynamodb/intra"])`
34. The public RT is never attached to an endpoint: `length([for k in keys(aws_vpc_endpoint_route_table_association.gateway) : k if endswith(k, "/public")]) == 0`
35. DB subnet group name: `aws_db_subnet_group.this[0].name == "complete-database"`
36. DB subnet group membership: `aws_db_subnet_group.this[0].subnet_ids` `[plan-unknown]`. Substitute `length(aws_db_subnet_group.this) == 1`.
37. CMK is applied to the log group: `aws_cloudwatch_log_group.flow_logs[0].kms_key_id == "arn:aws:kms:us-east-1:123456789012:key/1234abcd-12ab-34cd-56ef-1234567890ab"`
38. Custom retention: `aws_cloudwatch_log_group.flow_logs[0].retention_in_days == 731`
39. Custom aggregation: `aws_flow_log.this[0].max_aggregation_interval == 60`
40. Flow log still captures ALL: `aws_flow_log.this[0].traffic_type == "ALL"`
41. Default SG is still closed with all features on: `length(aws_default_security_group.this.ingress) == 0`
42. Output AZs: `output.azs == ["us-east-1a", "us-east-1b", "us-east-1c"]`
43. Output subnet ID keys: `keys(output.private_subnet_ids) == ["app-a", "app-b", "app-c"]`
44. Output subnet CIDR value: `output.public_subnet_cidr_blocks["web-b"] == "10.0.1.0/24"`
45. Output NAT keys: `toset(keys(output.nat_gateway_ids)) == toset(["us-east-1a", "us-east-1b", "us-east-1c"])`
46. Output NAT IP keys: `length(output.nat_public_ips) == 3`. Values are `[plan-unknown]`.
47. Output private RT keys: `keys(output.private_route_table_ids) == ["us-east-1a", "us-east-1b", "us-east-1c"]`
48. Output endpoint keys: `keys(output.gateway_endpoint_ids) == ["dynamodb", "s3"]`
49. Output DB subnet group name: `output.database_subnet_group_name == "complete-database"`
50. Output role ARN: `output.flow_log_iam_role_arn` `[plan-unknown]`. Substitute `length(aws_iam_role.flow_logs) == 1`.

#### Scenario: Feature Interactions (edge cases)

**Purpose**: Check toggle and topology combinations that gate or re-wire resources.
**File**: `tests/unit_edge_cases.tftest.hcl`. **Command**: `plan` (mock providers)

**Sub-scenario 1: single NAT serves an AZ without a public subnet**
**Inputs**:
```hcl
single_nat_gateway = true
public_subnets  = { web-a = { cidr_block = "10.0.0.0/24", availability_zone = "us-east-1a" } }
private_subnets = {
  app-a = { cidr_block = "10.0.10.0/24", availability_zone = "us-east-1a" }
  app-b = { cidr_block = "10.0.11.0/24", availability_zone = "us-east-1b" }
}
# run-level override_resource: aws_nat_gateway.this["us-east-1a"] id = "nat-0anchor" (override_during = plan)
```
**Assertions**:
- Exactly one NAT, keyed by the first public AZ: `keys(aws_nat_gateway.this) == ["us-east-1a"]`
- Exactly one EIP: `length(aws_eip.nat) == 1`
- Private RTs remain per AZ in single mode: `keys(aws_route_table.private) == ["us-east-1a", "us-east-1b"]`
- The AZ without its own NAT routes to the anchor: `aws_route.private_nat_gateway["us-east-1b"].nat_gateway_id == "nat-0anchor"`
- The anchor AZ routes to the anchor: `aws_route.private_nat_gateway["us-east-1a"].nat_gateway_id == "nat-0anchor"`

**Sub-scenario 2: per-AZ NAT placement, lexical host selection, and AZ-scoped association**
**Inputs**:
```hcl
public_subnets = {
  web-a   = { cidr_block = "10.0.0.0/24", availability_zone = "us-east-1a" }
  alpha-a = { cidr_block = "10.0.3.0/24", availability_zone = "us-east-1a" }
  web-b   = { cidr_block = "10.0.1.0/24", availability_zone = "us-east-1b" }
  web-c   = { cidr_block = "10.0.2.0/24", availability_zone = "us-east-1c" }
}
private_subnets = {
  app-a = { cidr_block = "10.0.10.0/24", availability_zone = "us-east-1a" }
  app-b = { cidr_block = "10.0.11.0/24", availability_zone = "us-east-1b" }
}
# run-level override_resource (override_during = plan):
#   aws_subnet.public["alpha-a"]         id = "subnet-0alpha"
#   aws_subnet.public["web-b"]           id = "subnet-0webb"
#   aws_route_table.private["us-east-1b"] id = "rtb-0privb"
#   aws_nat_gateway.this["us-east-1b"]   id = "nat-0b"
```
**Assertions**:
- NATs only in AZs that have private subnets (not in `us-east-1c`): `keys(aws_nat_gateway.this) == ["us-east-1a", "us-east-1b"]`
- The first-sorted key in the AZ hosts the NAT: `aws_nat_gateway.this["us-east-1a"].subnet_id == "subnet-0alpha"`
- The us-east-1b NAT sits in web-b: `aws_nat_gateway.this["us-east-1b"].subnet_id == "subnet-0webb"`
- The private subnet associates with its AZ's RT: `aws_route_table_association.private["app-b"].route_table_id == "rtb-0privb"`
- The private AZ routes to its own-AZ NAT: `aws_route.private_nat_gateway["us-east-1b"].nat_gateway_id == "nat-0b"`

**Sub-scenario 3: public-only VPC with an endpoint requested and a null map**
**Inputs**:
```hcl
public_subnets    = { web-a = { cidr_block = "10.0.0.0/24", availability_zone = "us-east-1a" } }
intra_subnets     = null
gateway_endpoints = ["s3"]
```
**Assertions**:
- IGW is created: `length(aws_internet_gateway.this) == 1`
- Public RT is created: `length(aws_route_table.public) == 1`
- No NAT without private subnets: `length(aws_nat_gateway.this) == 0`
- No private RTs: `length(aws_route_table.private) == 0`
- `nullable = false` turns null into empty: `length(aws_subnet.intra) == 0`
- The endpoint exists: `length(aws_vpc_endpoint.gateway) == 1`
- It has no associations, because only non-public RTs are eligible: `length(aws_vpc_endpoint_route_table_association.gateway) == 0`

**Sub-scenario 4: flow logs disabled suppresses every flow log object, even with KMS and retention set**
**Inputs**:
```hcl
enable_flow_logs           = false
kms_key_id                 = "arn:aws:kms:us-east-1:123456789012:key/1234abcd-12ab-34cd-56ef-1234567890ab"
flow_log_retention_in_days = 30
```
**Assertions**:
- No flow log: `length(aws_flow_log.this) == 0`
- No log group: `length(aws_cloudwatch_log_group.flow_logs) == 0`
- No role: `length(aws_iam_role.flow_logs) == 0`
- No role policy: `length(aws_iam_role_policy.flow_logs) == 0`
- No policy documents: `length(data.aws_iam_policy_document.flow_logs) == 0`
- Output flow log id is null: `output.flow_log_id == null`
- Output log group name is null: `output.flow_log_cloudwatch_log_group_name == null`
- Output role ARN is null: `output.flow_log_iam_role_arn == null`
- The default SG is still managed and closed: `length(aws_default_security_group.this.egress) == 0`

**Sub-scenario 5: single-AZ database tier without a subnet group, with the DynamoDB endpoint**
**Inputs**:
```hcl
create_database_subnet_group = false
database_subnets  = { db-a = { cidr_block = "10.0.20.0/24", availability_zone = "us-east-1a" } }
gateway_endpoints = ["dynamodb"]
```
**Assertions**:
- No DB subnet group: `length(aws_db_subnet_group.this) == 0`
- Database RT is still created: `length(aws_route_table.database) == 1`
- The database subnet is associated: `keys(aws_route_table_association.database) == ["db-a"]`
- The endpoint is attached to the database RT only: `keys(aws_vpc_endpoint_route_table_association.gateway) == ["dynamodb/database"]`
- No IGW for a database-only VPC: `length(aws_internet_gateway.this) == 0`
- Output subnet group name is null: `output.database_subnet_group_name == null`

**Sub-scenario 6: tag precedence**
**Inputs**:
```hcl
tags           = { ManagedBy = "custom-pipeline", Name = "ignored", Team = "net" }
public_subnets = { web-a = { cidr_block = "10.0.0.0/24", availability_zone = "us-east-1a", tags = { Name = "custom-web-a" } } }
```
**Assertions**:
- Consumer tags override ManagedBy: `aws_vpc.this.tags["ManagedBy"] == "custom-pipeline"`
- The per-resource Name beats `var.tags` Name: `aws_vpc.this.tags["Name"] == "test"`
- The per-resource Name on the route table: `aws_route_table.public[0].tags["Name"] == "test-public"`
- The per-subnet tag overrides Name: `aws_subnet.public["web-a"].tags["Name"] == "custom-web-a"`
- Consumer tags reach the log group: `aws_cloudwatch_log_group.flow_logs[0].tags["Team"] == "net"`

#### Scenario: Validation Boundaries (accept)

**Purpose**: Check that validations do not over-reject. Each case is its own `run` with `command = plan` and the listed assertion.
**File**: `tests/unit_boundaries.tftest.hcl`. **Command**: `plan` (mock providers)

**Boundary-pass cases**:
- `name = "a"` (minimum length 1) is accepted: `aws_vpc.this.tags["Name"] == "a"`
- `name = "abcdefghijklmnopqrstuvwxyz-12345"` (maximum length 32) is accepted, and the role name stays within 64 characters: `aws_iam_role.flow_logs[0].name == "abcdefghijklmnopqrstuvwxyz-12345-flow-logs-us-east-1"`
- `cidr_block = "10.0.0.0/28"` (largest allowed prefix) with `intra_subnets = { only = { cidr_block = "10.0.0.0/28", availability_zone = "us-east-1a" } }` (a subnet equal to the VPC CIDR is contained) is accepted: `aws_subnet.intra["only"].cidr_block == "10.0.0.0/28"`
- `cidr_block = "10.0.0.0/16"` with `intra_subnets = { whole = { cidr_block = "10.0.0.0/16", ... "us-east-1a" } }` (smallest allowed subnet prefix /16) is accepted: `aws_subnet.intra["whole"].cidr_block == "10.0.0.0/16"`
- `intra_subnets = { last = { cidr_block = "10.0.255.240/28", availability_zone = "us-east-1a" } }` (the last block inside the VPC) is accepted: `aws_subnet.intra["last"].cidr_block == "10.0.255.240/28"`
- `intra_subnets = { lo = { "10.0.0.0/25", "us-east-1a" }, hi = { "10.0.0.128/25", "us-east-1a" } }` (adjacent blocks do not overlap) is accepted: `length(aws_subnet.intra) == 2`
- `intra_subnets = { gov = { cidr_block = "10.0.0.0/24", availability_zone = "us-gov-west-1a" } }` (multi-segment region AZ name) is accepted: `aws_subnet.intra["gov"].availability_zone == "us-gov-west-1a"`
- `database_subnets` in exactly 2 distinct AZs (`us-east-1a`, `us-east-1b`) with the default subnet group is accepted: `length(aws_db_subnet_group.this) == 1`
- `private_subnets` with exactly 1 public subnet in the same AZ is accepted: `length(aws_nat_gateway.this) == 1`
- `gateway_endpoints = ["dynamodb"]` (single allowed value) is accepted: `keys(aws_vpc_endpoint.gateway) == ["dynamodb"]`
- `flow_log_retention_in_days = 0` (never expire; lowest allowed) is accepted: `aws_cloudwatch_log_group.flow_logs[0].retention_in_days == 0`
- `flow_log_retention_in_days = 1` (lowest finite value) is accepted: `aws_cloudwatch_log_group.flow_logs[0].retention_in_days == 1`
- `flow_log_retention_in_days = 3653` (highest allowed) is accepted: `aws_cloudwatch_log_group.flow_logs[0].retention_in_days == 3653`
- `flow_log_max_aggregation_interval = 60` (lower allowed value) is accepted: `aws_flow_log.this[0].max_aggregation_interval == 60`
- `kms_key_id = "arn:aws-us-gov:kms:us-gov-west-1:123456789012:key/1234abcd-12ab-34cd-56ef-1234567890ab"` (non-commercial partition) is accepted: `aws_cloudwatch_log_group.flow_logs[0].kms_key_id == "arn:aws-us-gov:kms:us-gov-west-1:123456789012:key/1234abcd-12ab-34cd-56ef-1234567890ab"`
- `tags = { "myaws:key" = "v" }` (`aws:` appears but not as a prefix) is accepted: `aws_vpc.this.tags["myaws:key"] == "v"`
- `map_public_ip_on_launch = true` with one public subnet (explicit opt-in) is accepted: `aws_subnet.public["web-a"].map_public_ip_on_launch == true`

#### Scenario: Validation Errors (reject)

**Purpose**: Check that invalid inputs are rejected before any resource is planned. Each case is its own `run` with `command = plan` and `expect_failures`. Base variables: `name = "test"`, `cidr_block = "10.0.0.0/16"`. Where a case needs a valid public subnet to isolate the failure, it adds `public_subnets = { web-a = { cidr_block = "10.0.0.0/24", availability_zone = "us-east-1a" } }`.
**File**: `tests/unit_validation.tftest.hcl`. **Command**: `plan` (mock providers)

**Expect error cases**:
- `name = ""` fails `[var.name]` with "name must be 1-32 characters"
- `name = "my_vpc!"` fails `[var.name]` with "letters, digits and hyphens"
- `name = "abcdefghijklmnopqrstuvwxyz-123456"` (33 chars) fails `[var.name]`
- `cidr_block = "10.0.0.300/16"` fails `[var.cidr_block]` with "valid IPv4 CIDR"
- `cidr_block = "2001:db8::/56"` (IPv6) fails `[var.cidr_block]` with "valid IPv4 CIDR"
- `cidr_block = "10.0.0.1/16"` (host bits) fails `[var.cidr_block]` with "network address"
- `cidr_block = "10.0.0.0/15"` fails `[var.cidr_block]` with "between /16 and /28"
- `cidr_block = "10.0.0.0/29"` fails `[var.cidr_block]` with "between /16 and /28"
- `public_subnets = { web-a = { cidr_block = "10.1.0.0/24", availability_zone = "us-east-1a" } }` (outside the VPC) fails `[var.public_subnets]` with "within cidr_block"
- `private_subnets = { app-a = { cidr_block = "10.0.10.1/24", ... "us-east-1a" } }` plus a valid public subnet (host bits) fails `[var.private_subnets]`
- `database_subnets = { db-a = { cidr_block = "10.0.20.0/29", ... }, db-b = { cidr_block = "10.0.21.0/24", ... "us-east-1b" } }` (/29) fails `[var.database_subnets]`
- `intra_subnets = { i = { cidr_block = "10.0.30.0/24", availability_zone = "use1-az1" } }` (AZ ID, not a name) fails `[var.intra_subnets]` with "availability zone name"
- `private_subnets = { app-a = { cidr_block = "10.0.10.0/24", availability_zone = "us-east-1a" } }` with no public subnets fails `[var.private_subnets]` with "require at least one public subnet"
- `database_subnets` all in `us-east-1a` (2 entries) with the default `create_database_subnet_group = true` fails `[var.database_subnets]` with "at least 2 availability zones"
- `gateway_endpoints = ["s3", "ec2"]` fails `[var.gateway_endpoints]` with "s3, dynamodb"
- `flow_log_retention_in_days = 42` fails `[var.flow_log_retention_in_days]`
- `flow_log_retention_in_days = -1` fails `[var.flow_log_retention_in_days]`
- `flow_log_max_aggregation_interval = 120` fails `[var.flow_log_max_aggregation_interval]`
- `kms_key_id = "alias/my-key"` fails `[var.kms_key_id]` with "KMS key ARN"
- `kms_key_id = "1234abcd-12ab-34cd-56ef-1234567890ab"` (bare key ID) fails `[var.kms_key_id]`
- `tags = { "aws:foo" = "bar" }` fails `[var.tags]` with "aws: prefix is reserved"
- Duplicate CIDR across tiers: public `web-a` `10.0.0.0/24` plus intra `i` `10.0.0.0/24` fails `[aws_vpc.this]` with "must be unique"
- Overlapping CIDRs: public `web-a` `10.0.0.0/20` plus intra `i` `10.0.1.0/24` fails `[aws_vpc.this]` with "must not overlap"
- Private AZ without a public subnet in per-AZ mode: public `web-a` (us-east-1a) plus private `app-b` `10.0.11.0/24` (us-east-1b), `single_nat_gateway = false`, fails `[aws_vpc.this]` with "needs a public subnet in the same AZ"

### Acceptance Tests

Real provider, `command = plan`, `provider "aws" { region = "us-east-1" }`, and each run is marked `# acceptance`. The file is created but not run in this workflow.

#### Scenario: Plan Verification

**Purpose**: Check the values that mocks cannot produce: real region and account resolution, and real policy JSON.
**File**: `tests/acceptance.tftest.hcl`. **Command**: `plan` (real providers)

**Inputs**: the Full Features inputs without `kms_key_id`, because the key must exist in the account.

**Assertions**:
- The service name uses the real region: `aws_vpc_endpoint.gateway["s3"].service_name == "com.amazonaws.us-east-1.s3"`
- Trust policy JSON restricts the principal: `jsondecode(data.aws_iam_policy_document.flow_logs_assume[0].json).Statement[0].Principal.Service == "vpc-flow-logs.amazonaws.com"`
- Permissions policy JSON has no CreateLogGroup: `!contains(flatten([jsondecode(data.aws_iam_policy_document.flow_logs[0].json).Statement[0].Action]), "logs:CreateLogGroup")`
- The permissions resource is the log group ARN: `contains(flatten([jsondecode(data.aws_iam_policy_document.flow_logs[0].json).Statement[0].Resource]), "arn:aws:logs:us-east-1:${data.aws_caller_identity.current.account_id}:log-group:/aws/vpc-flow-logs/complete")`
- The role name uses the real region: `aws_iam_role.flow_logs[0].name == "complete-flow-logs-us-east-1"`

### Integration Tests

Real provider, `command = apply`, each run marked `# integration`. The file is created but not run in this workflow, because it creates billable NAT gateways and EIPs.

#### Scenario: End-to-End

**Purpose**: Check that real resources are created, wired, and torn down cleanly.
**File**: `tests/integration.tftest.hcl`. **Command**: `apply` (real providers)

**Inputs**: `name = "tftest-vpc"`, `cidr_block = "10.42.0.0/16"`, 2 public, 2 private, 2 database and 1 intra subnets across `us-east-1a` and `us-east-1b`, `gateway_endpoints = ["s3"]`.

**Assertions**:
- The VPC ID is real: `startswith(output.vpc_id, "vpc-")`
- NAT per AZ: `length(output.nat_gateway_ids) == 2`
- NAT public IPs are allocated: `alltrue([for ip in values(output.nat_public_ips) : can(cidrhost("${ip}/32", 0))])`
- The flow log exists: `startswith(output.flow_log_id, "fl-")`
- The default SG has no ingress rules after apply: `length(aws_default_security_group.this.ingress) == 0`
- The default SG has no egress rules after apply: `length(aws_default_security_group.this.egress) == 0`
- The S3 endpoint has a prefix list: `startswith(aws_vpc_endpoint.gateway["s3"].prefix_list_id, "pl-")`
- The DB subnet group exists: `output.database_subnet_group_name == "tftest-vpc-database"`

---

## 6. Implementation Checklist

- [x] **A: Scaffold and interface**: update `versions.tf` (`required_version = ">= 1.14"`; aws `hashicorp/aws` `">= 5.0, < 6.0"`). Create `data.tf` (region, caller identity, partition). Write `variables.tf` with every input, type, default, `nullable = false` and all validation blocks from the Interface Contract. Write `locals.tf` with all derived maps (tags, AZ sets, NAT host and target maps, flow log name and ARN, endpoint association map), filtering defensively so that bad combinations surface only through the preconditions. Files: `versions.tf`, `data.tf`, `variables.tf`, `locals.tf`.
- [x] **B: Tests first (TDD)**: write the unit test files from the Test Scenarios section with the shared mock provider block and run-level `override_resource` where specified. Write the acceptance and integration test files (not executed). Delete the placeholder `tests/validate.tftest.hcl`, which runs `apply` against a real provider and can no longer plan without the required inputs. Files: `tests/unit_basic.tftest.hcl`, `tests/unit_complete.tftest.hcl`, `tests/unit_edge_cases.tftest.hcl`, `tests/unit_boundaries.tftest.hcl`, `tests/unit_validation.tftest.hcl`, `tests/acceptance.tftest.hcl`, `tests/integration.tftest.hcl`, and delete `tests/validate.tftest.hcl`.
- [ ] **C: Security core and network foundation**: in `main.tf`, write `aws_vpc.this` (DNS flags and the three preconditions), `aws_default_security_group.this` (empty ingress and egress), the four `aws_subnet` tiers, and `aws_db_subnet_group.this`. In `flow_logs.tf`, write the two policy documents, the log group, role, role policy and flow log. Add inline comments that cite CIS 5.4, EC2.15 and the confused-deputy conditions. Files: `main.tf`, `flow_logs.tf`.
- [ ] **D: Routing, egress and endpoints**: in `routing.tf`, write the IGW, `aws_eip.nat`, `aws_nat_gateway.this` (with `depends_on` on the IGW), the four route table tiers, the two `aws_route` resources and the four association tiers. In `endpoints.tf`, write `aws_vpc_endpoint.gateway` and `aws_vpc_endpoint_route_table_association.gateway`. Files: `routing.tf`, `endpoints.tf`.
- [ ] **E: Outputs**: write all 30 outputs from the Interface Contract with descriptions, using `try(x[0].attr, null)` for conditional singletons and `for` maps for keyed resources. Unit tests must pass after this item (`terraform test`). Files: `outputs.tf`.
- [ ] **F: Complete example**: write a runnable `examples/complete` with `provider "aws" { region = var.region }` and a terraform block with the same constraints. Include an `aws_kms_key` whose policy grants `logs.<region>.amazonaws.com` scoped by `kms:EncryptionContext:aws:logs:arn` to `/aws/vpc-flow-logs/<name>`, and `module "vpc" { source = "../../" }` with every input set, as in the Full Features scenario. Pass through key outputs. `examples/basic/main.tf` is **not modified**. Files: `examples/complete/main.tf`, `examples/complete/variables.tf`, `examples/complete/outputs.tf`, `examples/complete/versions.tf`, `examples/complete/README.md`.
- [ ] **G: Pre-commit tooling**: add `.pre-commit-config.yaml`. The repo has no config, so the installed git hook fails. Use `antonbabenko/pre-commit-terraform` hooks (`terraform_fmt`, `terraform_validate`, `terraform_tflint`, `terraform_docs`, `terraform_trivy`) plus `pre-commit-hooks` basics (trailing whitespace, end-of-file) and `yamllint` using the existing `.yamllint.yml`. Files: `.pre-commit-config.yaml`.
- [ ] **H: Polish and validation**: regenerate `README.md` with `terraform-docs` (inject mode, `.terraform-docs.yml`), and add a short hand-written section outside the markers covering the KMS key policy statement, `iam:PassRole`, the NAT host-selection rule and the default NACL caveat. Create `CHANGELOG.md` (v0.1.0 / Unreleased entry). Run `terraform fmt -recursive`, `terraform validate`, `terraform test`, `tflint --recursive`, `trivy config .` (no Critical or High) and `pre-commit run -a`. Files: `README.md`, `CHANGELOG.md`.

---

## 7. Open Questions

- **[DEFERRED] Default network ACL is not managed**: the AWS default NACL allows all inbound and outbound traffic, so every VPC from this module fails CIS AWS Foundations v3.0 5.1 / Security Hub EC2.21 (ingress from 0.0.0.0/0 to 22/3389), and `trivy` may flag it. Options: (a) a v1.x follow-up that adopts `aws_default_network_acl` with explicit deny rules for 22 and 3389 from `0.0.0.0/0` before an allow-all, behind a secure-default toggle; (b) document it as a known finding and leave it to account-level controls. **Recommendation: (a) as a follow-up issue.** Custom NACLs are out of scope for v1, and adopting the default NACL changes the traffic behaviour of every subnet, which needs its own tests.
- **[DEFERRED] NAT replacement when an earlier-sorting public subnet key is added to an AZ**: NAT host selection is "first public key in the AZ, lexically", and `aws_nat_gateway.subnet_id` is ForceNew. So adding e.g. `alpha-a` next to `web-a` in `us-east-1a` replaces that AZ's NAT and its EIP, and the public egress IP changes. It is documented in the `public_subnets` description. A possible later non-breaking addition is `nat_gateway = optional(bool, false)` on public subnet entries to pin the host explicitly, validated to at most one per AZ.
- **[DEFERRED] Scoping of `logs:DescribeLogGroups`**: the user decision scopes all four actions to the module log group ARN (and `:*`). research-aws-best-practices.md states that `DescribeLogGroups` does not support single-group resource scoping. The tightest alternative is `arn:<partition>:logs:<region>:<account>:log-group:*`, for that action only. Verify flow log delivery (no `access error` status on the flow log) in the sandbox integration apply. Widen only that one action, in its own statement, if delivery fails.
- **[DEFERRED] Spot-check AWS citations**: the AWS documentation citations in the research files (Security Hub control IDs EC2.2, EC2.6, EC2.15, EC2.21 and CloudWatch.16, the CIS v3.0 numbering, the Well-Architected BP IDs, and the flow logs IAM and CloudWatch Logs KMS pages) were not fetched live during research. Spot-check them before release. The provider schema facts were checked against hashicorp/aws 5.100.0 and are not in question.
- **[CONSTITUTION DEVIATION] §4.1 Provider constraints ("MUST use `>=` ... not `~>`")**: the module declares `version = ">= 5.0, < 6.0"`. *Research*: hashicorp/aws 6.0 deprecates `data.aws_region.name` (the only spelling valid in 5.x) and changes several resources (research-provider-docs.md "5.x vs 6.x"). *Justification*: the user deliberately pinned below 6.0 so that consumers cannot resolve 6.x until the scheduled upgrade, which is tested separately. The constraint still uses `>=` for the minimum and adds only an upper bound. Needs platform team acknowledgement per §8.2.
- **[CONSTITUTION DEVIATION] §5.3 Test organization**: validation tests are split into `unit_validation.tftest.hcl` (reject only) and `unit_boundaries.tftest.hcl` (accept only) instead of one `unit_validation` file. *Research*: research-edge-cases.md P7, where an erroring run causes later runs in the same file to be skipped. *Justification*: isolation keeps positive boundary cases from being masked by negative ones. The category mapping is unchanged.
