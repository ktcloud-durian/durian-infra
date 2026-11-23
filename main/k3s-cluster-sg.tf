# DURIAN: separate AWS K3s clusters A (2a) and C (2c).
# These SGs are only created with aws_k3s_enabled=true.
# Neither the existing aws_security_group.node (durian-node) nor existing EC2
# aws_instance.this["k3s"] is changed by this file.
# Keep the old role["master"|"worker"|"node"] SGs temporarily for safe rollout;
# do NOT attach those shared SGs to the independent cluster instances.

locals {
  k3s_cluster_sg_ids = {
    for cluster in keys(aws_security_group.k3s_master) : cluster => {
      master = aws_security_group.k3s_master[cluster].id
      worker = aws_security_group.k3s_worker[cluster].id
    }
  }

  # Intra-cluster peer traffic only. No A<->C SG references.
  # Includes self-reference so adding further Workers in one cluster works.
  k3s_cluster_internal_ports = {
    flannel_vxlan = { protocol = "udp", port = 8472 }
    kubelet       = { protocol = "tcp", port = 10250 }
  }
  k3s_cluster_internal_flows = var.aws_k3s_enabled ? {
    for p in setproduct(sort(keys(local.az_keys)), ["master", "worker"], ["master", "worker"], sort(keys(local.k3s_cluster_internal_ports))) :
    "${p[0]}-${p[1]}-to-${p[2]}-${p[3]}" => {
      cluster = p[0]
      source  = p[1]
      target  = p[2]
      port    = local.k3s_cluster_internal_ports[p[3]].port
      proto   = local.k3s_cluster_internal_ports[p[3]].protocol
    }
  } : {}

  k3s_cluster_outbound_ports = {
    http             = { protocol = "tcp", port = 80 }
    https            = { protocol = "tcp", port = 443 }
    tailscale_stun   = { protocol = "udp", port = 3478 }
    tailscale_direct = { protocol = "udp", port = 41641 }
  }
  k3s_cluster_outbound_flows = var.aws_k3s_enabled ? {
    for p in setproduct(sort(keys(local.az_keys)), ["master", "worker"], sort(keys(local.k3s_cluster_outbound_ports))) :
    "${p[0]}-${p[1]}-${p[2]}" => {
      cluster = p[0]
      role    = p[1]
      port    = local.k3s_cluster_outbound_ports[p[2]].port
      proto   = local.k3s_cluster_outbound_ports[p[2]].protocol
    }
  } : {}

  k3s_cluster_monitor_flows = var.aws_k3s_enabled ? {
    for p in setproduct(sort(keys(local.az_keys)), ["master", "worker"]) :
    "${p[0]}-${p[1]}" => { cluster = p[0], role = p[1] }
  } : {}
}

resource "aws_security_group" "k3s_master" {
  for_each    = var.aws_k3s_enabled ? local.az_keys : {}
  name        = "durian-k3s-master-${each.key}-sg"
  description = "DURIAN isolated K3s master cluster ${each.key}"
  vpc_id      = aws_vpc.this.id
  tags = {
    Name    = "durian-k3s-master-${each.key}-sg"
    Cluster = each.key
    Role    = "master"
  }
}

resource "aws_security_group" "k3s_worker" {
  for_each    = var.aws_k3s_enabled ? local.az_keys : {}
  name        = "durian-k3s-worker-${each.key}-sg"
  description = "DURIAN isolated K3s worker cluster ${each.key}"
  vpc_id      = aws_vpc.this.id
  tags = {
    Name    = "durian-k3s-worker-${each.key}-sg"
    Cluster = each.key
    Role    = "worker"
  }
}

# Agent/Worker in cluster A reaches only master A; likewise C -> C.
resource "aws_vpc_security_group_ingress_rule" "k3s_cluster_master_api" {
  for_each                     = var.aws_k3s_enabled ? local.az_keys : {}
  security_group_id            = aws_security_group.k3s_master[each.key].id
  referenced_security_group_id = aws_security_group.k3s_worker[each.key].id
  ip_protocol                  = "tcp"
  from_port                    = 6443
  to_port                      = 6443
  description                  = "Cluster ${each.key} Worker to own Master K3s API"
}

