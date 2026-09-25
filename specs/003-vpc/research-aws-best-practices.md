## Research: AWS security controls and best practices the VPC module must satisfy

### Decision

Keep the default security group empty. Turn flow logs on by default (`traffic_type = "ALL"`) and send them to a CloudWatch Logs group that the module creates, with a 365-day retention default and an optional customer-managed KMS key. The flow log IAM role gets a trust policy with confused-deputy conditions and a permissions policy scoped to that one log group. `map_public_ip_on_launch` defaults to `false` on every subnet. One NAT gateway per AZ is the default, and `single_nat_gateway` is an opt-in cost trade-off. Gateway endpoints attach only to non-public route tables.

### Resources Identified

- **Primary Resource**: `aws_vpc`, the network boundary. Set `enable_dns_support = true` and `enable_dns_hostnames = true`.
- **Supporting Resources**:
  - `aws_default_security_group`: take over the default SG with no `ingress` or `egress` blocks, which removes every rule (EC2.2).
  - `aws_flow_log`: `vpc_id`, `traffic_type = "ALL"`, `log_destination_type = "cloud-watch-logs"`, `log_destination` (log group ARN), `iam_role_arn`, `max_aggregation_interval` (60 or 600; default 600).
  - `aws_cloudwatch_log_group`: the flow log destination. Set `retention_in_days` and `kms_key_id`.
  - `aws_iam_role` + `aws_iam_role_policy`: the delivery role for flow logs.
  - `aws_subnet`: `map_public_ip_on_launch = false` by default.
  - `aws_nat_gateway` + `aws_eip`: one per AZ, or one if `single_nat_gateway = true`.
  - `aws_vpc_endpoint` (type `Gateway`, S3 and DynamoDB) + `aws_vpc_endpoint_route_table_association`, on private, database and intra route tables only.
  - Data sources: `aws_caller_identity`, `aws_region`, `aws_partition`. These build ARNs for the IAM conditions and must not hard-code `arn:aws`.
- **Key Arguments**: `enable_flow_log` (bool, default `true`), `flow_log_traffic_type` (default `"ALL"`), `flow_log_retention_in_days` (default `365`, checked against the values CloudWatch accepts), `flow_log_kms_key_id` (default `null`), `flow_log_max_aggregation_interval` (default `600`), `map_public_ip_on_launch` (default `false`), `single_nat_gateway` (default `false`).
- **Key Outputs**: `vpc_id` (`string`), `default_security_group_id` (`string`), `flow_log_id` (`string`), `flow_log_cloudwatch_log_group_arn` (`string`), `flow_log_iam_role_arn` (`string`), `nat_gateway_ids` (`list(string)`), `nat_public_ips` (`list(string)`), `vpc_endpoint_s3_id` / `vpc_endpoint_dynamodb_id` (`string`).
- **Security Considerations**: the controls table below lists them.

---

### 1. Security controls table

