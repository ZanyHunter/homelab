locals {
  # Moved off VLAN 1601 / 192.168.160.0/27 (the /27 expanded from a /28,
  # see issue #3) as part of the dev/prod VLAN reorg — that range and its
  # "K8s-Cluster-Prod" name (a leftover from before dev/prod were split
  # apart) now belong to prod, whose Unifi network object was already
  # named that. Dev takes a new, same-sized (/27) block instead. See
  # CLAUDE.md's History.
  network_cidr = "192.168.160.32/27"
  vlan_id      = 1602
  network_name = "K8s-Cluster-Dev"
  # Drives every ingress hostname and OIDC redirect URI in the codebase
  # (core-addons/keycloak-infra/keycloak-realm/observability all read this
  # directly, no Terragrunt dependency wiring needed) — the "k8s" subdomain
  # scheme is retired (#10), replaced by one suffix per environment.
  domain_name = "dev.thepugh.family"
  # Static, not the MetalLB-assigned live value, specifically so the
  # network unit's wildcard DNS record (#10) doesn't need a Tofu dependency
  # on core-addons (which applies after network in the DAG — a cycle
  # otherwise). core-addons pins ingress-nginx's Service to this exact IP
  # via the metallb.universe.tf/loadBalancerIPs annotation instead of
  # letting MetalLB assign it dynamically. Already what's live today.
  ingress_ip = "192.168.160.41"

  cluster = {
    name = "dev"
    # Floating control-plane VIP (Talos-managed, not any single node's address) — see
    # modules/talos-cluster's local.k8s_virtual_ip. First address after the gateway.
    endpoint        = "192.168.160.34"
    gateway         = "192.168.160.33"
    talos_version   = "v1.12.0"
    proxmox_cluster = "homelab"
  }

  # Control-plane nodes carry no scheduled workloads (Talos taints them by
  # default) and have never shown memory pressure at this size, so they stay
  # small. Workers went from 4GB/4 vCPU to this after Loki's chunksCache and
  # Immich's ML service both needed real headroom the old size didn't have —
  # physical hosts are 3x i9-12900H (14 cores/20 threads, 64GB RAM each), so
  # there's plenty of room for both this and a future prod cluster alongside
  # Ceph/Proxmox's own overhead.
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
    ttl                = "720h" # 30 days
    minio_bucket       = "velero"
    minio_storage_size = "50Gi"
  }

  nfs_storage = {
    server = "truenas.thepugh.family"
    share  = "/mnt/Main/k8s-dev"
  }

  # The existing Proxmox Ceph cluster (ceph-1 datastore, already backing
  # Talos VM disks) exposed to Kubernetes as a second StorageClass for
  # database/block-semantics-sensitive workloads (#28) — a dedicated pool
  # within that same cluster, not new hardware or a separate cluster. fsid
  # and monitors are facts about the shared physical cluster (same for any
  # future prod, since it's the same 3 physical nodes), looked up live via
  # `ceph mon dump` / the Proxmox Ceph status API rather than guessed.
  ceph = {
    pool_name  = "k8s-dev-rbd"
    cluster_id = "d783e88c-059c-4549-8b14-54ec5625add4"
    monitors = [
      "192.168.150.2:6789",
      "192.168.150.3:6789",
      "192.168.150.4:6789",
    ]
  }

  gitops = {
    repo_url = "https://github.com/ZanyHunter/homelab.git"
    # Dev's ArgoCD tracks the persistent "development" branch, not "main" —
    # the two-stage promotion pipeline (#51): feature branch -> PR ->
    # development (dev picks this up) -> PR -> main (prod picks this up,
    # see prod's own env.hcl). Applies to Tofu changes too, by convention
    # (not mechanically enforced the way this is for ArgoCD-managed apps/ —
    # see CLAUDE.md's Git workflow section).
    revision = "development"
  }

  # Not secrets in Cloudflare's own model (identifiers, not credentials) —
  # visible on the dashboard's Overview page for the domain. See
  # docs/src/explanation/public-ingress.md's manual step.
  cloudflare_account_id = "7eee532c0b49dbdd2f93dcb13de9df7a"
  cloudflare_zone_id    = "f57b43e69b149c9be3483b4452f483d4"
  cloudflared_version   = "2026.8.2"
  # Public hostnames live one level under this apex (Cloudflare's free
  # Universal SSL only covers *.thepugh.family, not *.dev.thepugh.family —
  # see the comment on public_hostnames in core-addons/main.tf), with a
  # "-dev" suffix so dev and prod never collide on the same public hostname
  # for the same app. Only matters if public_ingress_enabled is ever
  # flipped back on here.
  public_apex_domain     = "thepugh.family"
  public_hostname_suffix = "-dev"

  # No public ingress in dev, long-term: only prod is meant to be publicly
  # exposed (#33/#39/#40). Dev's own exposure was a temporary proof that the
  # whole mechanism (Cloudflare Tunnel, Keycloak's allowlisted realm route,
  # the Universal SSL hostname split) actually works end-to-end — it did,
  # and surfaced a real Keycloak `redirect_uri` mismatch once tested from
  # outside (Immich's OAuth flow computes its redirect_uri from whichever
  # hostname the browser actually used, and only the internal one was
  # registered on the Keycloak client) that isn't worth chasing here when
  # prod's own domain_name is already the bare apex — no hostname split, no
  # mismatch, ever. See docs/src/explanation/public-ingress.md.
  public_ingress_enabled = false
  public_apps            = []
  public_keycloak_realm  = false
  # Structurally can never be true here — dev's domain_name is a subdomain of
  # the real apex, not the apex itself, so it could never get valid Universal
  # SSL for a bare-domain_name route even if public_ingress_enabled were on.
  # See core-addons' public_matrix_wellknown variable description.
  public_matrix_wellknown = false

  ksops_version = "4.5.1"

  # "dev" inserted after the role so hostnames self-identify the
  # environment (prod keeps the clean, unprefixed k8s-ctrl-00/k8s-node-00
  # names) — vm_ids share prod's "160" third-octet prefix (both
  # environments' subnets fall in 192.168.160.0/24) but use a disjoint
  # node-index band (20-25, vs. prod's 10-15) to avoid colliding.
  k8s_nodes = {
    "k8s-dev-ctrl-00" = {
      proxmox_node  = "pve-node-0"
      role          = "controlplane"
      startup_order = 3
      vm_id         = 16020
      ip_address    = "192.168.160.35/27"
    },
    "k8s-dev-ctrl-01" = {
      proxmox_node  = "pve-node-1"
      role          = "controlplane"
      startup_order = 4
      vm_id         = 16021
      ip_address    = "192.168.160.36/27"
    },
    "k8s-dev-ctrl-02" = {
      proxmox_node  = "pve-node-2"
      role          = "controlplane"
      startup_order = 5
      vm_id         = 16022
      ip_address    = "192.168.160.37/27"
    },
    "k8s-dev-node-00" = {
      proxmox_node  = "pve-node-0"
      role          = "worker"
      startup_order = 6
      vm_id         = 16023
      ip_address    = "192.168.160.38/27"
    },
    "k8s-dev-node-01" = {
      proxmox_node  = "pve-node-1"
      role          = "worker"
      startup_order = 7
      vm_id         = 16024
      ip_address    = "192.168.160.39/27"
    },
    "k8s-dev-node-02" = {
      proxmox_node  = "pve-node-2"
      role          = "worker"
      startup_order = 8
      vm_id         = 16025
      ip_address    = "192.168.160.40/27"
    }
  }
}
