# Upgrade Report: hashicorp/aws 5.x to 6.x

Governing guide: "Terraform AWS Provider Version 6 Upgrade Guide" (registry doc `13746811`). Notes: [upgrade-notes.md](upgrade-notes.md). Issue: #7.

## What changed

| Change | Files | Guide entry |
|--------|-------|-------------|
| Constraint `>= 5.0, < 6.0` → `>= 6.0, < 7.0` | `versions.tf` | Prerequisites to Upgrade to v6.0.0 |
| `data.aws_region.current.name` → `.region` | `endpoints.tf:20`, `flow_logs.tf:35,81,86`, `locals.tf:77` | Data Source `aws_region` (`name` deprecated, use `region`) |
| Same, in the example | `examples/complete/main.tf:10` | Data Source `aws_region` |
| Example provider pinned to `6.66.0` (latest 6.x) | `examples/complete/versions.tf` | Prerequisites |
| Test mocks set `region` instead of `name` on `mock_data "aws_region"` | `tests/unit_*.tftest.hcl` (5 files) | Data Source `aws_region` |
| CHANGELOG `Unreleased` entry; README requirements table regenerated and provider note rewritten | `CHANGELOG.md`, `README.md` | Documentation of the above |

Checked, no change needed:

- Resource `aws_eip`: `vpc` removed. The module already uses `domain = "vpc"`.
- Resource `aws_flow_log`: `log_group_name` removed. The module already uses `log_destination`.
- Enhanced Region Support: the module sets no `region` argument on any resource.

No resource address changed, so no `moved` blocks were added.

## Test results (provider 6.66.0, Terraform 1.15.2)

| File | Result |
|------|--------|
| `tests/unit_basic.tftest.hcl` | pass (1 run) |
| `tests/unit_boundaries.tftest.hcl` | pass (7 runs) |
| `tests/unit_complete.tftest.hcl` | pass |
| `tests/unit_edge_cases.tftest.hcl` | pass (6 runs) |
| `tests/unit_validation.tftest.hcl` | pass (24 runs) |
| `tests/acceptance.tftest.hcl` | **not run**: no AWS credentials in this environment |
| `tests/integration.tftest.hcl` | **not run**: no AWS credentials in this environment |

Totals: 49 passed, 0 failed, 2 skipped (the two credentialed files). `terraform validate` passes for the root module and for `examples/complete`.

## Consumer impact

- **Constraint:** consumers must allow `hashicorp/aws` `>= 6.0, < 7.0` and run `terraform init -upgrade`. The guide asks that consumers first reach the latest 5.x with a clean plan and no deprecation warnings.
- **Expected plan effect for an already-deployed consumer:**
  - `aws_vpc_endpoint.this`, `aws_iam_role.flow_logs`, `aws_iam_role_policy.flow_logs`: no change. The region string is the same value read from a renamed attribute.
  - `aws_eip.nat`, `aws_flow_log.this`: no change. They already used the 6.x-compatible arguments.
  - All resources: 6.x adds a computed `region` argument (Enhanced Region Support). The expected result is no diff because it defaults to the provider region. **unverified**: the guide does not describe the state upgrade.
  - No replacements are expected.
- **`moved` / `import` on the consumer side:** none required.
- The consumer's uplift pipeline plan remains the authority for destroy or replace detection.
