# Bootstrap

One-time manual setup. None of this is managed by Terraform itself, because
the state backend and the CI role have to exist *before* Terraform can run -
you can't store state in a bucket Terraform hasn't created yet, and you
can't let GitHub Actions assume a role that doesn't exist.

Do this once per AWS account. Everything after this point is `terraform
apply` / `terraform destroy` via CI.

## 1. State backend: S3 bucket + DynamoDB lock table

```bash
export AWS_REGION=us-west-2
export BUCKET_NAME=dstepanov-tfstate   # must be globally unique, adjust as needed
export TABLE_NAME=terraform-eks-platform-tfstate-lock

aws s3api create-bucket \
  --bucket "$BUCKET_NAME" \
  --region "$AWS_REGION" \
  --create-bucket-configuration LocationConstraint="$AWS_REGION"

aws s3api put-bucket-versioning \
  --bucket "$BUCKET_NAME" \
  --versioning-configuration Status=Enabled

aws s3api put-public-access-block \
  --bucket "$BUCKET_NAME" \
  --public-access-block-configuration \
  BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true

aws s3api put-bucket-encryption \
  --bucket "$BUCKET_NAME" \
  --server-side-encryption-configuration \
  '{"Rules":[{"ApplyServerSideEncryptionByDefault":{"SSEAlgorithm":"AES256"}}]}'

aws dynamodb create-table \
  --table-name "$TABLE_NAME" \
  --attribute-definitions AttributeName=LockID,AttributeType=S \
  --key-schema AttributeName=LockID,KeyType=HASH \
  --billing-mode PAY_PER_REQUEST \
  --region "$AWS_REGION"
```

Then edit `versions.tf` in the repo root and replace `REPLACE_ME-tfstate` /
`REPLACE_ME-tfstate-lock` with the bucket/table names you just created.

## 2. GitHub OIDC identity provider (once per AWS account)

Skip this step if your account already has a `token.actions.githubusercontent.com`
identity provider registered (check IAM -> Identity providers first).

```bash
aws iam create-open-id-connect-provider \
  --url https://token.actions.githubusercontent.com \
  --client-id-list sts.amazonaws.com \
  --thumbprint-list 6938fd4d98bab03faadb97b34396831e3780aea1
```

## 3. IAM role that GitHub Actions assumes

Trust policy scoped to this specific repo - not "any GitHub Actions run
anywhere," just yours.

```bash
export ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
export GITHUB_ORG=bibigon14
export GITHUB_REPO=terraform-eks-platform

cat > trust-policy.json <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": {
        "Federated": "arn:aws:iam::${ACCOUNT_ID}:oidc-provider/token.actions.githubusercontent.com"
      },
      "Action": "sts:AssumeRoleWithWebIdentity",
      "Condition": {
        "StringEquals": {
          "token.actions.githubusercontent.com:aud": "sts.amazonaws.com"
        },
        "StringLike": {
          "token.actions.githubusercontent.com:sub": "repo:${GITHUB_ORG}/${GITHUB_REPO}:*"
        }
      }
    }
  ]
}
EOF

aws iam create-role \
  --role-name terraform-eks-platform-deploy \
  --assume-role-policy-document file://trust-policy.json

# For a real account you'd scope this to exactly what Terraform needs
# (EC2, EKS, IAM:PassRole, VPC, etc.) instead of AdministratorAccess.
# For a personal demo account this is the pragmatic tradeoff - just don't
# reuse this role/account for anything you actually care about.
aws iam attach-role-policy \
  --role-name terraform-eks-platform-deploy \
  --policy-arn arn:aws:iam::aws:policy/AdministratorAccess

rm trust-policy.json
```

## 4. Tell GitHub Actions the role ARN

Repo -> Settings -> Secrets and variables -> Actions -> Variables tab ->
New repository variable:

```
Name:  AWS_ROLE_ARN
Value: arn:aws:iam::<ACCOUNT_ID>:role/terraform-eks-platform-deploy
```

(It's a repo *variable*, not a secret - the role ARN isn't sensitive on its
own; the trust policy above is what actually gates who can assume it.)

## 5. Require manual approval before apply/destroy

Repo -> Settings -> Environments -> New environment -> name it `production`
-> add yourself under "Required reviewers". This is what the `environment:
production` line in `terraform-apply.yml` / `terraform-destroy.yml` hooks
into - every apply pauses for your manual click before it touches AWS.

## 6. First run

Open a PR against `main` and watch `terraform-plan.yml` run and comment
the plan. Merge it, `terraform-apply.yml` fires, approve it in the
Environment's "Review deployments" prompt, and it applies.

When you're done demoing it:

Actions tab -> Terraform Destroy -> Run workflow -> type `destroy` -> approve.
