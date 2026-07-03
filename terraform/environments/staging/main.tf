module "networking" {
  source = "../../modules/networking"

  environment        = var.environment
  # Must match the real EKS cluster name (modules/eks names it "${environment}-eks").
  # The in-tree AWS cloud-provider discovers LB subnets by the tag
  # kubernetes.io/cluster/<clusterName>; a mismatch makes it reject every subnet
  # ("could not find any suitable subnets for creating the ELB").
  cluster_name       = "${var.environment}-eks"
  vpc_cidr           = var.vpc_cidr
  public_subnets     = var.public_subnets
  private_subnets    = var.private_subnets
  availability_zones = var.availability_zones
}

module "eks" {
  source = "../../modules/eks"

  environment        = var.environment
  subnet_ids         = concat(module.networking.public_subnet_ids, module.networking.private_subnet_ids)
  private_subnet_ids = module.networking.private_subnet_ids
}

module "ecr" {
  source = "../../modules/ecr"

  environment     = var.environment
  repository_name = "backend"
}

module "ecr_frontend" {
  source = "../../modules/ecr"

  environment     = var.environment
  repository_name = "frontend"
}
