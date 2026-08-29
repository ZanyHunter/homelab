variable "cluster_name" {
  type        = string
  description = "Cluster name (e.g. \"dev\"), used only to name the NFS StorageClass (\"nfs-<cluster_name>\") so it's identifiable across environments sharing a Proxmox host."
}

variable "chart_versions" {
  description = "Pinned Helm chart versions for the add-ons this unit manages. Plain numbers.periods only, no leading \"v\"."
  type = object({
    csi_driver_nfs = string
    ceph_csi_rbd   = string
    metallb        = string
    ingress_nginx  = string
    cert_manager   = string
    argocd         = string
    argocd_apps    = string
  })
}

variable "ksops_version" {
  description = "Pinned viaductoss/ksops image tag used to install the ksops/kustomize binaries into ArgoCD's repo-server, so it can decrypt SOPS-encrypted manifests under apps/. Plain numbers.periods only, no leading \"v\"."
  type        = string
}

variable "nfs_storage" {
  description = "NFS server/share backing this cluster's default StorageClass."
  type = object({
    server = string
    share  = string
  })
}

variable "gitops" {
  description = "Git repository ArgoCD's app-of-apps ApplicationSet watches under the apps/ directory."
  type = object({
    repo_url = string
    revision = string
  })
}

variable "domain_name" {
  type        = string
  description = "Domain suffix for this environment (e.g. dev.thepugh.family) — drives ArgoCD's ingress hostname and OIDC issuer/redirect URL. See tofu/modules/network/variables.tf's domain_name for the full picture."
}

variable "ingress_ip" {
  type        = string
  description = "Static IP ingress-nginx's LoadBalancer Service is pinned to (metallb.universe.tf/loadBalancerIPs), matching the network unit's wildcard DNS record target exactly. See tofu/modules/network/variables.tf's ingress_ip for why this is static rather than MetalLB-assigned."
}

variable "ceph" {
  description = "Config for ceph-csi's connection to the existing external Ceph cluster (#28) — pool_name comes from the talos-cluster unit's output (the pool it actually created), cluster_id/monitors are static env.hcl facts about the shared physical cluster. See tofu/modules/talos-cluster/variables.tf's ceph variable for the full picture."
  type = object({
    pool_name  = string
    cluster_id = string
    monitors   = list(string)
  })
}

variable "ceph_rbd_client_id" {
  description = "CephX client name (without the \"client.\" prefix) ceph-csi authenticates as — manually created, scoped to only var.ceph.pool_name. See docs/src/bootstrap-environment for the bootstrap command."
  type        = string
}

variable "cloudflare_account_id" {
  description = "Cloudflare account ID (visible on the dashboard) — not a secret in Cloudflare's own model, just an identifier, so it lives in env.hcl rather than secrets.enc.yaml. Needed to create the Tunnel object (#33/#39)."
  type        = string
}

variable "cloudflare_zone_id" {
  description = "Zone ID for the real external domain (thepugh.family) this environment's public hostnames live under — same zone cert-manager's DNS-01 already writes TXT records to. Also not a secret, same reasoning as cloudflare_account_id."
  type        = string
}

variable "cloudflared_version" {
  description = "Pinned cloudflare/cloudflared image tag. Plain version, no leading \"v\" — matches the chart_versions convention even though this isn't a Helm chart (Cloudflare doesn't publish one)."
  type        = string
}

variable "public_apps" {
  description = "Apps exposed publicly via the Cloudflare Tunnel (#33/#39). Each entry becomes a full-hostname allowlist route (<hostname>.<domain_name>) forwarded to ingress-nginx, plus a matching public DNS record. Empty list (the default) means the tunnel and cloudflared exist but route nothing yet."
  type = list(object({
    hostname = string # subdomain only, e.g. "photos" -> photos.<domain_name>
  }))
  default = []
}

variable "public_keycloak_realm" {
  description = "Whether to add the single allowlisted keycloak.<domain_name>, path /realms/homelab/* tunnel route (#33/#39) — never a wildcard route for the whole hostname, so /admin stays internal/VPN-only by construction. Only needed once a var.public_apps entry requires Keycloak OIDC login from outside the LAN/VPN."
  type        = bool
  default     = false
}
