# Region, account and partition are used to build the flow log group ARN and
# IAM condition values locally, so policy documents are fully known at plan
# time and no ARN is hard-coded to the commercial `aws` partition.

data "aws_region" "current" {}

data "aws_caller_identity" "current" {}

data "aws_partition" "current" {}
