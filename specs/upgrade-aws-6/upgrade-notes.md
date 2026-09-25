# Upgrade Notes: hashicorp/aws 5.x to 6.x

- Guide: "Terraform AWS Provider Version 6 Upgrade Guide", registry doc ID `13746811` (provider docs at 6.66.0).
- Tracking issue: #7. Branch: `upgrade/aws-6`. Supersedes Dependabot PR #6.
- Latest 6.x release: `6.66.0`.

## Constraint

| File | Before | After |
|------|--------|-------|
| `versions.tf` | `>= 5.0, < 6.0` | `>= 6.0, < 7.0` |
| `examples/complete/versions.tf` | `>= 5.0, < 6.0` | `6.66.0` (exact pin, newest 6.x) |

`examples/basic` pins the registry module (`0.0.1`) and has no `versions.tf`; unchanged.

## Guide entries that hit the module

| Guide entry | file:line | Required change | Plan effect |
|-------------|-----------|-----------------|-------------|
| Data Source `aws_region`: `name` deprecated, use `region` | `endpoints.tf:20` | `data.aws_region.current.name` → `.region` | none (same value; guide states a rename only) |
| same | `flow_logs.tf:35` | `.name` → `.region` | none |
| same | `flow_logs.tf:81` | `.name` → `.region` | none |
| same | `flow_logs.tf:86` | `.name` → `.region` | none |
| same | `locals.tf:77` | `.name` → `.region` | none |
| same | `examples/complete/main.tf:10` | `.name` → `.region` | none |
| same | `tests/unit_{basic,boundaries,complete,edge_cases,validation}.tftest.hcl` `mock_data "aws_region"` | mock `defaults = { region = "us-east-1" }` instead of `name` | n/a (tests) |
| Resource `aws_eip`: `vpc` removed, use `domain` | `routing.tf:23` | none; already `domain = "vpc"` | none |
| Resource `aws_flow_log`: `log_group_name` removed, use `log_destination` | `flow_logs.tf:105-106` | none; already `log_destination` | none |
| Enhanced Region Support: `region` added to most resources | all resources | none; module does not set `region` | unverified (the guide describes the new argument but not its state upgrade; expected to be a no-op defaulting to the provider region) |
| Prerequisites: constraint style | `versions.tf:7` | bump constraint | n/a |

No other guide entry names a resource, data source, or attribute used by this module (checked: `aws_vpc`, `aws_subnet`, `aws_internet_gateway`, `aws_nat_gateway`, `aws_route*`, `aws_default_security_group`, `aws_db_subnet_group`, `aws_vpc_endpoint*`, `aws_cloudwatch_log_group`, `aws_iam_role*`, `aws_iam_policy_document`, `aws_caller_identity`, `aws_partition`). No provider `endpoints` or `s3_us_east_1_regional_endpoint` arguments are used.

## Deprecations that are not yet removals

- `data.aws_region.name`: deprecated in 6.x, not removed. Fixed now (the only one that hits), since `region` is the 6.x attribute and the constraint no longer admits 5.x where `region` did not exist.

## Replacement or unverified effects

- No replacement.
- Unverified: Enhanced Region Support state upgrade (no-op expected).
