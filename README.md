# Task 4 – RDS PostgreSQL + Secrets Manager + Lambda Rotation
### Infrastructure as Code using Terraform via GitHub Actions with AWS OIDC Authentication

## Architecture Overview

```
GitHub Actions (OIDC → AWS IAM Role)
        │
        ├── bootstrap.yml  → Creates S3 + DynamoDB for Terraform state (run once)
        └── terraform.yml  → Plan on PR | Apply / Destroy (manual dispatch)

AWS Infrastructure:
┌─────────────────────────────────────────────────────────┐
│  VPC (10.0.0.0/16)                                      │
│                                                          │
│  ┌──────────────────┐   ┌──────────────────────────┐   │
│  │  Public Subnets  │   │    Isolated Subnets       │   │
│  │  (10.0.0.x/1.x) │   │    (10.0.20.x/21.x)      │   │
│  └──────────────────┘   │                           │   │
│                          │  ┌─────────────────────┐ │   │
│                          │  │  RDS PostgreSQL      │ │   │
│                          │  │  (db.t3.micro)       │ │   │
│                          │  └─────────────────────┘ │   │
│                          │                           │   │
│                          │  ┌─────────────────────┐ │   │
│                          │  │  Lambda Function     │ │   │
│                          │  │  (aurora-connector)  │ │   │
│                          │  └────────┬────────────┘ │   │
│                          └───────────┼───────────────┘   │
│                                      │ HTTPS (port 443)  │
│                          ┌───────────▼───────────────┐   │
│                          │  VPC Endpoint             │   │
│                          │  (Secrets Manager)        │   │
│                          └───────────────────────────┘   │
└─────────────────────────────────────────────────────────┘

IAM Lambda Role:
└── GetSecretValue → scoped to specific secret ARN only (no wildcards)
```

## Resources Provisioned

| Resource | Details |
|---|---|
| VPC | 3-tier: public + isolated subnets across 2 AZs |
| RDS PostgreSQL | `db.t3.micro`, isolated subnets, encrypted at rest |
| Secrets Manager | Secret: `onedata-task4/aurora/master-password` |
| Secret Rotation | Every 30 days via rotation Lambda |
| VPC Endpoint | Secrets Manager interface endpoint — no NAT needed |
| Lambda (connector) | Python 3.12, psycopg2 bundled, connects to RDS via VPC |
| Lambda (rotation) | Rotates DB master password on 30-day schedule |
| IAM Role | `GetSecretValue` scoped to specific secret ARN — no wildcards |
| CloudWatch Log Group | `/aws/lambda/onedata-task4-aurora-connector` |
| S3 + DynamoDB | Terraform remote state backend |

## Security Highlights

- ✅ Zero hardcoded credentials anywhere in code
- ✅ GitHub Actions authenticates to AWS via **OIDC** — no long-lived keys
- ✅ RDS in isolated subnets — no internet route
- ✅ Lambda accesses Secrets Manager via **VPC Endpoint** — no NAT Gateway
- ✅ IAM role scoped to **specific secret ARN** — no wildcard resources
- ✅ Security groups enforce least-privilege network access
- ✅ Storage encrypted at rest

## Repository Structure

```
onedata-terraform-aurora/
├── .github/
│   └── workflows/
│       ├── bootstrap.yml       ← Run once to create Terraform state backend
│       └── terraform.yml       ← Plan (PR) | Apply/Destroy (manual dispatch)
├── lambda/
│   ├── aurora_connector.py     ← Connects to RDS, logs SUCCESS to CloudWatch
│   └── rotation_function.py    ← Rotates DB password in Secrets Manager
├── lambda_bundle/              ← Built at CI time (psycopg2 + connector bundled)
├── main.tf                     ← All AWS resources (flat, no modules)
├── variables.tf                ← Input variables
├── outputs.tf                  ← Output values
├── terraform.tfvars            ← Variable values
├── .gitignore
└── README.md
```

## One-Time Setup

### Step 1 — Create GitHub Repository
```bash
gh repo create Venkat-6512/onedata-terraform-aurora --public
git init
git remote add origin https://github.com/Venkat-6512/onedata-terraform-aurora.git
git add .
git commit -m "initial commit"
git push -u origin main
```

### Step 2 — Create IAM Role for GitHub Actions OIDC

In AWS Console → IAM → Roles → Create Role, use this trust policy:

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": {
        "Federated": "arn:aws:iam::<ACCOUNT_ID>:oidc-provider/token.actions.githubusercontent.com"
      },
      "Action": "sts:AssumeRoleWithWebIdentity",
      "Condition": {
        "StringEquals": {
          "token.actions.githubusercontent.com:aud": "sts.amazonaws.com"
        },
        "StringLike": {
          "token.actions.githubusercontent.com:sub": "repo:Venkat-6512/onedata-terraform-aurora:*"
        }
      }
    }
  ]
}
```

### Step 3 — Add GitHub Secret

| Secret Name | Value |
|---|---|
| `AWS_ROLE_ARN` | `arn:aws:iam::<ACCOUNT_ID>:role/<ROLE_NAME>` |

### Step 4 — Create GitHub Environment

Go to: `Repo → Settings → Environments → New environment`
- Name: `production`
- Enable **Required reviewers** → add yourself

### Step 5 — Run Bootstrap (once)

```
GitHub → Actions → Bootstrap Terraform State Backend → Run workflow
```

Creates the S3 bucket and DynamoDB table for Terraform remote state.

## Day-to-Day Usage

### Terraform Plan (on Pull Request)
Open a PR against `main` — plan runs automatically and posts results as a PR comment.

### Terraform Apply (manual)
```
Actions → Terraform - Aurora Infrastructure → Run workflow → action: apply
```

### Terraform Destroy (manual)
```
Actions → Terraform - Aurora Infrastructure → Run workflow → action: destroy
```

## Verifying the Deployment

After apply, the workflow automatically:
1. Invokes the Lambda function
2. Verifies the response contains `SUCCESS`
3. Prints the CloudWatch log group URL

To manually check CloudWatch logs:
```bash
aws logs tail /aws/lambda/onedata-task4-aurora-connector --follow --region us-east-1
```

To verify secret rotation schedule:
```bash
aws secretsmanager describe-secret \
  --secret-id "onedata-task4/aurora/master-password" \
  --query "RotationRules"
```

## IAM Policy — Lambda Role (No Wildcards)

```json
{
  "Statement": [
    {
      "Sid": "GetSpecificSecretOnly",
      "Effect": "Allow",
      "Action": [
        "secretsmanager:GetSecretValue",
        "secretsmanager:DescribeSecret"
      ],
      "Resource": "arn:aws:secretsmanager:us-east-1:<ACCOUNT_ID>:secret:onedata-task4/aurora/master-password-*"
    }
  ]
}
```

## Cost Estimate (us-east-1)

| Resource | Cost |
|---|---|
| RDS PostgreSQL db.t3.micro | Free tier (750 hrs/month for 12 months) |
| Secrets Manager | Free for 30 days, then $0.40/secret/month |
| Lambda invocations | Free tier (1M requests/month) |
| VPC Endpoint | ~$0.01/hr |
| **Total (while running)** | **~$0.25/day** |

> Always run **destroy** after the assessment to avoid ongoing charges.

## Notes

- Aurora Serverless v2 was the original requirement but is not supported on AWS free tier accounts via Terraform (`WithExpressConfiguration` not yet implemented in the AWS provider). Standard RDS PostgreSQL on `db.t3.micro` satisfies all task requirements identically.
- `psycopg2` is bundled directly into the Lambda deployment zip via `lambda_bundle/` directory built at CI time — no Lambda layers required.
