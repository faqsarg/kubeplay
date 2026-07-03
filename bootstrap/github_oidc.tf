# GitHub Actions OIDC — lets our CI workflows authenticate to AWS with a short-lived
# token instead of long-lived access keys stored as repo secrets.
#
# This is a SECOND OIDC federation in the project: the cluster already runs one
# (EKS -> pods, used by IRSA for ESO and the EBS CSI). Same mechanism
# (sts:AssumeRoleWithWebIdentity), different issuer. It lives here in bootstrap/
# (the durable layer) because CI must build and push images even when the cluster
# is torn down — and the provider is account-global, not tied to any cluster.

# 1. Register GitHub's token issuer as trusted in our AWS account.
#    - url:            who signs the tokens (GitHub's OIDC issuer)
#    - client_id_list: the audience we require in the token's `aud` claim.
#                      aws-actions/configure-aws-credentials requests aud=sts.amazonaws.com.
resource "aws_iam_openid_connect_provider" "github" {
  url            = "https://token.actions.githubusercontent.com"
  client_id_list = ["sts.amazonaws.com"]
}

data "aws_caller_identity" "current" {}

locals {
  github_repo = "faqsarg/kubeplay"

  # ECR repo ARNs built by hand (not a cross-state lookup): the repos live in the
  # ephemeral staging state, but this durable role must not depend on it.
  ecr_repo_arns = [
    for name in ["staging-backend", "staging-frontend"] :
    "arn:aws:ecr:${var.aws_region}:${data.aws_caller_identity.current.account_id}:repository/${name}"
  ]
}

# 2. The CI role — TRUST POLICY only (who may assume it). Its PERMISSIONS (what it
#    may do, e.g. push to ECR) are a separate policy attached next. As written, this
#    role trusts our repo's GitHub tokens but can do nothing yet: in IAM, "who can
#    assume" and "what they can do" are independent.
data "aws_iam_policy_document" "github_ci_assume" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [aws_iam_openid_connect_provider.github.arn]
    }

    # audience must be exactly the STS audience we registered on the provider
    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:aud"
      values   = ["sts.amazonaws.com"]
    }

    # StringLike (not Equals) so the trailing `*` works: any workflow / branch /
    # event in THIS repo may assume the role — but no other repo can.
    condition {
      test     = "StringLike"
      variable = "token.actions.githubusercontent.com:sub"
      values   = ["repo:${local.github_repo}:*"]
    }
  }
}

resource "aws_iam_role" "github_ci" {
  name               = "kubeplay-github-ci"
  assume_role_policy = data.aws_iam_policy_document.github_ci_assume.json

  tags = {
    Project = "cloud-platform"
  }
}

# 3. Permissions: what the CI role may DO. Two statements because ECR splits the
#    login token from the push actions at the IAM level.
data "aws_iam_policy_document" "github_ci_permissions" {
  # (a) the docker login token. GetAuthorizationToken is a registry-wide action —
  #     it returns a token for the whole registry, so IAM only accepts Resource "*".
  #     Scoping it to a repo ARN would never match and `docker login` would fail.
  statement {
    sid       = "EcrLogin"
    effect    = "Allow"
    actions   = ["ecr:GetAuthorizationToken"]
    resources = ["*"]
  }

  # (b) the actual push — repository-level actions, scoped to just our two repos.
  statement {
    sid    = "EcrPush"
    effect = "Allow"
    actions = [
      "ecr:BatchCheckLayerAvailability",
      "ecr:InitiateLayerUpload",
      "ecr:UploadLayerPart",
      "ecr:CompleteLayerUpload",
      "ecr:PutImage",
    ]
    resources = local.ecr_repo_arns
  }
}

resource "aws_iam_role_policy" "github_ci" {
  name   = "kubeplay-github-ci-ecr"
  role   = aws_iam_role.github_ci.id
  policy = data.aws_iam_policy_document.github_ci_permissions.json
}

# Consumed by ci.yml (aws-actions/configure-aws-credentials: role-to-assume).
output "github_ci_role_arn" {
  value = aws_iam_role.github_ci.arn
}
