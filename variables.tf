variable "name" {
  description = "Name of the VPC. Used as the `Name` tag and as the prefix for every derived resource name and the flow log group."
  type        = string
  nullable    = false

  validation {
    condition     = length(var.name) >= 1 && length(var.name) <= 32
    error_message = "name must be 1-32 characters long (keeps the derived IAM role name within 64 characters)."
  }

  validation {
    condition     = can(regex("^[A-Za-z0-9][A-Za-z0-9-]*$", var.name))
    error_message = "name may contain only letters, digits and hyphens, and must start with a letter or digit."
  }
}

variable "cidr_block" {
  description = "IPv4 CIDR block for the VPC, e.g. `10.0.0.0/16`."
  type        = string
  nullable    = false

  validation {
    condition     = can(cidrnetmask(var.cidr_block))
    error_message = "cidr_block must be a valid IPv4 CIDR (e.g. 10.0.0.0/16)."
  }

  validation {
    condition     = try(cidrhost(var.cidr_block, 0) == split("/", var.cidr_block)[0], false)
    error_message = "cidr_block must be a network address with no host bits set (e.g. 10.0.0.0/16, not 10.0.0.1/16)."
  }

  validation {
    condition     = try(tonumber(split("/", var.cidr_block)[1]) >= 16 && tonumber(split("/", var.cidr_block)[1]) <= 28, false)
    error_message = "cidr_block prefix length must be between /16 and /28."
  }
}

variable "public_subnets" {
  description = "Public subnets keyed by short name. They route to the internet gateway and host NAT gateways. In each AZ, the NAT goes in the subnet whose key sorts first. Adding a key that sorts earlier in the same AZ replaces that AZ's NAT and EIP. AZ values must be known at plan."
  type = map(object({
    cidr_block        = string
    availability_zone = string
    tags              = optional(map(string), {})
  }))
  default  = {}
  nullable = false

  validation {
    condition = alltrue([
      for k, s in var.public_subnets :
      can(cidrnetmask(s.cidr_block)) &&
      try(cidrhost(s.cidr_block, 0) == split("/", s.cidr_block)[0], false) &&
      try(tonumber(split("/", s.cidr_block)[1]) >= 16 && tonumber(split("/", s.cidr_block)[1]) <= 28, false)
    ])
    error_message = "Every public subnet cidr_block must be a valid IPv4 network address (no host bits set) with a prefix between /16 and /28."
  }

  validation {
    condition = alltrue([
      for k, s in var.public_subnets :
      try(
        tonumber(split("/", s.cidr_block)[1]) >= tonumber(split("/", var.cidr_block)[1]) &&
        cidrhost(format("%s/%s", cidrhost(s.cidr_block, 0), split("/", var.cidr_block)[1]), 0) == cidrhost(var.cidr_block, 0),
        false
      )
    ])
    error_message = "Every public subnet cidr_block must fall within cidr_block."
  }

  validation {
    condition = alltrue([
      for k, s in var.public_subnets :
      can(regex("^[a-z]{2}(-[a-z]+)+-[0-9]+[a-z]$", s.availability_zone))
    ])
    error_message = "Every public subnet availability_zone must be an availability zone name (e.g. us-east-1a), not an AZ ID (e.g. use1-az1)."
  }
}

