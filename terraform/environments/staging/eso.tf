# The single, cluster-wide ESO controller reads the Postgres secret for BOTH the
# staging and production namespaces, so its one IAM role must be allowed to read
# both. We CONSTRUCT the ARNs (region + account + name) instead of looking the
# secrets up with a data source: a `data aws_secretsmanager_secret` fails `plan`
# whenever the secret doesn't exist yet — e.g. the read-only CI plan gate, which
# never applies the bootstrap layer, or a fresh clone before any apply. IAM
# evaluates permissions at request time and never validates existence, so building
# the ARN decouples the plan from provisioning order (same rationale as the CI
# ECR-push role). Still least privilege: the two secret NAMES are enumerated, and
# `-??????` matches only the 6-char suffix AWS appends — not other secrets.
data "aws_caller_identity" "current" {}

locals {
  secret_arn_prefix = "arn:aws:secretsmanager:eu-west-1:${data.aws_caller_identity.current.account_id}:secret"
}

data "aws_iam_policy_document" "eso_secrets" {
  statement {
    effect  = "Allow"
    actions = ["secretsmanager:GetSecretValue"]
    resources = [
      "${local.secret_arn_prefix}:kubeplay/${var.environment}/postgres-??????",
      "${local.secret_arn_prefix}:kubeplay/production/postgres-??????",
    ]
  }
}

# Instantiate the generic IRSA module for ESO's ServiceAccount.
module "eso_irsa" {
  source = "../../modules/irsa"

  environment          = var.environment
  name                 = "eso"
  oidc_provider_arn    = module.eks.oidc_provider_arn
  oidc_provider_url    = module.eks.oidc_issuer_url
  namespace            = "external-secrets"
  service_account_name = "external-secrets"
  policy_json          = data.aws_iam_policy_document.eso_secrets.json
}

# Exposed so we can annotate ESO's ServiceAccount with it at Helm install time.
output "eso_irsa_role_arn" {
  value = module.eso_irsa.role_arn
}
