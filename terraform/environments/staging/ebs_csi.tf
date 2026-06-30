# EBS CSI driver — lets PVCs dynamically provision real EBS volumes.
# Without it, the in-tree gp2 provisioner is dead (removed in EKS 1.23+) and
# Postgres' PVC stays Pending. Same IRSA pattern as ESO: a cluster controller
# needs an IAM role to call AWS (here EC2 CreateVolume/AttachVolume/etc).

# IAM role for the CSI controller's ServiceAccount. Only a managed policy here —
# AWS maintains AmazonEBSCSIDriverPolicy, so we don't hand-roll the JSON.
module "ebs_csi_irsa" {
  source = "../../modules/irsa"

  environment          = var.environment
  name                 = "ebs-csi"
  oidc_provider_arn    = module.eks.oidc_provider_arn
  oidc_provider_url    = module.eks.oidc_issuer_url
  namespace            = "kube-system"
  service_account_name = "ebs-csi-controller-sa"
  managed_policy_arns  = ["arn:aws:iam::aws:policy/service-role/AmazonEBSCSIDriverPolicy"]
}

# Install the driver as a managed EKS addon and wire its ServiceAccount to the
# IRSA role above. The addon creates the ebs-csi-controller-sa and annotates it.
resource "aws_eks_addon" "ebs_csi" {
  cluster_name             = module.eks.cluster_name
  addon_name               = "aws-ebs-csi-driver"
  service_account_role_arn = module.ebs_csi_irsa.role_arn

  # Node group must exist so the controller pods can schedule before the addon
  # reports healthy.
  depends_on = [module.eks]
}
