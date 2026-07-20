variable "role_name" {
  description = "Name for the IAM role."
  type        = string
}

variable "oidc_provider_arn" {
  description = "ARN of the EKS cluster's OIDC identity provider (module.eks.oidc_provider_arn)."
  type        = string
}

variable "oidc_provider_url" {
  description = "Issuer URL of the EKS cluster's OIDC provider, without the https:// prefix requirement handled internally (module.eks.cluster_oidc_issuer_url)."
  type        = string
}

variable "namespace" {
  description = "Kubernetes namespace the service account lives in."
  type        = string
}

variable "service_account_name" {
  description = "Kubernetes service account name that is allowed to assume this role."
  type        = string
}

variable "policy_arns" {
  description = "List of IAM managed policy ARNs to attach to the role. Keep this as narrow as the workload actually needs - that's the entire point of IRSA over a shared node instance profile."
  type        = list(string)
  default     = []
}
