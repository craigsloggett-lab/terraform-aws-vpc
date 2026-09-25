# Example - Complete

Deploys the VPC module with every feature enabled:

- Public, private, database and intra subnets across three availability zones
- One NAT gateway per private-subnet AZ
- S3 and DynamoDB gateway endpoints attached to the private, database and intra route tables
- A DB subnet group
- VPC flow logs (all traffic) to a CloudWatch Logs group encrypted with a customer-managed KMS key

The example creates the KMS key itself. Its key policy lets the account root administer the key and lets `logs.<region>.amazonaws.com` use it only for the log group `/aws/vpc-flow-logs/<name>` (through the `kms:EncryptionContext:aws:logs:arn` condition).

## Usage

```sh
terraform init
terraform plan -var 'region=us-east-1'
terraform apply -var 'region=us-east-1'
```

The region must have at least three availability zones named `<region>a`, `<region>b` and `<region>c`.

This example creates resources that cost money, including NAT gateways, Elastic IPs and a KMS key. Run `terraform destroy` when you are done.
