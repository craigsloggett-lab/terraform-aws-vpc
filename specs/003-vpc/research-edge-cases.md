## Research: What edge cases and validation rules should the design cover, and how should they be tested with mock providers in plan mode?

> Everything below was checked against the local toolchain: **Terraform v1.15.2** (linux_arm64) and **hashicorp/aws 5.100.0** (the latest release that satisfies `>= 5.0, < 6.0`). I built a throwaway prototype module in the scratchpad (not in the repo) and ran the snippets below with `terraform test`. They all pass unless marked as a negative example.

### Decision

Validate each input on its own **and** across inputs with `variable` `validation` blocks (cross-variable references have been allowed since Terraform 1.9). Put checks that need to compare many subnets at once (duplicate or overlapping CIDRs, AZ coverage for NAT) in **`lifecycle.precondition` on `aws_vpc.this`**. Use a **`check` block** only for advisory rules. Unit tests use `mock_provider "aws"` with `command = plan`, `expect_failures` for negative cases, `mock_data` for `aws_iam_policy_document` (required), `aws_region` and `aws_caller_identity`, and `override_during = plan` only where a test must assert a provider-computed ID.

### Resources Identified

- **Primary Resource**: `aws_vpc` — also holds the cross-subnet `precondition`s (duplicate/overlap/AZ coverage)
- **Supporting Resources** (the ones relevant to edge cases):
  - `aws_subnet` (public/private/database/intra, `for_each` over input maps; keys are known at plan)
  - `aws_internet_gateway`, `aws_route_table.public`, `aws_route.public_internet` — `count = length(var.public_subnets) > 0 ? 1 : 0`
  - `aws_eip`, `aws_nat_gateway` — `for_each` keyed by **AZ name** (static, known at plan)
  - `aws_route.private_nat` — `for_each` over private subnet keys; empty when there is no NAT
  - `aws_cloudwatch_log_group`, `aws_iam_role`, `aws_iam_role_policy`, `aws_flow_log` — `count = var.enable_flow_logs ? 1 : 0`
  - `data.aws_iam_policy_document`, `data.aws_region`, `data.aws_caller_identity` (and `data.aws_partition` if used for ARNs) — each needs a `mock_data` entry
  - `aws_vpc_endpoint` (S3/DynamoDB Gateway) — `service_name` built from `data.aws_region.current.name`
- **Key Arguments**: `cidr_block`, subnet maps `{ cidr_block, availability_zone, tags = optional(map(string), {}) }` with `nullable = false`, `single_nat_gateway`, `flow_log_retention_in_days`, `kms_key_id`
- **Key Outputs**: output maps keyed by subnet key (`map(string)`) so keys stay known at plan. IDs are unknown at plan (`[plan-unknown]`).
- **Security Considerations**: the retention allow-list includes `0` (never expire). Keeping ≥365 for flow logs is a compliance goal (CIS/FSBP log retention). `kms_key_id` must be a KMS **key ARN** for CloudWatch Logs, not a key ID or alias.

---

### 1. Verified function availability (Terraform 1.15.2 console)

| Expression | Result | Notes |
|---|---|---|
| `cidrcontains("10.0.0.0/16","10.0.1.0/24")` | **Error: Call to unknown function** | **`cidrcontains` does NOT exist** in Terraform core. The AWS provider v5 functions are only `arn_parse`, `arn_build`, `trim_iam_role_path`. Emulate it (see below). |
| `can(cidrhost("10.0.0.300/16",0))` | `false` | Rejects a malformed address |
| `can(cidrhost("foo",0))` | `false` | |
| `can(cidrhost("2001:db8::/56",0))` | `true` | `cidrhost` accepts IPv6 |
| `can(cidrnetmask("2001:db8::/56"))` | `false` | **`cidrnetmask` is IPv4-only**, so it is the better IPv4 validity test |
| `can(cidrnetmask("10.0.0.0/33"))` | `false` | Rejects an out-of-range prefix |
| `cidrhost("10.0.1.5/16",0)` | `"10.0.0.0"` | `cidrhost` silently masks host bits, so you need an explicit network-address check |
| `cidrhost("10.0.1.5/24",0) == split("/","10.0.1.5/24")[0]` | `false` | Detects host bits that are set |

