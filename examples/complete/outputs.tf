output "database_subnet_group_name" {
  description = "Name of the DB subnet group."
  value       = module.vpc.database_subnet_group_name
}

output "database_subnet_ids" {
  description = "Database subnet IDs keyed by subnet name."
  value       = module.vpc.database_subnet_ids
}

output "default_security_group_id" {
  description = "ID of the VPC default security group, which is managed with no rules."
  value       = module.vpc.default_security_group_id
}

output "flow_log_cloudwatch_log_group_name" {
  description = "Name of the flow log CloudWatch Logs group."
  value       = module.vpc.flow_log_cloudwatch_log_group_name
}

output "flow_log_id" {
  description = "ID of the VPC flow log."
  value       = module.vpc.flow_log_id
}

output "gateway_endpoint_ids" {
  description = "Gateway VPC endpoint IDs keyed by service."
  value       = module.vpc.gateway_endpoint_ids
}

output "intra_subnet_ids" {
  description = "Intra subnet IDs keyed by subnet name."
  value       = module.vpc.intra_subnet_ids
}

output "kms_key_arn" {
  description = "ARN of the KMS key that encrypts the flow log group."
  value       = aws_kms_key.flow_logs.arn
}

output "nat_public_ips" {
  description = "NAT gateway Elastic IP addresses keyed by AZ."
  value       = module.vpc.nat_public_ips
}

output "private_route_table_ids" {
  description = "Private route table IDs keyed by AZ."
  value       = module.vpc.private_route_table_ids
}

output "private_subnet_ids" {
  description = "Private subnet IDs keyed by subnet name."
  value       = module.vpc.private_subnet_ids
}

output "public_subnet_ids" {
  description = "Public subnet IDs keyed by subnet name."
  value       = module.vpc.public_subnet_ids
}

output "vpc_id" {
  description = "ID of the VPC."
  value       = module.vpc.vpc_id
}
