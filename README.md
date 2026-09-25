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
| ---- | ------- |
| <a name="requirement_terraform"></a> [terraform](#requirement\_terraform) | ~> 1.0 |

## Providers

No providers.

## Inputs

No inputs.

## Resources

No resources.

## Outputs

No outputs.
<!-- END_TF_DOCS -->
