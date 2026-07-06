# Read-only role for the Terraform PR pipeline (.github/workflows/terraform.yml).
#
# `terraform plan` must read state from S3 and refresh resources (describe/list
# across services) — but it must NEVER mutate. So this role gets the AWS-managed
# ReadOnlyAccess policy and nothing else. `apply` stays a deliberate, manual human
# action; CI never assumes a role that can change infrastructure.
#
# It reuses the SAME trust document as the CI role (github_oidc.tf): both are
# assumed by GitHub tokens from this repo. Trust (who may assume) and permissions
# (what they may do) are independent, so sharing the trust policy is fine.
resource "aws_iam_role" "github_plan" {
  name               = "kubeplay-github-plan"
  assume_role_policy = data.aws_iam_policy_document.github_ci_assume.json

  tags = {
    Project = "cloud-platform"
  }
}

resource "aws_iam_role_policy_attachment" "github_plan_readonly" {
  role       = aws_iam_role.github_plan.name
  policy_arn = "arn:aws:iam::aws:policy/ReadOnlyAccess"
}

# Consumed by terraform.yml (aws-actions/configure-aws-credentials: role-to-assume).
output "github_plan_role_arn" {
  value = aws_iam_role.github_plan.arn
}