resource "aws_vpc_security_group_egress_rule" "k3s_cluster_worker_master_api" {
  for_each                     = var.aws_k3s_enabled ? local.az_keys : {}
  security_group_id            = aws_security_group.k3s_worker[each.key].id
  referenced_security_group_id = aws_security_group.k3s_master[each.key].id
  ip_protocol                  = "tcp"
  from_port                    = 6443
  to_port                      = 6443
  description                  = "Cluster ${each.key} Worker to own Master API"
}

# Flannel VXLAN (8472/udp) and kubelet (10250/tcp) in SAME cluster only.
resource "aws_vpc_security_group_ingress_rule" "k3s_cluster_internal" {
  for_each = local.k3s_cluster_internal_flows

  security_group_id            = local.k3s_cluster_sg_ids[each.value.cluster][each.value.target]
  referenced_security_group_id = local.k3s_cluster_sg_ids[each.value.cluster][each.value.source]
  ip_protocol                  = each.value.proto
  from_port                    = each.value.port
  to_port                      = each.value.port
  description                  = "K3s ${each.value.cluster} ${each.value.source} to ${each.value.target} ${each.value.port}"
}

resource "aws_vpc_security_group_egress_rule" "k3s_cluster_internal" {
  for_each = local.k3s_cluster_internal_flows

  security_group_id            = local.k3s_cluster_sg_ids[each.value.cluster][each.value.source]
  referenced_security_group_id = local.k3s_cluster_sg_ids[each.value.cluster][each.value.target]
  ip_protocol                  = each.value.proto
  from_port                    = each.value.port
  to_port                      = each.value.port
  description                  = "K3s ${each.value.cluster} ${each.value.source} to ${each.value.target} ${each.value.port}"
}

# EC2 bootstrap (apt/K3s/Helm/SSM/GitHub) and Tailscale outbound.
# Egress alone does not create a route: private subnets still require approved NAT
# or endpoints, and VPC DNS/NTP need checking before enabling the cluster.
# EX-03 (NET-01): isolated master/worker startup via approved NAT path
# Scope: this Terraform resource only. Review 2026-12-04.
#trivy:ignore:AVD-AWS-0104:exp:2026-12-04
resource "aws_vpc_security_group_egress_rule" "k3s_cluster_bootstrap" {
  for_each = local.k3s_cluster_outbound_flows

  security_group_id = local.k3s_cluster_sg_ids[each.value.cluster][each.value.role]
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = each.value.proto
  from_port         = each.value.port
  to_port           = each.value.port
  description       = "Cluster ${each.value.cluster} ${each.value.role} outbound ${each.value.proto}/${each.value.port}"
}

# Existing role["mgmt"] SG can scrape Node Exporter on new cluster instances.
# Both directions are required because the new K3s role SGs have no allow-all egress.
resource "aws_vpc_security_group_ingress_rule" "k3s_cluster_exporter" {
  for_each                     = local.k3s_cluster_monitor_flows
  security_group_id            = local.k3s_cluster_sg_ids[each.value.cluster][each.value.role]
  referenced_security_group_id = aws_security_group.role["mgmt"].id
  ip_protocol                  = "tcp"
  from_port                    = 9100
  to_port                      = 9100
  description                  = "Monitor to Cluster ${each.value.cluster} ${each.value.role} exporter"
}

resource "aws_vpc_security_group_egress_rule" "k3s_cluster_monitor_exporter" {
  for_each                     = local.k3s_cluster_monitor_flows
  security_group_id            = aws_security_group.role["mgmt"].id
  referenced_security_group_id = local.k3s_cluster_sg_ids[each.value.cluster][each.value.role]
  ip_protocol                  = "tcp"
  from_port                    = 9100
  to_port                      = 9100
  description                  = "Monitor to Cluster ${each.value.cluster} ${each.value.role} exporter"
}
