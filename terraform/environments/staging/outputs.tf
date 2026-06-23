output "vpc_id" {
  value = module.networking.vpc_id
}

output "public_subnet_ids" {
  value = module.networking.public_subnet_ids
}

output "private_subnet_ids" {
  value = module.networking.private_subnet_ids
}

output "ecr_backend_repository_url" {
  value = module.ecr.repository_url
}

output "ecr_frontend_repository_url" {
  value = module.ecr_frontend.repository_url
}
