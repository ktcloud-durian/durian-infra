# Embed the actual PR #10 team installer. No second HA installer is executed.
# Script is gzip+base64 compressed to respect AWS EC2 User Data limits.
# Headroom is small: rendered User Data must stay <= 16384 chars (aws_k3s_guard), and with
# install.sh at base64gzip ~14,680 chars only ~100 chars remain (measured 2026-11-27, PR #32).
# Put new monitor-only logic in scripts/monitoring/*.sh (like security-dashboard.sh, grafana-embed.sh),
# not in install.sh. Check: echo 'length(base64gzip(file("scripts/install.sh")))' | terraform console
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
