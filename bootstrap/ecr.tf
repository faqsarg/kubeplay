# Container registries — DURABLE layer.
#
# A registry holds build artifacts (your release history), and CI must be able to
# push to it whether or not any cluster exists. That makes it durable infrastructure,
# co-located here with the CI role that pushes to it — NOT part of the ephemeral
# staging environment that gets torn down each session. Keeping it here is what
# actually makes "CI works even when staging is destroyed" true.
#
# The `staging-` name prefix (from the module's ${environment}- convention) describes
# the deployment TRACK the image targets, not where the repo lives. A production track
# would add its own repos in this same durable layer later.
module "ecr" {
  source = "../terraform/modules/ecr"

  environment     = "staging"
  repository_name = "backend"
}

module "ecr_frontend" {
  source = "../terraform/modules/ecr"

  environment     = "staging"
  repository_name = "frontend"
}

output "ecr_backend_repository_url" {
  value = module.ecr.repository_url
}

output "ecr_frontend_repository_url" {
  value = module.ecr_frontend.repository_url
}
