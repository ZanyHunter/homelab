# Real, applied environment (stood up as part of the dev/prod VLAN reorg —
# see CLAUDE.md's History). Prod took over VLAN 1601 / 192.168.160.0/27, the
# exact range dev used to occupy — its Unifi network object was already
# named "K8s-Cluster-Prod" (a leftover from before dev/prod were split
# apart), so this reorg is what makes that name actually true. Dev moved to
# a new, same-sized block (VLAN 1602 / 192.168.160.32/27) to make room.
locals {
  network_cidr = "192.168.160.0/27"
  vlan_id      = 1601
  network_name = "K8s-Cluster-Prod"
  # The real domain, bare apex — no longer collides with dev now that dev
  # moved to its own dev.thepugh.family suffix (#10). Drives every ingress
  # hostname/OIDC redirect URI the same way dev's does.
  domain_name = "thepugh.family"
  # Static, not the MetalLB-assigned live value — see dev's env.hcl for why.
  ingress_ip = "192.168.160.9"

  cluster = {
    name            = "prod"
    endpoint        = "192.168.160.2" # Floating control-plane VIP (Talos-managed) — first address after the gateway
    gateway         = "192.168.160.1"
    talos_version   = "v1.12.0"
    proxmox_cluster = "homelab" # same 3 physical Proxmox nodes as dev (unresolved question from #21: shared hardware capacity)
  }

  # Mirrors dev's node_resources shape/values for consistency — see dev's
  # env.hcl for the reasoning. Running both dev and prod at these sizes
  # simultaneously on the same 3 physical hosts is the same unresolved
  # shared-hardware-capacity question noted on `cluster` above; revisit
  # before prod is ever actually applied.
  node_resources = {
    controlplane = {
      cores  = 4
      memory = 4096
    }
    worker = {
      cores  = 8
      memory = 16384
    }
  }

  chart_versions = {
    metallb               = "0.14.8"
    ingress_nginx         = "4.11.2"
    cert_manager          = "1.15.1"
    argocd                = "7.3.7"
    argocd_apps           = "2.0.5"
    csi_driver_nfs        = "4.13.4"
    ceph_csi_rbd          = "3.17.1"
    minio                 = "5.4.0"
    velero                = "12.1.0"
    keycloak              = "7.3.0"
    oauth2_proxy          = "10.7.0"
    kube_prometheus_stack = "88.6.0"
    loki                  = "7.3.0"
    alloy                 = "1.12.1"
    external_secrets      = "2.10.0"
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
    share  = "/mnt/Main/k8s-prod"
  }

  # Same physical Ceph cluster as dev (shared hardware — see cluster.proxmox_cluster
  # below), so fsid/monitors are identical; only the pool name is env-scoped so
  # dev/prod don't collide on the same physical cluster. Pool itself doesn't exist
  # yet — created when prod's talos-cluster unit is actually applied.
  ceph = {
    pool_name  = "k8s-prod-rbd"
    cluster_id = "d783e88c-059c-4549-8b14-54ec5625add4"
    monitors = [
      "192.168.150.2:6789",
      "192.168.150.3:6789",
      "192.168.150.4:6789",
    ]
  }

  gitops = {
    repo_url = "https://github.com/ZanyHunter/homelab.git"
    # Prod stays on "main" — the promoted-to branch in the two-stage
    # pipeline (#51). Dev tracks "development" instead (see dev's own
    # env.hcl); a change only reaches prod once its development -> main
    # promotion PR merges.
    revision = "main"
  }

  # Same zone (thepugh.family) as dev's cloudflare_zone_id, since prod's
  # domain_name is the real apex itself rather than a subdomain — same
  # account/zone, just the one Cloudflare account this repo has.
  cloudflare_account_id = "7eee532c0b49dbdd2f93dcb13de9df7a"
  cloudflare_zone_id    = "f57b43e69b149c9be3483b4452f483d4"
  cloudflared_version   = "2026.8.2"
  # No suffix needed — prod's own domain_name is already the bare apex, so
  # there's no Universal SSL coverage gap to work around (unlike dev's
  # "-dev" suffix — see the comment on public_hostnames in
  # core-addons/main.tf).
  public_apex_domain     = "thepugh.family"
  public_hostname_suffix = ""

  # Prod is the one environment meant to be publicly exposed long-term
  # (#33/#39/#40). The legacy Immich instance (and the other legacy apps)
  # have been moved to <service>-legacy.thepugh.family, freeing
  # photos.thepugh.family for prod's own Immich — confirmed live via a
  # real showmount-style check before this went in. public_keycloak_realm
  # gates the one narrow ^/realms/homelab/.* tunnel route Immich's public
  # OIDC login needs; the admin console stays internal/VPN-only regardless.
  #
  # matrix/element (#57): the client-server API + Element Web, so off-LAN
  # clients (a phone on cellular) can actually reach Matrix. Federation and
  # TURN/voice-calls stay off regardless (var.public_matrix_wellknown below
  # only ever opens the /.well-known/matrix/* discovery path, not federation
  # itself — see docs/src/explanation/matrix.md).
  public_ingress_enabled = true
  public_apps = [
    { hostname = "photos" },
    { hostname = "matrix" },
    { hostname = "element" },
  ]
  public_keycloak_realm = true
  # Matrix's apex-based server_name identity (#57) needs /.well-known/matrix/*
  # reachable at exactly https://thepugh.family/ — only satisfiable here
  # because prod's own domain_name already IS the real apex. See
  # core-addons' public_matrix_wellknown variable description.
  public_matrix_wellknown = true

  # Real-time calling's LiveKit SFU (#72) — a static MetalLB IP (free within
  # this environment's own lb-pool-range, apps/cluster-addons/overlays/prod/
  # env-values.yaml) for its single-port UDP mux Service.
  # matrix_calls_public_udp_forward stays false even in prod until calling
  # is actually verified working on dev first and deliberately promoted
  # beyond LAN/VPN testing — not flipped on as part of this same rollout.
  matrix_calls_udp_ip             = "192.168.160.10"
  matrix_calls_public_udp_forward = false


  ksops_version = "4.5.1"

  # Same node names/vm_id-prefix dev used to have on this exact address
  # block — freed by dev's destroy as part of this reorg. Dev's own nodes
  # moved to a disjoint vm_id band (16020-16025) on its new subnet to avoid
  # colliding with these, since both environments share third octet 160.
  k8s_nodes = {
    "k8s-ctrl-00" = {
      proxmox_node  = "pve-node-0"
      role          = "controlplane"
      startup_order = 3
      vm_id         = 16010
      ip_address    = "192.168.160.3/27"
    },
    "k8s-ctrl-01" = {
      proxmox_node  = "pve-node-1"
      role          = "controlplane"
      startup_order = 4
      vm_id         = 16011
      ip_address    = "192.168.160.4/27"
    },
    "k8s-ctrl-02" = {
      proxmox_node  = "pve-node-2"
      role          = "controlplane"
      startup_order = 5
      vm_id         = 16012
      ip_address    = "192.168.160.5/27"
    },
    "k8s-node-00" = {
      proxmox_node  = "pve-node-0"
      role          = "worker"
      startup_order = 6
      vm_id         = 16013
      ip_address    = "192.168.160.6/27"
    },
    "k8s-node-01" = {
      proxmox_node  = "pve-node-1"
      role          = "worker"
      startup_order = 7
      vm_id         = 16014
      ip_address    = "192.168.160.7/27"
    },
    "k8s-node-02" = {
      proxmox_node  = "pve-node-2"
      role          = "worker"
      startup_order = 8
      vm_id         = 16015
      ip_address    = "192.168.160.8/27"
    }
  }
}
