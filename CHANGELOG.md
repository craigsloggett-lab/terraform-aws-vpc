# Changelog

All notable changes to this module are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Changed

- **BREAKING:** Requires `hashicorp/aws` `>= 6.0, < 7.0` (was `>= 5.0, < 6.0`). Consumers must allow the 6.x provider.
- Region lookups use the `aws_region` data source's `region` attribute in place of the deprecated `name`. Resolved values (endpoint service names, flow log IAM role name and trust policy, flow log group ARN) do not change.
- `examples/complete` pins `hashicorp/aws` `6.66.0`.

### Added

- Initial release of the AWS VPC module (`hashicorp/aws` `>= 5.0, < 6.0`, Terraform `>= 1.14`).
- VPC with DNS support and hostnames enabled, and the default security group adopted with no rules (CIS 5.4).
- Four subnet tiers keyed by name (`public`, `private`, `database`, `intra`), with auto-assign public IP disabled by default (EC2.15).
- Internet gateway and public route table when public subnets exist.
- NAT gateways with Elastic IPs, one per private-subnet AZ or a single shared gateway (`single_nat_gateway`), placed in the lexically first public subnet key per AZ.
- One private route table per AZ. Database and intra route tables have no internet or NAT route.
- Optional DB subnet group for the database subnets.
- Gateway VPC endpoints (`s3`, `dynamodb`) attached to the private, database and intra route tables.
- VPC flow logs (all traffic) to a CloudWatch Logs group, enabled by default, with 365-day retention and optional customer-managed KMS encryption (`kms_key_id`). The least-privilege IAM role has confused-deputy conditions.
- Input validation and preconditions for CIDRs, AZ coverage, NAT hosting and DB subnet group requirements.
- `examples/complete` with a scoped KMS key. Unit, acceptance and integration tests.

### Known limitations

- The default network ACL is not managed (CIS 5.1 / EC2.21).
- Adding a public subnet key that sorts earlier in an AZ replaces that AZ's NAT gateway and EIP.