**Containment idiom (replaces `cidrcontains`)**. Subnet `s` is inside VPC `v` iff `prefix(s) >= prefix(v)` and masking `s`'s network address to `v`'s prefix gives `v`'s network address:

```hcl
tonumber(split("/", s)[1]) >= tonumber(split("/", v)[1]) &&
cidrhost(format("%s/%s", cidrhost(s, 0), split("/", v)[1]), 0) == cidrhost(v, 0)
```

I checked this against VPC `10.0.0.0/16`: `10.0.1.0/24` gives true, `10.0.255.240/28` gives true, `10.1.0.0/24` gives false, and `10.0.0.0/8` gives false (the subnet is larger than the VPC).

**Overlap idiom**: two CIDRs overlap iff the one with the shorter prefix contains the other. So you run the containment test in both directions over every pair.

---

### 2. Edge-case catalogue and where each rule should live

| # | Edge case | Mechanism | Why here | Test target |
|---|---|---|---|---|
| E1 | `name` is empty or whitespace | `validation` on `var.name` | Single variable | `expect_failures = [var.name]` |
| E2 | `cidr_block` is malformed or IPv6 | `validation`: `can(cidrnetmask(var.cidr_block))` | Single variable | `[var.cidr_block]` |
| E3 | `cidr_block` has host bits set (`10.0.0.1/16`) | `validation`: `cidrhost(x,0) == split("/",x)[0]` | The AWS API normalises or rejects it. Better to fail clearly | `[var.cidr_block]` |
| E4 | VPC prefix outside `/16`–`/28` | `validation` on the prefix range | AWS limit for the IPv4 VPC CIDR | `[var.cidr_block]` |
| E5 | Subnet CIDR malformed, has host bits, or prefix outside `/16`–`/28` | `validation` on each subnet map (`alltrue([...])`) | Single variable | `[var.public_subnets]` etc. |
| E6 | Subnet CIDR outside the VPC CIDR | **Cross-variable `validation`** on each subnet map (refers to `var.cidr_block`) | TF ≥ 1.9 allows it, and the error is attributed to the offending variable | `[var.private_subnets]` |
| E7 | Duplicate subnet CIDRs **across** tiers | **`precondition` on `aws_vpc.this`** | Needs all four maps at once. Putting it in a variable would mean repeating it in four places | `[aws_vpc.this]` |
| E8 | Overlapping subnet CIDRs (e.g. `/20` contains `/24`) | `precondition` on `aws_vpc.this` (pairwise) | Same reason as E7 | `[aws_vpc.this]` |
| E9 | Private subnets but **zero** public subnets (no IGW, so NAT has nowhere to go) | **Cross-variable `validation`** on `var.private_subnets`: `length(var.private_subnets) == 0 \|\| length(var.public_subnets) > 0` | Clear, early, attributed to the variable | `[var.private_subnets]` |
| E10 | Private subnet in an AZ with **no public subnet** while `single_nat_gateway = false` (that AZ's NAT has no subnet) | `precondition` on `aws_vpc.this`: `var.single_nat_gateway \|\| length(setsubtract(private_azs, public_azs)) == 0` | Set arithmetic over two maps. Easier to read in a `precondition` that uses `locals`. Stops a `for_each` lookup error (`aws_nat_gateway.this[az]` missing key) | `[aws_vpc.this]` |
| E11 | Same as E10 with `single_nat_gateway = true` | **Allowed**: one NAT in the first public AZ (sorted) serves everything | Cross-AZ NAT is legal and costs less, but it is not AZ-resilient | Positive test: 1 NAT, one route per private subnet |
| E12 | Several public subnets in one AZ | Pick the NAT host deterministically: `sort([for k,s in var.public_subnets : k if s.availability_zone == az])[0]` | Keeps the plan stable when keys are added | Assert NAT keys |
| E13 | All subnet maps empty (defaults) | `count`/`for_each` produce 0 IGW, 0 NAT, 0 EIP, 0 routes. The VPC, flow logs and endpoints (with no route tables, or the main RT only) remain | Must plan cleanly | Assert `length(...) == 0` |
| E14 | Public subnets only | 1 IGW, 1 public RT and route, **0 NAT** | NAT is only needed when there are private subnets | Assert counts |
| E15 | Intra subnets | Route table with **no** default route | The isolated tier | Assert `length(aws_route.intra) == 0` or no such resource |
| E16 | Database subnets | NAT route is a design choice. If the module creates `aws_db_subnet_group`, that needs subnets in **at least 2 AZs**, which is another cross-variable validation to consider | RDS requirement | `[var.database_subnets]` |
| E17 | Subnet map passed as `null` | `nullable = false` + `default = {}`, so `null` becomes `{}` | Verified: `public_subnets = null` plans with 0 subnets | Positive test |
| E18 | Invalid `availability_zone` | `validation` regex `^[a-z]{2}(-[a-z]+)+-[0-9]+[a-z]$` | Accepts `us-east-1a` and `us-gov-west-1a`. Rejects AZ IDs (`use1-az1`) and Local Zones (`us-west-2-lax-1a`). Document this limit or loosen the regex | `[var.public_subnets]` |
| E19 | `flow_log_retention_in_days` not in the allowed set (e.g. 42, -1) | `validation` with `contains([...])` | See the exact list below | `[var.flow_log_retention_in_days]` |
| E20 | Retention below 365 (compliance) | Optional `check` block (warning outside tests) | Advisory. The consumer may accept it | `[check.<name>]` |
| E21 | `kms_key_id` not a key ARN | `validation`: `var.kms_key_id == null \|\| can(regex("^arn:aws[a-z-]*:kms:[a-z0-9-]+:[0-9]{12}:key/.+$", var.kms_key_id))` | CloudWatch Logs `kms_key_id` requires the ARN. The key policy must also grant `logs.<region>.amazonaws.com` (not something the module can check) | `[var.kms_key_id]` |
| E22 | `enable_flow_logs = false` | Log group, role, policy and flow log all `count = 0`. Retention and KMS become irrelevant | | Assert counts are 0 |

**Retention allow-list** (provider docs, `aws_cloudwatch_log_group.retention_in_days`): `0, 1, 3, 5, 7, 14, 30, 60, 90, 120, 150, 180, 365, 400, 545, 731, 1096, 1827, 2192, 2557, 2922, 3288, 3653`. `0` means never expire. Decide whether to allow `0`: it is compliant (retained forever) but unbounded in cost. Note that the provider's own validator also rejects bad values, **but it attributes the error to the resource, not the variable**, so keep the variable validation.

#### Validation vs precondition vs check: summary

- **`validation`**: the rule depends only on input variables, including other variables (TF ≥ 1.9). It fails first, blames a specific input, and is testable with `expect_failures = [var.x]`. Use it for E1–E6, E9, E16, E18, E19 and E21.
- **`precondition`** (on `aws_vpc.this` or the resource the rule protects): the rule needs `locals` that combine several variables (duplicates, overlaps, AZ coverage). It blocks the plan and is testable with `expect_failures = [aws_vpc.this]`. **Pitfall**: if a precondition depends on an **unknown** value at plan time it is deferred, so it passes silently in mocked plan tests. Keep these conditions input-only, as all of E7, E8 and E10 are.
- **`check`**: advisory only. In normal plan/apply it is a warning, but **in `terraform test` an unexpected failed `check` fails the run**. Verified: the run failed with "Check block assertion failed" until `expect_failures = [check.retention_compliance]` was added. Do not use `check` for E9/E10: those are hard errors that would otherwise produce broken routing or a `for_each` key lookup error.

---

### 3. Reference validation code (verified)

```hcl
variable "cidr_block" {
  type = string
  validation {
    condition     = can(cidrnetmask(var.cidr_block))
    error_message = "cidr_block must be a valid IPv4 CIDR (e.g. 10.0.0.0/16)."
  }
  validation {
    condition     = try(cidrhost(var.cidr_block, 0) == split("/", var.cidr_block)[0], false)
    error_message = "cidr_block must be a network address with no host bits set."
  }
  validation {
    condition     = try(tonumber(split("/", var.cidr_block)[1]) >= 16 && tonumber(split("/", var.cidr_block)[1]) <= 28, false)
    error_message = "cidr_block prefix length must be between /16 and /28."
  }
}

variable "private_subnets" {
  type = map(object({
    cidr_block        = string
    availability_zone = string
    tags              = optional(map(string), {})
  }))
  default  = {}
  nullable = false

  validation { # E5
    condition = alltrue([for k, s in var.private_subnets :
      can(cidrnetmask(s.cidr_block)) && try(cidrhost(s.cidr_block, 0) == split("/", s.cidr_block)[0], false)
    ])
    error_message = "Every private subnet cidr_block must be a valid IPv4 network address."
  }
  validation { # E6 - cross-variable (TF >= 1.9)
    condition = alltrue([for k, s in var.private_subnets :
      try(
        tonumber(split("/", s.cidr_block)[1]) >= tonumber(split("/", var.cidr_block)[1]) &&
        cidrhost(format("%s/%s", cidrhost(s.cidr_block, 0), split("/", var.cidr_block)[1]), 0) == cidrhost(var.cidr_block, 0),
      false)
    ])
    error_message = "Every private subnet cidr_block must fall within var.cidr_block."
  }
  validation { # E9 - cross-variable
    condition     = length(var.private_subnets) == 0 || length(var.public_subnets) > 0
    error_message = "private_subnets require at least one public subnet to host a NAT gateway."
  }
}
```

Wrap every `split(...)[1]` or `cidrhost` in `try(..., false)`. Otherwise a malformed CIDR makes the *containment* validation raise an evaluation error instead of a clean validation failure. Each validation block is evaluated independently.

```hcl
locals {
  all_subnet_cidrs = concat(
    [for s in values(var.public_subnets) : s.cidr_block],
    [for s in values(var.private_subnets) : s.cidr_block],
    [for s in values(var.database_subnets) : s.cidr_block],
    [for s in values(var.intra_subnets) : s.cidr_block],
  )
  public_azs  = toset([for s in values(var.public_subnets) : s.availability_zone])
  private_azs = toset([for s in values(var.private_subnets) : s.availability_zone])

  # E12: deterministic NAT host subnet per AZ
  nat_subnet_key_by_az = {
    for az in local.public_azs :
    az => sort([for k, s in var.public_subnets : k if s.availability_zone == az])[0]
  }
  # AZ-keyed map => known keys at plan time
  nat_gateways = length(var.private_subnets) == 0 ? {} : (
    var.single_nat_gateway
    ? { (sort(keys(local.nat_subnet_key_by_az))[0]) = local.nat_subnet_key_by_az[sort(keys(local.nat_subnet_key_by_az))[0]] }
    : { for az in local.private_azs : az => local.nat_subnet_key_by_az[az] if contains(keys(local.nat_subnet_key_by_az), az) }
  )
}

resource "aws_vpc" "this" {
  # ...
  lifecycle {
    precondition { # E7
      condition     = length(local.all_subnet_cidrs) == length(distinct(local.all_subnet_cidrs))
      error_message = "Subnet CIDR blocks must be unique across all subnet tiers."
    }
    precondition { # E8 pairwise overlap
      condition = alltrue(flatten([
        for i, a in local.all_subnet_cidrs : [
          for j, b in local.all_subnet_cidrs : i >= j || !(
            tonumber(split("/", a)[1]) <= tonumber(split("/", b)[1])
            ? cidrhost(format("%s/%s", cidrhost(b, 0), split("/", a)[1]), 0) == cidrhost(a, 0)
            : cidrhost(format("%s/%s", cidrhost(a, 0), split("/", b)[1]), 0) == cidrhost(b, 0)
          )
        ]
      ]))
      error_message = "Subnet CIDR blocks must not overlap."
    }
    precondition { # E10
      condition     = var.single_nat_gateway || length(setsubtract(local.private_azs, local.public_azs)) == 0
      error_message = "Each private subnet AZ needs a public subnet in the same AZ unless single_nat_gateway = true."
    }
  }
}
```

A note on E7 and E8: an exact duplicate also counts as an overlap, so E8 alone catches E7. Keep both anyway because the duplicate message is clearer. Pairwise overlap is O(n²), which is fine for fewer than about 100 subnets.

---

### 4. Mock provider pitfalls in `command = plan` (all reproduced locally)

| # | Pitfall | Observed behaviour | Remedy |
|---|---|---|---|
| P1 | `aws_iam_policy_document.json` is mocked as a random string | **The plan fails**: `Error: "assume_role_policy" contains an invalid JSON policy: not a JSON object`. The mock provider still runs the real provider's **config validation**. | `mock_data "aws_iam_policy_document" { defaults = { json = "{\"Version\":\"2012-10-17\",\"Statement\":[]}" } }` |
| P2 | Computed resource attributes (`aws_vpc.this.id`, `aws_subnet.x.id`, `arn`) | **Unknown at plan.** Asserting on them gives `Error: Unknown condition value`, even `!= null` | Assert on inputs (`cidr_block`, `availability_zone`, tags, counts, keys). Or add `override_during = plan` together with `mock_resource`/`override_resource` values |
| P3 | `override_during = plan` without a value for that attribute | Only attributes **given in** `mock_resource`/`override_resource` become known. With only `aws_vpc` mocked, `aws_subnet.public["a"].id` stayed unknown | Mock every resource type whose ID you want to assert. Use `override_resource { target = aws_subnet.public["b"] }` to get **distinct** per-instance IDs (a `mock_resource` default gives every instance the same ID) |
| P4 | `for_each` over values that come from resource IDs, e.g. `toset([for s in aws_subnet.public : s.id])` | **Plan fails**: `Invalid for_each argument ... cannot be determined until apply` | Always use `for_each` over **input-derived keys** (subnet map keys, AZ names). Put IDs only in *values* (`subnet_id = aws_subnet.public[each.key].id`) |
| P5 | Data sources (`aws_region`, `aws_caller_identity`) | Mocked data **is known at plan** without `override_during`. Without `mock_data` the values are random strings, e.g. `service_name = "com.amazonaws.<random>.s3"` | `mock_data "aws_region" { defaults = { name = "us-east-1" } }` (use `name` on provider v5; v6 renames it to `region`) and `mock_data "aws_caller_identity" { defaults = { account_id = "123456789012" } }` |
| P6 | Comparing two unknown values (`aws_nat_gateway.this["b"].subnet_id == aws_subnet.public["b"].id`) | `Unknown condition value` | `override_resource` on the subnet with `override_during = plan`, then compare with a literal |
| P7 | A run errors (not an assertion failure) | Later runs in the same file are **skipped** | Put negative `expect_failures` tests in a separate file from positive tests, or make sure every run is independent |
| P8 | A `check` block fails during a test | The run **fails** unless `expect_failures = [check.name]` is set | Every scenario that trips an advisory check must expect it |
| P9 | A precondition over unknown values | Deferred at plan, so it passes silently | Keep precondition conditions input-only |

---

### 5. Example `.tftest.hcl` snippets (verified passing)

**`tests/unit_validation.tftest.hcl`**: negative cases only (see P7)

```hcl
mock_provider "aws" {
  mock_data "aws_iam_policy_document" {
    defaults = { json = "{\"Version\":\"2012-10-17\",\"Statement\":[]}" }
  }
  mock_data "aws_region" {
    defaults = { name = "us-east-1" }
  }
  mock_data "aws_caller_identity" {
    defaults = { account_id = "123456789012" }
  }
}

variables {
  name       = "test"
  cidr_block = "10.0.0.0/16"
}

run "rejects_malformed_vpc_cidr" {
  command         = plan
  variables { cidr_block = "10.0.0.300/16" }
  expect_failures = [var.cidr_block]
}

run "rejects_vpc_cidr_host_bits" {
  command         = plan
  variables { cidr_block = "10.0.0.1/16" }
  expect_failures = [var.cidr_block]
}

run "rejects_vpc_prefix_out_of_range" {
  command         = plan
  variables { cidr_block = "10.0.0.0/8" }
  expect_failures = [var.cidr_block]
}

run "rejects_subnet_outside_vpc" {
  command = plan
  variables {
    public_subnets = { a = { cidr_block = "10.1.0.0/24", availability_zone = "us-east-1a" } }
  }
  expect_failures = [var.public_subnets]
}

run "rejects_private_without_public" {
  command = plan
  variables {
    private_subnets = { a = { cidr_block = "10.0.10.0/24", availability_zone = "us-east-1a" } }
  }
  expect_failures = [var.private_subnets]
}

run "rejects_duplicate_cidrs_across_tiers" {
  command = plan
  variables {
    public_subnets  = { a = { cidr_block = "10.0.0.0/24", availability_zone = "us-east-1a" } }
    private_subnets = { a = { cidr_block = "10.0.0.0/24", availability_zone = "us-east-1a" } }
  }
  expect_failures = [aws_vpc.this]
}

run "rejects_overlapping_cidrs" {
  command = plan
  variables {
    public_subnets  = { a = { cidr_block = "10.0.0.0/20", availability_zone = "us-east-1a" } }
    private_subnets = { a = { cidr_block = "10.0.1.0/24", availability_zone = "us-east-1a" } }
  }
  expect_failures = [aws_vpc.this]
}

run "rejects_private_az_without_public_when_multi_nat" {
  command = plan
  variables {
    public_subnets  = { a = { cidr_block = "10.0.0.0/24", availability_zone = "us-east-1a" } }
    private_subnets = { b = { cidr_block = "10.0.10.0/24", availability_zone = "us-east-1b" } }
  }
  expect_failures = [aws_vpc.this]
}

run "rejects_unsupported_retention" {
  command         = plan
  variables { flow_log_retention_in_days = 42 }
  expect_failures = [var.flow_log_retention_in_days]
}
```

**`tests/unit_edge_cases.tftest.hcl`**: positive cases, counts and keys

```hcl
mock_provider "aws" {
  mock_data "aws_iam_policy_document" {
    defaults = { json = "{\"Version\":\"2012-10-17\",\"Statement\":[]}" }
  }
  mock_data "aws_region" {
    defaults = { name = "us-east-1" }
  }
  mock_data "aws_caller_identity" {
    defaults = { account_id = "123456789012" }
  }
}

# Distinct, plan-known ID for one subnet instance (P3/P6)
override_resource {
  target          = aws_subnet.public["b"]
  override_during = plan
  values          = { id = "subnet-bbbb" }
}

variables {
  name       = "test"
  cidr_block = "10.0.0.0/16"
}

run "empty_maps_create_no_routing" {
  command = plan
  assert {
    condition     = length(aws_subnet.public) == 0 && length(aws_subnet.private) == 0
    error_message = "No subnets expected with empty maps."
  }
  assert {
    condition     = length(aws_internet_gateway.this) == 0 && length(aws_nat_gateway.this) == 0 && length(aws_eip.nat) == 0
    error_message = "No IGW/NAT/EIP expected with empty maps."
  }
  assert {
    condition     = length(aws_route.private_nat) == 0
    error_message = "No NAT routes expected with empty maps."
  }
}

run "null_map_treated_as_empty" {
  command = plan
  variables { public_subnets = null }
  assert {
    condition     = length(aws_subnet.public) == 0
    error_message = "nullable = false should coerce null to {}."
  }
}

run "nat_per_az_keys_and_placement" {
  command = plan
  variables {
    public_subnets = {
      a = { cidr_block = "10.0.0.0/24", availability_zone = "us-east-1a" }
      b = { cidr_block = "10.0.1.0/24", availability_zone = "us-east-1b" }
    }
    private_subnets = {
      a = { cidr_block = "10.0.10.0/24", availability_zone = "us-east-1a" }
      b = { cidr_block = "10.0.11.0/24", availability_zone = "us-east-1b" }
    }
  }
  assert {
    condition     = toset(keys(aws_nat_gateway.this)) == toset(["us-east-1a", "us-east-1b"])
    error_message = "Expected one NAT gateway per private-subnet AZ."
  }
  assert {
    condition     = keys(aws_subnet.private) == ["a", "b"]
    error_message = "Private subnet keys must mirror input map keys."
  }
  assert {
    condition     = aws_nat_gateway.this["us-east-1b"].subnet_id == "subnet-bbbb"
    error_message = "NAT in us-east-1b must sit in public subnet b."
  }
  assert {
    condition     = aws_route.private_nat["a"].destination_cidr_block == "0.0.0.0/0"
    error_message = "Private route table must default-route to NAT."
  }
}

run "single_nat_serves_az_without_public" {
  command = plan
  variables {
    single_nat_gateway = true
    public_subnets  = { a = { cidr_block = "10.0.0.0/24", availability_zone = "us-east-1a" } }
    private_subnets = {
      a = { cidr_block = "10.0.10.0/24", availability_zone = "us-east-1a" }
      b = { cidr_block = "10.0.11.0/24", availability_zone = "us-east-1b" }
    }
  }
  assert {
    condition     = length(aws_nat_gateway.this) == 1 && length(aws_eip.nat) == 1
    error_message = "single_nat_gateway must create exactly one NAT + EIP."
  }
  assert {
    condition     = length(aws_route.private_nat) == 2
    error_message = "Every private subnet needs a NAT route."
  }
}

run "gateway_endpoint_uses_mocked_region" {
  command = plan
  assert {
    condition     = aws_vpc_endpoint.s3.service_name == "com.amazonaws.us-east-1.s3"
    error_message = "S3 endpoint service name must use the current region."
  }
}
```

**Advisory `check` test pattern** (P8):

```hcl
run "short_retention_warns" {
  command         = plan
  variables { flow_log_retention_in_days = 30 }
  expect_failures = [check.flow_log_retention_compliance]
}
```

**Assertion tips**
- Counts: `length(aws_subnet.private)` works for both `for_each` (map) and `count` (list) resources.
- Keys: `keys(aws_subnet.private) == ["a","b"]` (sorted), or `toset(keys(...)) == toset([...])`.
- Specific instances: `aws_subnet.private["a"].cidr_block` (known) and `aws_subnet.private["a"].availability_zone` (known). `.id` and `.arn` are `[plan-unknown]` unless overridden.
- Outputs: `output.private_subnet_ids` is a map with known **keys** but unknown values, so assert `keys(output.private_subnet_ids)` or `length(...)`, never the values.

### Rationale

- The claims about functions are backed by `terraform console` on 1.15.2. `cidrcontains` is absent, so the `cidrhost`/`format` idiom is required. `cidrnetmask` is the IPv4-only validity test.
- Cross-variable validation (Terraform 1.9+) gives errors attributed to the offending variable, which is better than preconditions for single-map rules. Preconditions are kept for rules that combine several maps.
- The provider docs (aws 5.100.0, `aws_cloudwatch_log_group`) give the exact retention set and say `kms_key_id` is "The ARN of the KMS Key".
- The mock-provider behaviours (P1–P9) were all reproduced. The key surprise is that **provider-side config validation still runs under `mock_provider`**, so mocked `aws_iam_policy_document.json` must be valid JSON.
- AWS VPC docs: IPv4 VPC and subnet CIDRs must be `/16`–`/28`, and AWS reserves 5 addresses per subnet. A NAT gateway lives in one AZ, and AWS recommends one per AZ for resilience, which is why the per-AZ NAT is keyed by AZ.

### Alternatives Considered

| Alternative | Why Not |
| --- | --- |
| `cidrcontains()` | Does not exist in Terraform 1.14/1.15 core or in the AWS provider v5 functions |
| `check` block for NAT reachability (E9/E10) | Only a warning outside tests. Broken routing, or a `for_each` key lookup error, would still happen |
| Precondition for "subnet outside VPC" | Works, but blames `aws_vpc.this` instead of the offending variable. Cross-variable validation is clearer |
| Relying on provider validation for retention | The error is attributed to `aws_cloudwatch_log_group.this[0]` rather than the variable, and the message is less clear |
| `for_each` NAT/route resources keyed by subnet IDs | Unknown at plan, giving `Invalid for_each argument` (P4) |
| `override_during = plan` globally for every test | Hides real unknown-value problems. Use it only in the runs that assert IDs |
| Allowing AZ IDs (`use1-az1`) | `aws_subnet.availability_zone` expects names. Supporting `availability_zone_id` would be a separate interface choice |

### Sources

- Local verification: Terraform v1.15.2 `terraform console` and `terraform test` against a prototype using hashicorp/aws 5.100.0 with `mock_provider`
- Provider docs: hashicorp/aws 5.100.0, `aws_cloudwatch_log_group` (retention values, `kms_key_id` ARN), `aws_subnet`, `aws_db_subnet_group` (≥2 AZs)
- Terraform docs, input variable validation (cross-object references since v1.9): https://developer.hashicorp.com/terraform/language/values/variables#custom-validation-rules
- Terraform docs, custom conditions (preconditions and check blocks): https://developer.hashicorp.com/terraform/language/expressions/custom-conditions
- Terraform docs, tests and mocking (`mock_provider`, `mock_data`, `override_resource`, `override_during`): https://developer.hashicorp.com/terraform/language/tests/mocking
- Terraform docs, `cidrhost` / `cidrnetmask`: https://developer.hashicorp.com/terraform/language/functions/cidrhost
- AWS VPC subnet sizing (`/16`–`/28`, 5 reserved IPs): https://docs.aws.amazon.com/vpc/latest/userguide/subnet-sizing.html
- AWS NAT gateways (zonal, one per AZ recommended): https://docs.aws.amazon.com/vpc/latest/userguide/vpc-nat-gateway.html