variable "private_subnets" {
  description = "Private subnets keyed by short name. They get outbound-only internet access through a NAT gateway (one route table per AZ)."
  type = map(object({
    cidr_block        = string
    availability_zone = string
    tags              = optional(map(string), {})
  }))
  default  = {}
  nullable = false

  validation {
    condition = alltrue([
      for k, s in var.private_subnets :
      can(cidrnetmask(s.cidr_block)) &&
      try(cidrhost(s.cidr_block, 0) == split("/", s.cidr_block)[0], false) &&
      try(tonumber(split("/", s.cidr_block)[1]) >= 16 && tonumber(split("/", s.cidr_block)[1]) <= 28, false)
    ])
    error_message = "Every private subnet cidr_block must be a valid IPv4 network address (no host bits set) with a prefix between /16 and /28."
  }

  validation {
    condition = alltrue([
      for k, s in var.private_subnets :
      try(
        tonumber(split("/", s.cidr_block)[1]) >= tonumber(split("/", var.cidr_block)[1]) &&
        cidrhost(format("%s/%s", cidrhost(s.cidr_block, 0), split("/", var.cidr_block)[1]), 0) == cidrhost(var.cidr_block, 0),
        false
      )
    ])
    error_message = "Every private subnet cidr_block must fall within cidr_block."
  }

  validation {
    condition = alltrue([
      for k, s in var.private_subnets :
      can(regex("^[a-z]{2}(-[a-z]+)+-[0-9]+[a-z]$", s.availability_zone))
    ])
    error_message = "Every private subnet availability_zone must be an availability zone name (e.g. us-east-1a), not an AZ ID (e.g. use1-az1)."
  }

  validation {
    condition     = length(var.private_subnets) == 0 || length(var.public_subnets) > 0
    error_message = "private_subnets require at least one public subnet to host a NAT gateway. Use intra_subnets for subnets without internet egress."
  }
}

variable "database_subnets" {
  description = "Isolated database subnets keyed by short name. They have no internet or NAT route."
  type = map(object({
    cidr_block        = string
    availability_zone = string
    tags              = optional(map(string), {})
  }))
  default  = {}
  nullable = false

  validation {
    condition = alltrue([
      for k, s in var.database_subnets :
      can(cidrnetmask(s.cidr_block)) &&
      try(cidrhost(s.cidr_block, 0) == split("/", s.cidr_block)[0], false) &&
      try(tonumber(split("/", s.cidr_block)[1]) >= 16 && tonumber(split("/", s.cidr_block)[1]) <= 28, false)
    ])
    error_message = "Every database subnet cidr_block must be a valid IPv4 network address (no host bits set) with a prefix between /16 and /28."
  }

  validation {
    condition = alltrue([
      for k, s in var.database_subnets :
      try(
        tonumber(split("/", s.cidr_block)[1]) >= tonumber(split("/", var.cidr_block)[1]) &&
        cidrhost(format("%s/%s", cidrhost(s.cidr_block, 0), split("/", var.cidr_block)[1]), 0) == cidrhost(var.cidr_block, 0),
        false
      )
    ])
    error_message = "Every database subnet cidr_block must fall within cidr_block."
  }

  validation {
    condition = alltrue([
      for k, s in var.database_subnets :
      can(regex("^[a-z]{2}(-[a-z]+)+-[0-9]+[a-z]$", s.availability_zone))
    ])
    error_message = "Every database subnet availability_zone must be an availability zone name (e.g. us-east-1a), not an AZ ID (e.g. use1-az1)."
  }

  validation {
    condition = (
      !var.create_database_subnet_group ||
      length(var.database_subnets) == 0 ||
      length(distinct([for s in values(var.database_subnets) : s.availability_zone])) >= 2
    )
    error_message = "database_subnets must span at least 2 availability zones when create_database_subnet_group is true."
  }
}

variable "intra_subnets" {
  description = "Fully isolated subnets keyed by short name. They have no internet or NAT route."
  type = map(object({
    cidr_block        = string
    availability_zone = string
    tags              = optional(map(string), {})
  }))
  default  = {}
  nullable = false

  validation {
    condition = alltrue([
      for k, s in var.intra_subnets :
      can(cidrnetmask(s.cidr_block)) &&
      try(cidrhost(s.cidr_block, 0) == split("/", s.cidr_block)[0], false) &&
      try(tonumber(split("/", s.cidr_block)[1]) >= 16 && tonumber(split("/", s.cidr_block)[1]) <= 28, false)
    ])
    error_message = "Every intra subnet cidr_block must be a valid IPv4 network address (no host bits set) with a prefix between /16 and /28."
  }

  validation {
    condition = alltrue([
      for k, s in var.intra_subnets :
      try(
        tonumber(split("/", s.cidr_block)[1]) >= tonumber(split("/", var.cidr_block)[1]) &&
        cidrhost(format("%s/%s", cidrhost(s.cidr_block, 0), split("/", var.cidr_block)[1]), 0) == cidrhost(var.cidr_block, 0),
        false
      )
    ])
    error_message = "Every intra subnet cidr_block must fall within cidr_block."
  }

  validation {
    condition = alltrue([
      for k, s in var.intra_subnets :
      can(regex("^[a-z]{2}(-[a-z]+)+-[0-9]+[a-z]$", s.availability_zone))
    ])
    error_message = "Every intra subnet availability_zone must be an availability zone name (e.g. us-east-1a), not an AZ ID (e.g. use1-az1)."
  }
}