| Control (Security Hub / CIS) | Requirement (AWS Config rule) | How the module enforces it |
| --- | --- | --- |
| **EC2.2**: VPC default security groups should not allow inbound or outbound traffic. CIS v1.2 4.3, v1.4 5.3, v3.0 5.4. Severity High. | `vpc-default-security-group-closed`. The default SG must have zero ingress and zero egress rules. | `aws_default_security_group` on `aws_vpc.this.id` with no rule blocks. Terraform then removes AWS's default allow-all egress and self-referencing ingress. There is no toggle for this. Test: the plan shows empty `ingress` and `egress`. |
| **EC2.6**: VPC flow logging should be enabled in all VPCs. CIS v1.2 2.9, v1.4 3.9, v3.0 3.7. Severity Medium. | `vpc-flow-logs-enabled`. The rule's default `trafficType` is `REJECT`. CIS requires at least REJECT. | `enable_flow_log = true` by default, and `traffic_type` defaults to `"ALL"`, which covers REJECT. Validation allows `ACCEPT`, `REJECT` or `ALL`. |
| **EC2.15**: EC2 subnets should not automatically assign public IP addresses. Severity Medium. | `subnet-auto-assign-public-ip-disabled`. Fails on any subnet with `MapPublicIpOnLaunch = true`, public subnets included. | `map_public_ip_on_launch` defaults to `false` on every subnet tier. It is exposed only for public subnets, as an explicit opt-in, and the variable description names EC2.15. Private, database and intra subnets always use `false`. |
| **EC2.9**: EC2 instances should not have a public IPv4 address. Severity High. | `ec2-instance-no-public-ip` | The same `false` default means instances only get a public IP when the consumer requests one explicitly. |
| **CloudWatch.16**: CloudWatch log groups should be retained for a specified time period. Severity Medium. | `cw-loggroup-retention-period-check`. The default `minRetentionTime` is **365 days**. `0` (never expire) is compliant. | `flow_log_retention_in_days` defaults to `365`. It is validated against the allowed set: 0, 1, 3, 5, 7, 14, 30, 60, 90, 120, 150, 180, 365, 400, 545, 731, 1096, 1827, 2192, 2557, 2922, 3288, 3653. |
| CloudWatch log group encryption. This is a Config rule only (NIST 800-53 and other conformance packs); FSBP has no control for it. | `cloudwatch-log-group-encrypted`. The log group needs a KMS key. By default it is encrypted with AWS-owned keys, which this rule does not accept. | Optional `flow_log_kms_key_id` (default `null`) is passed to `aws_cloudwatch_log_group.kms_key_id`. The consumer's key must carry the key policy in section 3. The README states that `null` means AWS-owned-key encryption and does not meet this rule. |
| IAM least privilege / confused deputy (IAM best practice; FSBP IAM.1 and IAM.21 target wildcard `*` actions on customer policies) | Trust policy restricted to the service principal with `aws:SourceAccount` and `aws:SourceArn`. No `logs:*` and no `Resource: "*"` where it can be avoided. | The trust and permissions policies in section 2 are built with `data "aws_iam_policy_document"`. Every action is listed explicitly; there are no service wildcards. |
| **EC2.21**: Network ACLs should not allow ingress from 0.0.0.0/0 to port 22 or 3389. CIS v1.4 5.1, v3.0 5.1. Severity Medium. | `nacl-no-unrestricted-ssh-rdp` | Out of scope for v1, which keeps the default NACL. **Flag for design**: the default NACL (rule 100, allow all from 0.0.0.0/0) fails this control. Options: manage `aws_default_network_acl` with explicit deny rules for 22 and 3389, or document it as a known finding. |
| **EC2.172**: VPC Block Public Access should block internet gateway traffic. | Account-level setting | Not applicable. The module needs an IGW for public subnets. Document it so consumers using BPA add an exclusion. |
| Private access to AWS services (VPC best practice; data-perimeter guidance) | Keep S3 and DynamoDB traffic off NAT and the internet. | Gateway endpoints are associated with private, database and intra route tables only, never with the public one. They are free, and they cut NAT data-processing cost. The default endpoint policy is full access; an optional `*_endpoint_policy` input may tighten it. |

---

### 2. Flow logs to CloudWatch Logs: IAM role

AWS's role requirements page ("IAM role for publishing flow logs to CloudWatch Logs") gives the trust principal `vpc-flow-logs.amazonaws.com` and the actions `logs:CreateLogGroup`, `logs:CreateLogStream`, `logs:PutLogEvents`, `logs:DescribeLogGroups` and `logs:DescribeLogStreams`. Its example uses `Resource: "*"`. The same page recommends `aws:SourceAccount` and `aws:SourceArn` in the trust policy to prevent the confused-deputy problem. The flow log ARN format is `arn:${Partition}:ec2:${Region}:${Account}:vpc-flow-log/${FlowLogId}`.

**Trust policy.** The flow log ID is not known before creation, so the ARN condition uses a wildcard.

```json
{
  "Version": "2012-10-17",
  "Statement": [{
    "Effect": "Allow",
    "Principal": { "Service": "vpc-flow-logs.amazonaws.com" },
    "Action": "sts:AssumeRole",
    "Condition": {
      "StringEquals": { "aws:SourceAccount": "${account_id}" },
      "ArnLike":      { "aws:SourceArn": "arn:${partition}:ec2:${region}:${account_id}:vpc-flow-log/*" }
    }
  }]
}
```

