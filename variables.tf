variable "aws_region" {
  description = "AWS region for all resources."
  type        = string
  default     = "us-west-2"
}

variable "project_name" {
  description = "Short name used for tagging and resource naming."
  type        = string
  default     = "terraform-eks-platform"
}

variable "environment" {
  description = "Environment name (dev/staging/prod). This repo is designed to be spun up and torn down on demand, so 'dev' is the expected day-to-day value."
  type        = string
  default     = "dev"
}

variable "vpc_cidr" {
  description = "CIDR block for the VPC."
  type        = string
  default     = "10.20.0.0/16"
}

variable "az_count" {
  description = "Number of Availability Zones to spread subnets across. 2 is enough for a demo cluster and keeps NAT Gateway cost down."
  type        = number
  default     = 2
}

variable "cluster_name" {
  description = "EKS cluster name."
  type        = string
  default     = "eks-platform-demo"
}

variable "cluster_version" {
  description = "Kubernetes version for the EKS control plane."
  type        = string
  default     = "1.30"
}

variable "node_instance_types" {
  description = "EC2 instance types for the managed node group. t3.medium is the smallest practical size for EKS system pods + a demo workload."
  type        = list(string)
  default     = ["t3.medium"]
}

variable "node_desired_size" {
  description = "Desired number of worker nodes. Kept at 1 by default to minimize cost - bump to 2+ only when you need to demo HA/scheduling behavior."
  type        = number
  default     = 1
}

variable "node_min_size" {
  type    = number
  default = 1
}

variable "node_max_size" {
  type    = number
  default = 3
}

variable "single_nat_gateway" {
  description = "Use one NAT Gateway for all private subnets instead of one per AZ. Saves ~$32/month per extra NAT Gateway; fine for a demo, not what you'd do for real prod HA."
  type        = bool
  default     = true
}
