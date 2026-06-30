variable "environment" {
  type = string
}

variable "name" {
  type        = string
  description = "Short workload name, e.g. \"eso\". Used to build the role name."
}

variable "oidc_provider_arn" {
  type        = string
  description = "ARN of the cluster's IAM OIDC provider (from the eks module)."
}

variable "oidc_provider_url" {
  type        = string
  description = "Issuer URL of the cluster's OIDC provider, e.g. \"https://oidc.eks...\"."
}

variable "namespace" {
  type        = string
  description = "Namespace where the ServiceAccount lives."
}

variable "service_account_name" {
  type        = string
  description = "Name of the ServiceAccount allowed to assume this role."
}

variable "policy_json" {
  type        = string
  default     = null
  description = "Inline IAM permission policy (JSON) attached to the role. Optional: roles that only use managed policies can omit it."
}

variable "managed_policy_arns" {
  type        = list(string)
  default     = []
  description = "AWS-managed policy ARNs to attach (e.g. AmazonEBSCSIDriverPolicy). Use when AWS already maintains the right policy."
}