**Least-privilege permissions policy.** Because the module creates the log group itself, it drops `logs:CreateLogGroup` and scopes everything to that group.

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "WriteFlowLogs",
      "Effect": "Allow",
      "Action": ["logs:CreateLogStream", "logs:PutLogEvents", "logs:DescribeLogStreams"],
      "Resource": ["${log_group_arn}", "${log_group_arn}:*"]
    },
    {
      "Sid": "DescribeLogGroups",
      "Effect": "Allow",
      "Action": "logs:DescribeLogGroups",
      "Resource": "arn:${partition}:logs:${region}:${account_id}:log-group:*"
    }
  ]
}
```

Notes:
- Since AWS provider v4, `aws_cloudwatch_log_group.arn` has no trailing `:*`. Log stream ARNs look like `…:log-group:NAME:log-stream:STREAM`, so the `"${arn}:*"` entry is required.
- `DescribeLogGroups` does not support resource-level scoping to a single group, so its scope is the account and region log-group wildcard. This is the tightest scope available.
- The flow log role needs **no KMS permissions**. CloudWatch Logs performs encryption with its own service principal (section 3).
- The deploying principal needs `iam:PassRole` on this role. Mention this in the README.
- Use an inline `aws_iam_role_policy` (or a customer-managed policy). Avoid AWS-managed broad policies.

---

### 3. KMS key policy for a customer-managed key on the log group

These requirements come from the CloudWatch Logs guide "Encrypt log data in CloudWatch Logs using AWS KMS":
- The key must be a **symmetric** encryption KMS key in the **same Region** as the log group.
- The key policy must allow the **`logs.<region>.amazonaws.com`** service principal (a regional principal, not `logs.amazonaws.com`).
- CloudWatch Logs sends the encryption context `kms:EncryptionContext:aws:logs:arn`. Scope the grant to the log group ARN with `ArnEquals`, or `ArnLike` for a pattern.
- If the key policy is missing or wrong, `CreateLogGroup` or `AssociateKmsKey` fails with `AccessDeniedException`. Tests and docs should say so.
- If the key is disabled or scheduled for deletion, CloudWatch Logs cannot read or write the group.

Statement the consumer must add to their key policy. The module takes `kms_key_id` and does not create the key.

```json
{
  "Sid": "AllowCloudWatchLogsVpcFlowLogGroup",
  "Effect": "Allow",
  "Principal": { "Service": "logs.${region}.amazonaws.com" },
  "Action": ["kms:Encrypt*", "kms:Decrypt*", "kms:ReEncrypt*", "kms:GenerateDataKey*", "kms:Describe*"],
  "Resource": "*",
  "Condition": {
    "ArnEquals": {
      "kms:EncryptionContext:aws:logs:arn": "arn:${partition}:logs:${region}:${account_id}:log-group:${log_group_name}"
    }
  }
}
```

Design implications:
- The log group name must be deterministic, for example `/aws/vpc-flow-log/${name}`, so that consumers can write the key policy before they apply. Expose `flow_log_cloudwatch_log_group_name` as an output, and put the policy snippet in the README and the example.
- Validate `kms_key_id` as a KMS key ARN, either `^arn:aws[a-z-]*:kms:` or null. CloudWatch Logs requires the key **ARN**, not a key ID or alias.

---

### 4. `map_public_ip_on_launch` on public subnets

- **Guidance.** EC2.15 fails **every** subnet with auto-assign enabled, public subnets included. AWS has also charged for all public IPv4 addresses since 2024-02-01 (about $0.005 per hour each).
- **What does not need it.** NAT gateways use explicitly allocated EIPs. Internet-facing ALBs and NLBs get their public addresses from ELB regardless of the subnet setting.
- **What breaks with `false`.** An EC2 instance or ECS task launched into a public subnet without `associate_public_ip_address = true` (or `assign_public_ip = ENABLED`) gets no public IP. With no NAT route it has no internet egress.
- **Decision.** Default to `false` and expose `map_public_ip_on_launch` (bool) for public subnets only, as an opt-in. Enabling it knowingly creates an EC2.15 finding.

---

### 5. NAT gateway: one per AZ vs a single gateway

From the VPC user guide (NAT gateways / "NAT gateway basics"): a NAT gateway is redundant only within its AZ. If resources in several AZs share one NAT gateway and that AZ fails, the other AZs lose internet access. For AZ-independent architecture, AWS recommends a NAT gateway in each AZ, with each private route table routing to the NAT gateway in the same AZ.

| Mode | Availability | Cost |
| --- | --- | --- |
| Per AZ (default, `single_nat_gateway = false`) | Survives an AZ failure. No cross-AZ dependency. | N × hourly charge + N EIPs. No cross-AZ data transfer. |
| Single (`single_nat_gateway = true`) | Single point of failure in one AZ. | 1 × hourly charge + 1 EIP, plus inter-AZ data transfer (about $0.01 per GB each way) from the other AZs. Suited to dev and test. |

Implementation: create one private route table per AZ in both modes, so that switching modes only changes the route targets. Place the NAT gateways in the public subnet of the same AZ. The route tables for database and intra subnets get **no** default route to NAT; intra subnets get no internet route at all.

---

### 6. Flow log retention and format

- **Default 365 days.** This meets the default threshold of Security Hub CloudWatch.16, is common for PCI DSS 10.5.1 (keep at least 12 months of audit logs), and is a reasonable default for NIST AU-11. Consumers can set a longer value, or `0` (never expire) for compliance archives.
- `traffic_type = "ALL"`. CIS requires at least REJECT; ALL supports incident response and GuardDuty-style analysis.
- `max_aggregation_interval`: keep the 600 s default for cost; 60 s gives finer forensics. Expose it as an input with validation `contains([60, 600], v)`.
- `log_format` is optional. The default v2 format is enough; custom fields such as `vpc-id`, `subnet-id`, `pkt-srcaddr` and `flow-direction` can be passed through.

---

### Rationale

AWS publishes each of these as either a Security Hub FSBP or CIS AWS Foundations control backed by a managed Config rule (EC2.2, EC2.6, EC2.15, CloudWatch.16) or as documented service requirements (the flow logs IAM role and the CloudWatch Logs KMS key policy). The defaults are set so that a consumer who changes nothing passes these checks. Cost and availability trade-offs (single NAT, public IP auto-assign, KMS) stay as explicit opt-ins, with the control affected named in each variable description. The provider docs (hashicorp/aws 6.x, `aws_flow_log`) show that every required argument is supported: `iam_role_arn`, `log_destination`, `traffic_type` and `max_aggregation_interval`. The provider's own example uses `Resource: "*"` and no trust conditions. This module tightens both, as AWS's confused-deputy guidance recommends.

### Alternatives Considered

| Alternative | Why Not |
| --- | --- |
| Flow logs to S3 | The feature scope sets CloudWatch Logs. S3 would also need bucket policy, encryption and lifecycle resources, and the module would have to own a bucket. |
| Provider example policy (`Resource: "*"`, `logs:CreateLogGroup`, no trust conditions) | Too broad. It allows writing to any log group, and the trust policy is open to confused-deputy use. |
| Module creates its own KMS key | Out of scope (spec: `kms_key_id` default null). A key per VPC adds cost and key-policy management; consumers normally have a central logging CMK. |
| `map_public_ip_on_launch = true` on public subnets (the terraform-aws-modules/vpc default) | Fails EC2.15, adds public IPv4 cost, and is unnecessary for NAT and ALB. |
| Regional NAT gateway (new availability mode) | Newer feature with a different resource model. Consider it for a future version; per-AZ zonal NAT is well-established HA guidance. |
| Default retention `0` (never expire) | Unbounded cost, even though CloudWatch.16 accepts it. 365 days is the default threshold. |

### Sources

- Security Hub EC2 controls (EC2.2, EC2.6, EC2.9, EC2.15, EC2.21, EC2.172): https://docs.aws.amazon.com/securityhub/latest/userguide/ec2-controls.html
- Security Hub CloudWatch controls (CloudWatch.16): https://docs.aws.amazon.com/securityhub/latest/userguide/cloudwatch-controls.html
- CIS AWS Foundations Benchmark in Security Hub: https://docs.aws.amazon.com/securityhub/latest/userguide/cis-aws-foundations-benchmark.html
- Flow logs IAM role for CloudWatch Logs (trust and permissions, confused deputy): https://docs.aws.amazon.com/vpc/latest/userguide/flow-logs-iam-role.html
- Publish flow logs to CloudWatch Logs: https://docs.aws.amazon.com/vpc/latest/userguide/flow-logs-cwl.html
- Cross-service confused deputy prevention: https://docs.aws.amazon.com/IAM/latest/UserGuide/confused-deputy.html
- CloudWatch Logs KMS encryption (key policy, encryption context): https://docs.aws.amazon.com/AmazonCloudWatch/latest/logs/encrypt-log-data-kms.html
- Default security groups: https://docs.aws.amazon.com/vpc/latest/userguide/default-security-group.html
- NAT gateways (per-AZ HA guidance): https://docs.aws.amazon.com/vpc/latest/userguide/vpc-nat-gateway.html
- Subnet public IP addressing: https://docs.aws.amazon.com/vpc/latest/userguide/vpc-ip-addressing.html
- Gateway endpoints: https://docs.aws.amazon.com/vpc/latest/privatelink/gateway-endpoints.html
- VPC security best practices: https://docs.aws.amazon.com/vpc/latest/userguide/vpc-security-best-practices.html
- AWS Config managed rules: https://docs.aws.amazon.com/config/latest/developerguide/vpc-default-security-group-closed.html, https://docs.aws.amazon.com/config/latest/developerguide/vpc-flow-logs-enabled.html, https://docs.aws.amazon.com/config/latest/developerguide/subnet-auto-assign-public-ip-disabled.html, https://docs.aws.amazon.com/config/latest/developerguide/cw-loggroup-retention-period-check.html, https://docs.aws.amazon.com/config/latest/developerguide/cloudwatch-log-group-encrypted.html
- Public IPv4 pricing change: https://aws.amazon.com/blogs/aws/new-aws-public-ipv4-address-charge-public-ip-insights/
- Provider docs: hashicorp/aws 6.66.0, `aws_flow_log` (doc id 13748168), `aws_cloudwatch_log_group`, `aws_default_security_group`, `aws_vpc_endpoint`
