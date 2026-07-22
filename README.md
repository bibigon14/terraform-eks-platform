# terraform-eks-platform

A minimal, production-shaped AWS landing zone: VPC, EKS, and IAM Roles for
Service Accounts (IRSA), deployed exclusively through GitHub Actions using
OIDC federation - no long-lived AWS access keys stored anywhere.

> **Cost warning:** the EKS control plane is billed at $0.10/hour
> (~$72/month) the moment `apply` finishes, on top of EC2 node cost. It is
> **not** covered by the AWS free tier. This repo is built to be applied,
> demoed, and destroyed the same day via the `Terraform Destroy` workflow -
> see [docs/bootstrap.md](docs/bootstrap.md).

## Why this exists

Most "Terraform + AWS" portfolio repos stop at `terraform apply` from a
laptop with a hardcoded `AWS_ACCESS_KEY_ID`. This one is built the way I'd
actually want to find infrastructure at a new job:

- **State lives in S3 + DynamoDB**, not on anyone's laptop, with locking so
  two applies can't race each other.
- **No static AWS credentials, anywhere.** CI assumes an IAM role via GitHub's
  OIDC provider, scoped by trust policy to this one repo. Credentials are
  minted per workflow run and expire on their own.
- **Plan runs on every PR** and gets posted as a comment before anything is
  allowed to merge. Apply and destroy are gated behind a GitHub Environment
  with required manual approval - `git push` alone can't touch AWS.
- **IRSA is hand-rolled, not hidden behind a module.** `modules/irsa-role`
  spells out the actual OIDC trust condition (`sub` claim matching
  `system:serviceaccount:<namespace>:<name>`) because that's the mechanism
  worth understanding, not just invoking.

## Architecture

```mermaid
flowchart TB
    GHA["GitHub Actions<br/>(OIDC token, no stored AWS keys)"]
    ROLE1["IAM Role<br/>terraform-eks-platform-deploy"]
    GHA -->|sts:AssumeRoleWithWebIdentity| ROLE1

    subgraph VPC["VPC (10.20.0.0/16)"]
        PUB["Public subnet<br/>(per AZ)"]
        NAT(["NAT Gateway"])
        PRIV["Private subnet<br/>(EKS nodes)"]
        PUB --> NAT --> PRIV

        subgraph EKS["EKS cluster"]
            OIDC["OIDC provider (enable_irsa)"]
            NODES["Managed node group (t3.medium)"]
        end

        PRIV --> EKS
    end

    ROLE1 --> VPC
    ROLE2["IAM Role<br/>&lt;cluster&gt;-s3-reader<br/>(scoped to exactly one policy)"]
    EKS -->|"sts:AssumeRoleWithWebIdentity<br/>(sub claim = namespace:sa)"| ROLE2
```

## Repo structure

```
.
├── main.tf                    # VPC + EKS + demo IRSA role wiring
├── variables.tf
├── outputs.tf
├── providers.tf
├── versions.tf                 # provider + S3 backend config
├── modules/
│   └── irsa-role/               # hand-written IRSA trust policy module
├── .github/workflows/
│   ├── terraform-plan.yml       # PR: fmt, validate, plan, comment
│   ├── terraform-apply.yml      # push to main: apply (manual approval gate)
│   └── terraform-destroy.yml    # manual-only teardown
└── docs/
    └── bootstrap.md             # one-time setup: state backend, OIDC, IAM role
```

## Quickstart

Full walkthrough in [docs/bootstrap.md](docs/bootstrap.md). Short version:

1. Create the S3 state bucket + DynamoDB lock table (one-time, manual).
2. Register GitHub's OIDC provider in IAM and create the deploy role,
   trust-scoped to this repo (one-time, manual).
3. Add the role ARN as a repo variable (`AWS_ROLE_ARN`).
4. Add a `production` GitHub Environment with required reviewers.
5. Open a PR - `terraform-plan.yml` comments the plan. Merge - `terraform-apply.yml`
   runs and waits for your approval.