variable "map_public_ip_on_launch" {
  description = "Auto-assign public IPv4 addresses to instances launched in public subnets. `true` fails Security Hub EC2.15. Other tiers always use `false`."
  type        = bool
  default     = false
  nullable    = false
}

variable "single_nat_gateway" {
  description = "Use one NAT gateway (in the first sorted public AZ) for all private subnets instead of one per AZ. This lowers cost but gives up AZ resilience."
  type        = bool
  default     = false
  nullable    = false
}

variable "gateway_endpoints" {
  description = "Gateway VPC endpoints to create and attach to every private, database and intra route table (never the public one). Allowed: `s3`, `dynamodb`."
  type        = set(string)
  default     = []
  nullable    = false

  validation {
    condition     = alltrue([for s in var.gateway_endpoints : contains(["s3", "dynamodb"], s)])
    error_message = "gateway_endpoints may only contain the values: s3, dynamodb."
  }
}

variable "create_database_subnet_group" {
  description = "Create a DB subnet group from the database subnets. Only takes effect when `database_subnets` is non-empty. Requires at least 2 AZs."
  type        = bool
  default     = true
  nullable    = false
}

variable "enable_flow_logs" {
  description = "Enable VPC flow logs (all traffic) to a CloudWatch Logs group created by this module. Disabling fails CIS 3.7 / Security Hub EC2.6."
  type        = bool
  default     = true
  nullable    = false
}

variable "flow_log_retention_in_days" {
  description = "Retention for the flow log group in days. `0` means never expire. Values under 365 fail Security Hub CloudWatch.16."
  type        = number
  default     = 365
  nullable    = false

  validation {
    condition     = contains([0, 1, 3, 5, 7, 14, 30, 60, 90, 120, 150, 180, 365, 400, 545, 731, 1096, 1827, 2192, 2557, 2922, 3288, 3653], var.flow_log_retention_in_days)
    error_message = "flow_log_retention_in_days must be one of: 0, 1, 3, 5, 7, 14, 30, 60, 90, 120, 150, 180, 365, 400, 545, 731, 1096, 1827, 2192, 2557, 2922, 3288, 3653."
  }
}

variable "flow_log_max_aggregation_interval" {
  description = "Maximum interval in seconds over which a flow is captured and aggregated into one record."
  type        = number
  default     = 600
  nullable    = false

  validation {
    condition     = contains([60, 600], var.flow_log_max_aggregation_interval)
    error_message = "flow_log_max_aggregation_interval must be 60 or 600."
  }
}

variable "kms_key_id" {
  description = "ARN of a customer-managed symmetric KMS key used to encrypt the flow log group. `null` uses CloudWatch Logs service-managed encryption. The key policy must allow `logs.<region>.amazonaws.com` for log group `/aws/vpc-flow-logs/<name>`."
  type        = string
  default     = null

  validation {
    condition     = var.kms_key_id == null || can(regex("^arn:aws[a-z-]*:kms:[a-z0-9-]+:[0-9]{12}:key/.+$", var.kms_key_id))
    error_message = "kms_key_id must be a KMS key ARN (arn:<partition>:kms:<region>:<account>:key/<key-id>), not a key ID or alias."
  }
}

variable "tags" {
  description = "Tags for every taggable resource. They override `ManagedBy`. `Name` is set per resource and is not overridden from here."
  type        = map(string)
  default     = {}
  nullable    = false

  validation {
    condition     = alltrue([for k in keys(var.tags) : !startswith(lower(k), "aws:")])
    error_message = "Tag keys must not start with \"aws:\" (the aws: prefix is reserved by AWS)."
  }
}
