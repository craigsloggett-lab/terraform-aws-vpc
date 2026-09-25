# tflint-ignore: terraform_required_version
module "vpc" {
  source  = "app.terraform.io/craigsloggett-lab/vpc/aws"
  version = "0.0.1"
}
