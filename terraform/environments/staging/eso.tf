# Look up the Postgres secret created in the bootstrap layer (by name),
# so this environment doesn't need to read bootstrap's state directly.
data "aws_secretsmanager_secret" "postgres" {
  name = "kubeplay/${var.environment}/postgres"
}

# Permission policy: this role may ONLY read that one secret (least privilege).
data "aws_iam_policy_document" "eso_secrets" {
  statement {
    effect    = "Allow"
    actions   = ["secretsmanager:GetSecretValue"]
    resources = [data.aws_secretsmanager_secret.postgres.arn]
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
