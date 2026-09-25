variable "name" {
  description = "Name of the VPC. Also used for the flow log group (/aws/vpc-flow-logs/<name>) and the KMS key alias."
  type        = string
  default     = "complete"
}

variable "region" {
  description = "AWS region to deploy into. Subnet availability zones are derived as <region>a, <region>b and <region>c."
  type        = string
  default     = "us-east-1"
}

variable "tags" {
  description = "Tags applied to every taggable resource in this example."
  type        = map(string)
  default = {
    Environment = "test"
    Owner       = "platform"
  }
}
