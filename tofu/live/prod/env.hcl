# SCAFFOLDING ONLY — nothing in tofu/live/prod/ is applied by this refactor.
# These are placeholder values showing the shape a real prod environment
# would need, not vetted real ones. Before ever running `terragrunt apply`
# here, at minimum: pick a real unused VLAN ID/subnet (needs Unifi sign-off
# per CLAUDE.md — this VLAN doesn't exist yet), a real unused vm_id/IP range
# that doesn't collide with dev's (16010-16015 / 192.168.160.2-11), and a
# dedicated NFS export on the NAS (CLAUDE.md: "dev/prod will not share
# infrastructure — each gets its own NFS backend").
locals {
  network_cidr = "192.168.161.0/27" # placeholder — not yet an allocated subnet
  vlan_id      = 1602               # placeholder — not yet an allocated VLAN
  network_name = "K8s-Cluster-Prod"
  domain_name  = "k8s.thepugh.family" # placeholder — would collide with dev's ingress hostnames if both were ever live; needs a real decision

  cluster = {
    name            = "prod"
    endpoint        = "192.168.161.16" # placeholder VIP
    gateway         = "192.168.161.1"  # placeholder
    talos_version   = "v1.12.0"
    proxmox_cluster = "homelab" # same 3 physical Proxmox nodes as dev (unresolved question from #21: shared hardware capacity)
  }

  chart_versions = {
    metallb               = "0.14.8"
    ingress_nginx         = "4.11.2"
    cert_manager          = "1.15.1"
    argocd                = "7.3.7"
    argocd_apps           = "2.0.5"
    csi_driver_nfs        = "4.13.4"
    minio                 = "5.4.0"
    velero                = "12.1.0"
    keycloak              = "7.3.0"
    oauth2_proxy          = "10.7.0"
    kube_prometheus_stack = "88.6.0"
    loki                  = "7.3.0"
    alloy                 = "1.12.1"
  }

  velero_plugin_for_aws_version = "1.14.2"
  postgres_version              = "16"
  whoami_version                = "1.12.0"

  backup = {
    schedule           = "0 3 * * *"
    ttl                = "720h"
    minio_bucket       = "velero"
    minio_storage_size = "50Gi"
  }

  nfs_storage = {
    server = "truenas.thepugh.family"
    share  = "/mnt/Main/k8s-prod" # placeholder — dedicated export, not yet created
  }

  gitops = {
    repo_url = "https://github.com/ZanyHunter/homelab.git"
    revision = "main" # would likely want a release branch instead, once real
  }

  ksops_version = "4.5.1"

  # Placeholder — a real prod node topology hasn't been decided (issue #21:
  # same 3 Proxmox nodes as dev, or dedicated hardware?). vm_ids/IPs here are
  # illustrative only and don't avoid collision with dev's real ones.
  k8s_nodes = {
    "k8s-ctrl-00" = {
      proxmox_node  = "pve-node-0"
      role          = "controlplane"
      startup_order = 3
      vm_id         = 16110
      ip_address    = "192.168.161.2/27"
    },
    "k8s-ctrl-01" = {
      proxmox_node  = "pve-node-1"
      role          = "controlplane"
      startup_order = 4
      vm_id         = 16111
      ip_address    = "192.168.161.3/27"
    },
    "k8s-ctrl-02" = {
      proxmox_node  = "pve-node-2"
      role          = "controlplane"
      startup_order = 5
      vm_id         = 16112
      ip_address    = "192.168.161.4/27"
    },
    "k8s-node-00" = {
      proxmox_node  = "pve-node-0"
      role          = "worker"
      startup_order = 6
      vm_id         = 16113
      ip_address    = "192.168.161.9/27"
    },
    "k8s-node-01" = {
      proxmox_node  = "pve-node-1"
      role          = "worker"
      startup_order = 7
      vm_id         = 16114
      ip_address    = "192.168.161.10/27"
    },
    "k8s-node-02" = {
      proxmox_node  = "pve-node-2"
      role          = "worker"
      startup_order = 8
      vm_id         = 16115
      ip_address    = "192.168.161.11/27"
    }
  }
}
