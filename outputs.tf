output "azs" {
  description = "Sorted, distinct availability zones used by any subnet tier. Empty when no subnets are defined."
  value       = local.azs
}

output "database_route_table_id" {
  description = "ID of the database route table. Null when no database subnets are defined."
  value       = try(aws_route_table.database[0].id, null)
}

output "database_subnet_arns" {
  description = "Database subnet ARNs keyed by subnet name."
  value       = { for k, s in aws_subnet.database : k => s.arn }
}

output "database_subnet_cidr_blocks" {
  description = "Database subnet CIDR blocks keyed by subnet name."
  value       = { for k, s in aws_subnet.database : k => s.cidr_block }
}

output "database_subnet_group_name" {
  description = "Name of the DB subnet group. Null unless create_database_subnet_group is true and database subnets are defined."
  value       = try(aws_db_subnet_group.this[0].name, null)
}

output "database_subnet_ids" {
  description = "Database subnet IDs keyed by subnet name."
  value       = { for k, s in aws_subnet.database : k => s.id }
}

output "default_security_group_id" {
  description = "ID of the VPC default security group, which is managed with no rules."
  value       = aws_default_security_group.this.id
}

output "flow_log_cloudwatch_log_group_arn" {
  description = "ARN of the flow log CloudWatch Logs group. Null when flow logs are disabled."
  value       = try(aws_cloudwatch_log_group.flow_logs[0].arn, null)
}

output "flow_log_cloudwatch_log_group_name" {
  description = "Name of the flow log CloudWatch Logs group. Null when flow logs are disabled."
  value       = try(aws_cloudwatch_log_group.flow_logs[0].name, null)
}

output "flow_log_iam_role_arn" {
  description = "ARN of the IAM role used by VPC Flow Logs to publish to CloudWatch Logs. Null when flow logs are disabled."
  value       = try(aws_iam_role.flow_logs[0].arn, null)
}

output "flow_log_id" {
  description = "ID of the VPC flow log. Null when flow logs are disabled."
  value       = try(aws_flow_log.this[0].id, null)
}

output "gateway_endpoint_ids" {
  description = "Gateway VPC endpoint IDs keyed by service (s3, dynamodb). Empty map when no gateway endpoints are requested."
  value       = { for k, e in aws_vpc_endpoint.gateway : k => e.id }
}

output "internet_gateway_id" {
  description = "ID of the internet gateway. Null when no public subnets are defined."
  value       = try(aws_internet_gateway.this[0].id, null)
}

output "intra_route_table_id" {
  description = "ID of the intra route table. Null when no intra subnets are defined."
  value       = try(aws_route_table.intra[0].id, null)
}

output "intra_subnet_arns" {
  description = "Intra subnet ARNs keyed by subnet name."
  value       = { for k, s in aws_subnet.intra : k => s.arn }
}

output "intra_subnet_cidr_blocks" {
  description = "Intra subnet CIDR blocks keyed by subnet name."
  value       = { for k, s in aws_subnet.intra : k => s.cidr_block }
}

output "intra_subnet_ids" {
  description = "Intra subnet IDs keyed by subnet name."
  value       = { for k, s in aws_subnet.intra : k => s.id }
}

output "nat_gateway_ids" {
  description = "NAT gateway IDs keyed by availability zone. Empty map when no private subnets are defined."
  value       = { for k, n in aws_nat_gateway.this : k => n.id }
}

output "nat_public_ips" {
  description = "NAT gateway Elastic IP addresses keyed by availability zone. Empty map when no private subnets are defined."
  value       = { for k, e in aws_eip.nat : k => e.public_ip }
}

output "private_route_table_ids" {
  description = "Private route table IDs keyed by availability zone. Empty map when no private subnets are defined."
  value       = { for k, rt in aws_route_table.private : k => rt.id }
}

output "private_subnet_arns" {
  description = "Private subnet ARNs keyed by subnet name."
  value       = { for k, s in aws_subnet.private : k => s.arn }
}

output "private_subnet_cidr_blocks" {
  description = "Private subnet CIDR blocks keyed by subnet name."
  value       = { for k, s in aws_subnet.private : k => s.cidr_block }
}

output "private_subnet_ids" {
  description = "Private subnet IDs keyed by subnet name."
  value       = { for k, s in aws_subnet.private : k => s.id }
}

output "public_route_table_id" {
  description = "ID of the public route table. Null when no public subnets are defined."
  value       = try(aws_route_table.public[0].id, null)
}

output "public_subnet_arns" {
  description = "Public subnet ARNs keyed by subnet name."
  value       = { for k, s in aws_subnet.public : k => s.arn }
}

output "public_subnet_cidr_blocks" {
  description = "Public subnet CIDR blocks keyed by subnet name."
  value       = { for k, s in aws_subnet.public : k => s.cidr_block }
}

output "public_subnet_ids" {
  description = "Public subnet IDs keyed by subnet name."
  value       = { for k, s in aws_subnet.public : k => s.id }
}

output "vpc_arn" {
  description = "ARN of the VPC."
  value       = aws_vpc.this.arn
}

output "vpc_cidr_block" {
  description = "IPv4 CIDR block of the VPC."
  value       = aws_vpc.this.cidr_block
}

output "vpc_id" {
  description = "ID of the VPC."
  value       = aws_vpc.this.id
}
