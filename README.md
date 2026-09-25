# terraform-aws-vpc

A Terraform module to deploy a VPC with subnets, NAT gateways, and flow logs to AWS.

<!-- BEGIN_TF_DOCS -->
## Usage

### main.tf
```hcl
# tflint-ignore: terraform_required_version
module "vpc" {
  source  = "app.terraform.io/craigsloggett-lab/vpc/aws"
  version = "0.0.1"
}
```

## Requirements

| Name | Version |
|------|---------|
| <a name="requirement_terraform"></a> [terraform](#requirement\_terraform) | >= 1.14 |
| <a name="requirement_aws"></a> [aws](#requirement\_aws) | >= 5.0, < 6.0 |

## Providers

| Name | Version |
|------|---------|
| <a name="provider_aws"></a> [aws](#provider\_aws) | >= 5.0, < 6.0 |

## Inputs

| Name | Description | Type | Default | Required |
|------|-------------|------|---------|:--------:|
| <a name="input_cidr_block"></a> [cidr\_block](#input\_cidr\_block) | IPv4 CIDR block for the VPC, e.g. `10.0.0.0/16`. | `string` | n/a | yes |
| <a name="input_create_database_subnet_group"></a> [create\_database\_subnet\_group](#input\_create\_database\_subnet\_group) | Create a DB subnet group from the database subnets. Only takes effect when `database_subnets` is non-empty. Requires at least 2 AZs. | `bool` | `true` | no |
| <a name="input_database_subnets"></a> [database\_subnets](#input\_database\_subnets) | Isolated database subnets keyed by short name. They have no internet or NAT route. | <pre>map(object({<br/>    cidr_block        = string<br/>    availability_zone = string<br/>    tags              = optional(map(string), {})<br/>  }))</pre> | `{}` | no |
| <a name="input_enable_flow_logs"></a> [enable\_flow\_logs](#input\_enable\_flow\_logs) | Enable VPC flow logs (all traffic) to a CloudWatch Logs group created by this module. Disabling fails CIS 3.7 / Security Hub EC2.6. | `bool` | `true` | no |
| <a name="input_flow_log_max_aggregation_interval"></a> [flow\_log\_max\_aggregation\_interval](#input\_flow\_log\_max\_aggregation\_interval) | Maximum interval in seconds over which a flow is captured and aggregated into one record. | `number` | `600` | no |
| <a name="input_flow_log_retention_in_days"></a> [flow\_log\_retention\_in\_days](#input\_flow\_log\_retention\_in\_days) | Retention for the flow log group in days. `0` means never expire. Values under 365 fail Security Hub CloudWatch.16. | `number` | `365` | no |
| <a name="input_gateway_endpoints"></a> [gateway\_endpoints](#input\_gateway\_endpoints) | Gateway VPC endpoints to create and attach to every private, database and intra route table (never the public one). Allowed: `s3`, `dynamodb`. | `set(string)` | `[]` | no |
| <a name="input_intra_subnets"></a> [intra\_subnets](#input\_intra\_subnets) | Fully isolated subnets keyed by short name. They have no internet or NAT route. | <pre>map(object({<br/>    cidr_block        = string<br/>    availability_zone = string<br/>    tags              = optional(map(string), {})<br/>  }))</pre> | `{}` | no |
| <a name="input_kms_key_id"></a> [kms\_key\_id](#input\_kms\_key\_id) | ARN of a customer-managed symmetric KMS key used to encrypt the flow log group. `null` uses CloudWatch Logs service-managed encryption. The key policy must allow `logs.<region>.amazonaws.com` for log group `/aws/vpc-flow-logs/<name>`. | `string` | `null` | no |
| <a name="input_map_public_ip_on_launch"></a> [map\_public\_ip\_on\_launch](#input\_map\_public\_ip\_on\_launch) | Auto-assign public IPv4 addresses to instances launched in public subnets. `true` fails Security Hub EC2.15. Other tiers always use `false`. | `bool` | `false` | no |
| <a name="input_name"></a> [name](#input\_name) | Name of the VPC. Used as the `Name` tag and as the prefix for every derived resource name and the flow log group. | `string` | n/a | yes |
| <a name="input_private_subnets"></a> [private\_subnets](#input\_private\_subnets) | Private subnets keyed by short name. They get outbound-only internet access through a NAT gateway (one route table per AZ). | <pre>map(object({<br/>    cidr_block        = string<br/>    availability_zone = string<br/>    tags              = optional(map(string), {})<br/>  }))</pre> | `{}` | no |
| <a name="input_public_subnets"></a> [public\_subnets](#input\_public\_subnets) | Public subnets keyed by short name. They route to the internet gateway and host NAT gateways. In each AZ, the NAT goes in the subnet whose key sorts first. Adding a key that sorts earlier in the same AZ replaces that AZ's NAT and EIP. AZ values must be known at plan. | <pre>map(object({<br/>    cidr_block        = string<br/>    availability_zone = string<br/>    tags              = optional(map(string), {})<br/>  }))</pre> | `{}` | no |
| <a name="input_single_nat_gateway"></a> [single\_nat\_gateway](#input\_single\_nat\_gateway) | Use one NAT gateway (in the first sorted public AZ) for all private subnets instead of one per AZ. This lowers cost but gives up AZ resilience. | `bool` | `false` | no |
| <a name="input_tags"></a> [tags](#input\_tags) | Tags for every taggable resource. They override `ManagedBy`. `Name` is set per resource and is not overridden from here. | `map(string)` | `{}` | no |

## Resources

| Name | Type |
|------|------|
| [aws_cloudwatch_log_group.flow_logs](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/cloudwatch_log_group) | resource |
| [aws_db_subnet_group.this](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/db_subnet_group) | resource |
| [aws_default_security_group.this](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/default_security_group) | resource |
| [aws_eip.nat](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/eip) | resource |
| [aws_flow_log.this](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/flow_log) | resource |
| [aws_iam_role.flow_logs](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_role) | resource |
| [aws_iam_role_policy.flow_logs](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_role_policy) | resource |
| [aws_internet_gateway.this](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/internet_gateway) | resource |
| [aws_nat_gateway.this](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/nat_gateway) | resource |
| [aws_route.private_nat_gateway](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/route) | resource |
| [aws_route.public_internet_gateway](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/route) | resource |
| [aws_route_table.database](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/route_table) | resource |
| [aws_route_table.intra](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/route_table) | resource |
| [aws_route_table.private](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/route_table) | resource |
| [aws_route_table.public](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/route_table) | resource |
| [aws_route_table_association.database](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/route_table_association) | resource |
| [aws_route_table_association.intra](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/route_table_association) | resource |
| [aws_route_table_association.private](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/route_table_association) | resource |
| [aws_route_table_association.public](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/route_table_association) | resource |
| [aws_subnet.database](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/subnet) | resource |
| [aws_subnet.intra](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/subnet) | resource |
| [aws_subnet.private](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/subnet) | resource |
| [aws_subnet.public](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/subnet) | resource |
| [aws_vpc.this](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/vpc) | resource |
| [aws_vpc_endpoint.gateway](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/vpc_endpoint) | resource |
| [aws_vpc_endpoint_route_table_association.gateway](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/vpc_endpoint_route_table_association) | resource |
| [aws_caller_identity.current](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/caller_identity) | data source |
| [aws_iam_policy_document.flow_logs](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/iam_policy_document) | data source |
| [aws_iam_policy_document.flow_logs_assume](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/iam_policy_document) | data source |
| [aws_partition.current](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/partition) | data source |
| [aws_region.current](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/region) | data source |

## Outputs

| Name | Description |
|------|-------------|
| <a name="output_azs"></a> [azs](#output\_azs) | Sorted, distinct availability zones used by any subnet tier. Empty when no subnets are defined. |
| <a name="output_database_route_table_id"></a> [database\_route\_table\_id](#output\_database\_route\_table\_id) | ID of the database route table. Null when no database subnets are defined. |
| <a name="output_database_subnet_arns"></a> [database\_subnet\_arns](#output\_database\_subnet\_arns) | Database subnet ARNs keyed by subnet name. |
| <a name="output_database_subnet_cidr_blocks"></a> [database\_subnet\_cidr\_blocks](#output\_database\_subnet\_cidr\_blocks) | Database subnet CIDR blocks keyed by subnet name. |
| <a name="output_database_subnet_group_name"></a> [database\_subnet\_group\_name](#output\_database\_subnet\_group\_name) | Name of the DB subnet group. Null unless create\_database\_subnet\_group is true and database subnets are defined. |
| <a name="output_database_subnet_ids"></a> [database\_subnet\_ids](#output\_database\_subnet\_ids) | Database subnet IDs keyed by subnet name. |
| <a name="output_default_security_group_id"></a> [default\_security\_group\_id](#output\_default\_security\_group\_id) | ID of the VPC default security group, which is managed with no rules. |
| <a name="output_flow_log_cloudwatch_log_group_arn"></a> [flow\_log\_cloudwatch\_log\_group\_arn](#output\_flow\_log\_cloudwatch\_log\_group\_arn) | ARN of the flow log CloudWatch Logs group. Null when flow logs are disabled. |
| <a name="output_flow_log_cloudwatch_log_group_name"></a> [flow\_log\_cloudwatch\_log\_group\_name](#output\_flow\_log\_cloudwatch\_log\_group\_name) | Name of the flow log CloudWatch Logs group. Null when flow logs are disabled. |
| <a name="output_flow_log_iam_role_arn"></a> [flow\_log\_iam\_role\_arn](#output\_flow\_log\_iam\_role\_arn) | ARN of the IAM role used by VPC Flow Logs to publish to CloudWatch Logs. Null when flow logs are disabled. |
| <a name="output_flow_log_id"></a> [flow\_log\_id](#output\_flow\_log\_id) | ID of the VPC flow log. Null when flow logs are disabled. |
| <a name="output_gateway_endpoint_ids"></a> [gateway\_endpoint\_ids](#output\_gateway\_endpoint\_ids) | Gateway VPC endpoint IDs keyed by service (s3, dynamodb). Empty map when no gateway endpoints are requested. |
| <a name="output_internet_gateway_id"></a> [internet\_gateway\_id](#output\_internet\_gateway\_id) | ID of the internet gateway. Null when no public subnets are defined. |
| <a name="output_intra_route_table_id"></a> [intra\_route\_table\_id](#output\_intra\_route\_table\_id) | ID of the intra route table. Null when no intra subnets are defined. |
| <a name="output_intra_subnet_arns"></a> [intra\_subnet\_arns](#output\_intra\_subnet\_arns) | Intra subnet ARNs keyed by subnet name. |
| <a name="output_intra_subnet_cidr_blocks"></a> [intra\_subnet\_cidr\_blocks](#output\_intra\_subnet\_cidr\_blocks) | Intra subnet CIDR blocks keyed by subnet name. |
| <a name="output_intra_subnet_ids"></a> [intra\_subnet\_ids](#output\_intra\_subnet\_ids) | Intra subnet IDs keyed by subnet name. |
| <a name="output_nat_gateway_ids"></a> [nat\_gateway\_ids](#output\_nat\_gateway\_ids) | NAT gateway IDs keyed by availability zone. Empty map when no private subnets are defined. |
| <a name="output_nat_public_ips"></a> [nat\_public\_ips](#output\_nat\_public\_ips) | NAT gateway Elastic IP addresses keyed by availability zone. Empty map when no private subnets are defined. |
| <a name="output_private_route_table_ids"></a> [private\_route\_table\_ids](#output\_private\_route\_table\_ids) | Private route table IDs keyed by availability zone. Empty map when no private subnets are defined. |
| <a name="output_private_subnet_arns"></a> [private\_subnet\_arns](#output\_private\_subnet\_arns) | Private subnet ARNs keyed by subnet name. |
| <a name="output_private_subnet_cidr_blocks"></a> [private\_subnet\_cidr\_blocks](#output\_private\_subnet\_cidr\_blocks) | Private subnet CIDR blocks keyed by subnet name. |
| <a name="output_private_subnet_ids"></a> [private\_subnet\_ids](#output\_private\_subnet\_ids) | Private subnet IDs keyed by subnet name. |
| <a name="output_public_route_table_id"></a> [public\_route\_table\_id](#output\_public\_route\_table\_id) | ID of the public route table. Null when no public subnets are defined. |
| <a name="output_public_subnet_arns"></a> [public\_subnet\_arns](#output\_public\_subnet\_arns) | Public subnet ARNs keyed by subnet name. |
| <a name="output_public_subnet_cidr_blocks"></a> [public\_subnet\_cidr\_blocks](#output\_public\_subnet\_cidr\_blocks) | Public subnet CIDR blocks keyed by subnet name. |
| <a name="output_public_subnet_ids"></a> [public\_subnet\_ids](#output\_public\_subnet\_ids) | Public subnet IDs keyed by subnet name. |
| <a name="output_vpc_arn"></a> [vpc\_arn](#output\_vpc\_arn) | ARN of the VPC. |
| <a name="output_vpc_cidr_block"></a> [vpc\_cidr\_block](#output\_vpc\_cidr\_block) | IPv4 CIDR block of the VPC. |
| <a name="output_vpc_id"></a> [vpc\_id](#output\_vpc\_id) | ID of the VPC. |
<!-- END_TF_DOCS -->
