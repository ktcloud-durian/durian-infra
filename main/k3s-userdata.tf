locals {
  k3s_userdata_common = {
    image_registry      = var.aws_k3s_image_registry
    team_prep_gz        = base64gzip(file("${path.module}/scripts/team-node-prep.sh"))
    argocd_installer_gz = base64gzip(file("${path.module}/scripts/install-argocd-gitops.sh"))
    traefik_config_gz   = base64gzip(file("${path.module}/scripts/traefik-config.yaml"))
    bootstrap_runner_gz = base64gzip(file("${path.module}/scripts/run-k3s-bootstrap.sh"))
    bootstrap_execute   = var.aws_k3s_bootstrap_approved
    ecr_setup_gz        = base64gzip(file("${path.module}/scripts/setup-ecr-provider.sh"))
    ecr_config_gz       = base64gzip(file("${path.module}/scripts/ecr-credential-provider-config.yaml"))
    k3s_version         = var.aws_k3s_version
    ecr_fetch_gz        = base64gzip(file("${path.module}/scripts/fetch-ecr-provider.sh"))
    ecr_provider_sha256 = trimspace(file("${path.module}/scripts/ecr-provider.sha256"))
    ecr_s3_bucket       = var.aws_k3s_ecr_s3_bucket
    ecr_s3_key          = var.aws_k3s_ecr_s3_key
  }

  k3s_master_user_data = templatefile(
    "${path.module}/scripts/k3s-userdata.sh.tftpl",
    merge(local.k3s_userdata_common, {
      role           = "master"
      role_script_gz = base64gzip(file("${path.module}/scripts/install-k3s-ha-master.sh"))
    })
  )

  k3s_worker_user_data = templatefile(
    "${path.module}/scripts/k3s-userdata.sh.tftpl",
    merge(local.k3s_userdata_common, {
      role           = "worker"
      role_script_gz = base64gzip(file("${path.module}/scripts/install-k3s-ha-worker.sh"))
    })
  )
}
