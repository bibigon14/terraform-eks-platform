data "aws_availability_zones" "available" {
  filter {
    name   = "opt-in-status"
    values = ["opt-in-not-required"]
  }
}

locals {
  azs = slice(data.aws_availability_zones.available.names, 0, var.az_count)

  # /24s for public (one per AZ), /20s for private (one per AZ), carved out of vpc_cidr.
  public_subnets  = [for i in range(var.az_count) : cidrsubnet(var.vpc_cidr, 8, i)]
  private_subnets = [for i in range(var.az_count) : cidrsubnet(var.vpc_cidr, 4, i + 1)]
}

# ── Networking ───────────────────────────────────────────────────────────────
# Community module instead of hand-rolled VPC resources: it's the de-facto
# standard, battle-tested, and already knows the exact subnet tags EKS/ALB
# controller expect (kubernetes.io/role/elb, kubernetes.io/cluster/<name>).
module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "~> 5.13"

  name = "${var.project_name}-vpc"
  cidr = var.vpc_cidr

  azs             = local.azs
  public_subnets  = local.public_subnets
  private_subnets = local.private_subnets

  enable_nat_gateway   = true
  single_nat_gateway   = var.single_nat_gateway
  enable_dns_hostnames = true

  # Required so the AWS Load Balancer Controller and EKS itself can
  # auto-discover which subnets to use.
  public_subnet_tags = {
    "kubernetes.io/role/elb"                    = "1"
    "kubernetes.io/cluster/${var.cluster_name}" = "shared"
  }
  private_subnet_tags = {
    "kubernetes.io/role/internal-elb"           = "1"
    "kubernetes.io/cluster/${var.cluster_name}" = "shared"
  }
}

# ── EKS cluster ──────────────────────────────────────────────────────────────
module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "~> 20.31"

  cluster_name    = var.cluster_name
  cluster_version = var.cluster_version

  vpc_id     = module.vpc.vpc_id
  subnet_ids = module.vpc.private_subnets

  cluster_endpoint_public_access = true

  # This is what makes IRSA (IAM Roles for Service Accounts) possible: it
  # provisions the OIDC identity provider for the cluster that our own
  # irsa-role module then trusts.
  enable_irsa = true

  eks_managed_node_groups = {
    default = {
      instance_types = var.node_instance_types
      capacity_type  = "ON_DEMAND"

      min_size     = var.node_min_size
      max_size     = var.node_max_size
      desired_size = var.node_desired_size
    }
  }

  tags = {
    Project = var.project_name
  }
}

# ── Example IRSA role ────────────────────────────────────────────────────────
# Demonstrates the pattern end to end: a pod running as this service account
# gets short-lived AWS credentials scoped to exactly the permissions below,
# no node-wide instance profile, no long-lived keys in a Secret.
module "demo_s3_reader_irsa" {
  source = "./modules/irsa-role"

  role_name            = "${var.cluster_name}-s3-reader"
  oidc_provider_arn    = module.eks.oidc_provider_arn
  oidc_provider_url    = module.eks.cluster_oidc_issuer_url
  namespace            = "default"
  service_account_name = "s3-reader"
  policy_arns = [
    "arn:aws:iam::aws:policy/AmazonS3ReadOnlyAccess"
  ]
}
