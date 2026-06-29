# Trust policy: only the given ServiceAccount, presenting a token from this
# cluster's OIDC provider, may assume the role (this is the IRSA mechanism).
data "aws_iam_policy_document" "assume_role" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [var.oidc_provider_arn]
    }

    # pin the exact ServiceAccount via the token's `sub` claim
    condition {
      test     = "StringEquals"
      variable = "${replace(var.oidc_provider_url, "https://", "")}:sub"
      values   = ["system:serviceaccount:${var.namespace}:${var.service_account_name}"]
    }

    # require the AWS STS audience
    condition {
      test     = "StringEquals"
      variable = "${replace(var.oidc_provider_url, "https://", "")}:aud"
      values   = ["sts.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "this" {
  name               = "${var.environment}-${var.name}-irsa"
  assume_role_policy = data.aws_iam_policy_document.assume_role.json
}

# permissions the caller decided this role should have
resource "aws_iam_role_policy" "this" {
  name   = "${var.environment}-${var.name}-policy"
  role   = aws_iam_role.this.id
  policy = var.policy_json
}
