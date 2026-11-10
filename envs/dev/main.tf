module "network" {
  source = "../../modules/network"
  name   = "durian-dev"
  az     = var.az
}

module "k3s" {
  source         = "../../modules/k3s-node"
  name           = "durian-dev-k3s"
  vpc_id         = module.network.vpc_id
  subnet_id      = module.network.public_subnet_id
  instance_type  = var.instance_type
  volume_size_gb = 30
  admin_cidrs    = var.admin_cidrs
}