6. When you're done: Actions -> **Terraform Destroy** -> type `destroy` -> approve.

## Verified end-to-end

Last full apply+destroy cycle run against a real AWS account on 2026-07-21.
Metrics from that run:

- **Apply**: ~13 min (EKS control plane provisioning dominates, ~10 min on
  its own; VPC, NAT, IAM, node group parallelize around it).
- **Destroy**: ~10 min in reverse order.
- **Cost of the run**: ~$0.19/hour × ~40 min ≈ **$0.13**.

Every mutating step gates on a manual approval in the `production` GitHub
Environment - `git push` alone never touches AWS:

![Apply waiting for environment approval](docs/screenshots/01-apply-environment-gate-approval.png)

The apply itself is mostly EKS control plane provisioning - the `Still
creating` counter is the honest bit of demoing IaC:

![Terraform apply mid-flight, EKS still creating](docs/screenshots/02-apply-in-progress-eks-provisioning.png)

Once the plane is up and the node group joins, the workflow finishes
clean:

![Apply succeeded in 13m 41s](docs/screenshots/03-apply-succeeded.png)

AWS Console sees the cluster it was told to create - same name, same K8s
version, same region as in `variables.tf`:

![EKS Console showing eks-platform-demo Active](docs/screenshots/04-aws-eks-cluster-active.png)

And `kubectl` from a laptop, authenticated through IAM against the fresh
API server, sees a `Ready` node and the expected system pods:

![kubectl cluster-info, get nodes, get pods -A](docs/screenshots/05-kubectl-nodes-and-pods.png)

Destroy runs through the same environment gate as apply, and reverses
everything in ~10 min:

![Destroy succeeded in 12m 0s](docs/screenshots/06-destroy-succeeded.png)

## What's deliberately simplified

This is a portfolio/demo repo, not a multi-account org:

- Single AWS account, single environment (`dev`).
- One NAT Gateway instead of one per AZ (saves ~$32/month; real prod HA
  wants per-AZ NAT).
- Deploy role uses `AdministratorAccess` for simplicity - a real account
  would scope this to exactly the actions Terraform needs.
- No multi-region, no Terraform workspaces per environment - the pattern
  extends cleanly to both, just not built out here.

## Known follow-ups

Things I know I'd do next if this were going past the demo:

- **Move cluster admin access into Terraform.** Right now the `eks` module
  is called without an `access_entries` argument, so post-apply you have
  to run `aws eks create-access-entry` once to give your laptop kubectl
  access (see [docs/bootstrap.md](docs/bootstrap.md) step 7). Cleaner
  place is inline in the module call, so admin list lives in state.
- **Scope the deploy IAM role down from `AdministratorAccess`** to the
  actual set of `ec2:*`, `eks:*`, `iam:*` (with `PassRole` conditions),
  `s3:*` on the state bucket, `dynamodb:*` on the lock table, and
  `logs:*` actions Terraform actually calls during apply/destroy.
- **Add `tflint` + `trivy config` (or `tfsec`)** to the plan workflow.
  IaC security scanning on every PR is table stakes; the plumbing is a
  10-line addition to `terraform-plan.yml`.
- **Restrict `cluster_endpoint_public_access_cidrs`.** Currently the
  public endpoint is open to `0.0.0.0/0` (behind IAM+TLS auth, but still
  more surface than needed). A real deploy would lock this to the office
  egress and the CI runner ranges.
- **pre-commit hooks** (`terraform_fmt`, `terraform_validate`,
  `terraform_docs`) so formatting drift and stale variable tables never
  reach a PR in the first place - the first CI run of this repo caught a
  fmt issue that pre-commit would have caught locally.

## Related

Companion homelab (bare-metal k3s, Prometheus/Thanos, SLO error budgets,
GitOps via ArgoCD): [homelab-k3s](https://github.com/bibigon14/homelab-k3s)
