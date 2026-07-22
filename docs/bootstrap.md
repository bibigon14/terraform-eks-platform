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
          "token.actions.githubusercontent.com:sub": [
            "repo:${GITHUB_ORG}/${GITHUB_REPO}:*",
            "repo:${GITHUB_ORG}@*/${GITHUB_REPO}@*:*"
          ]
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
Environment's "Review deployments" prompt, and it applies (~13 minutes -
the EKS control plane alone takes ~10).

When you're done demoing it:

Actions tab -> Terraform Destroy -> Run workflow -> type `destroy` -> approve.

## 7. Give yourself kubectl access (post-apply)

The apply above creates the cluster from CI, which means the *only*
principal with admin access to the Kubernetes API server is the CI role
`terraform-eks-platform-deploy`. Your local IAM user (the one you use for
`aws configure` on your laptop) is not on the list yet, so `kubectl` will
answer with `error: You must be logged in to the server (Unauthorized)`.

Fix it once, per cluster, with two AWS API calls - no Terraform changes,
no kubeconfig hacks:

```bash
export ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
export LOCAL_IAM_USER=terraform-admin   # whatever your local user is called

aws eks create-access-entry \
  --cluster-name eks-platform-demo \
  --region us-west-2 \
  --principal-arn arn:aws:iam::${ACCOUNT_ID}:user/${LOCAL_IAM_USER} \
  --type STANDARD

aws eks associate-access-policy \
  --cluster-name eks-platform-demo \
  --region us-west-2 \
  --principal-arn arn:aws:iam::${ACCOUNT_ID}:user/${LOCAL_IAM_USER} \
  --policy-arn arn:aws:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy \
  --access-scope type=cluster

aws eks update-kubeconfig --region us-west-2 --name eks-platform-demo
kubectl get nodes
```

Longer-term, the cleaner place for this is inside the `eks` module call
via its `access_entries` argument, so it lives in Terraform state and
survives cluster rebuilds. That's in the follow-ups list in the README.

## Troubleshooting

### `AccessDenied` on `sts:AssumeRoleWithWebIdentity` from the plan/apply job

The action retries `Assuming role with OIDC` for ~2 minutes and then fails.
Trust policy conditions look right, OIDC provider is registered, and
`vars.AWS_ROLE_ARN` matches the role that exists in IAM.

Cause on this account: GitHub's OIDC issuer emits a **customized subject
claim with owner/repo IDs** - the `sub` on the token looks like
`repo:<owner>@<ownerID>/<repo>@<repoID>:pull_request`, not the standard
`repo:<owner>/<repo>:pull_request`. A trust policy written against only
the standard form will never match.

The trust policy in step 3 above accepts *both* forms via a two-element
`StringLike` list. If you're forking this repo and hit the same error,
confirm what your account is sending by looking at the failed STS call
in CloudTrail:

```bash
aws cloudtrail lookup-events \
  --lookup-attributes AttributeKey=EventName,AttributeValue=AssumeRoleWithWebIdentity \
  --max-results 5 \
  --region us-west-2 \
  --output json \
  | jq '.Events[].CloudTrailEvent | fromjson | .userIdentity.principalId'
```

Whatever pattern the `principalId` shows is what your trust policy needs
to `StringLike`-match.
