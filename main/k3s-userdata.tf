# Embed the actual PR #10 team installer. No second HA installer is executed.
# Script is gzip+base64 compressed to respect AWS EC2 User Data limits.
locals {
  k3s_userdata_common = {
    install_script_gz    = base64gzip(file("${path.module}/scripts/install.sh"))
    k3s_version          = var.aws_k3s_version
    argocd_chart_version = var.aws_k3s_argocd_chart_version
    pod_cidr             = var.aws_k3s_pod_cidr
    service_cidr         = var.aws_k3s_service_cidr
    bootstrap_execute    = var.aws_k3s_bootstrap_approved
    require_tailscale    = var.aws_k3s_require_tailscale
    region               = var.region
  }
  k3s_master_user_data = {
    for cluster in keys(local.az_keys) : cluster => templatefile(
      "${path.module}/scripts/k3s-userdata.sh.tftpl",
      merge(local.k3s_userdata_common, { role = "master", cluster = cluster })
    )
  }
  k3s_worker_user_data = {
    for cluster in keys(local.az_keys) : cluster => templatefile(
      "${path.module}/scripts/k3s-userdata.sh.tftpl",
      merge(local.k3s_userdata_common, { role = "worker", cluster = cluster })
    )
  }
}
