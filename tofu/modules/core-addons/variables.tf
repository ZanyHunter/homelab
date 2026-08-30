variable "cluster_name" {
  type        = string
  description = "Cluster name (e.g. \"dev\"), used only to name the NFS StorageClass (\"nfs-<cluster_name>\") so it's identifiable across environments sharing a Proxmox host."
}

variable "chart_versions" {
  description = "Pinned Helm chart versions for the add-ons this unit manages. Plain numbers.periods only, no leading \"v\"."
  type = object({
    csi_driver_nfs   = string
    ceph_csi_rbd     = string
    metallb          = string
    ingress_nginx    = string
    cert_manager     = string
    argocd           = string
    argocd_apps      = string
    external_secrets = string
  })
}

variable "kubernetes_client_configuration" {
  description = "Raw talos-cluster connection details (same values the kubernetes/helm providers already receive via the Terragrunt-generated provider.tf), threaded in separately so null_resource.external_secrets_crds's local-exec provisioner can build its own throwaway kubeconfig — a provisioner's shell can't reach a Terraform provider's own authenticated session, so there's no way to reuse the provider's connection directly."
  type = object({
    host               = string
    client_certificate = string
    client_key         = string
    ca_certificate     = string
  })
  sensitive = true
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

variable "public_ingress_enabled" {
  description = "Whether the Cloudflare Tunnel infrastructure exists at all in this environment (#33/#39/#40) — false leaves zero public-ingress resources (no Tunnel object, no cloudflared Deployment, no DNS records), not just empty routing. Only prod is meant to be publicly exposed long-term; dev's exposure was a temporary proof of the mechanism, now torn down. The module code stays generic so prod can flip this on later with no code change."
  type        = bool
}

variable "public_apps" {
  description = "Apps exposed publicly via the Cloudflare Tunnel (#33/#39). Each entry's public hostname is <hostname><public_hostname_suffix>.<public_apex_domain> (NOT <hostname>.<domain_name> — see public_hostname_suffix), forwarded to ingress-nginx with the Host header rewritten back to <hostname>.<domain_name> so it still matches the app's existing internal Ingress/cert. Empty list (the default) means the tunnel and cloudflared exist but route nothing yet."
  type = list(object({
    hostname = string # subdomain only, e.g. "photos" -> photos<public_hostname_suffix>.<public_apex_domain>
  }))
  default = []
}

variable "public_apex_domain" {
  description = "The real external domain's bare apex (thepugh.family) — public hostnames live directly under this, not under domain_name, since Cloudflare's free Universal SSL only covers one subdomain level (*.thepugh.family) and domain_name (e.g. dev.thepugh.family) is already one level deep. Same value for every environment — it's the one real domain this repo manages in Cloudflare."
  type        = string
}

variable "public_hostname_suffix" {
  description = "Appended to each var.public_apps hostname (and \"keycloak\") before public_apex_domain, so dev and prod don't collide on the same public hostname for the same app — e.g. \"-dev\" for dev (photos-dev.thepugh.family), \"\" for prod (photos.thepugh.family, since prod's own domain_name is already the bare apex with no coverage gap to work around)."
  type        = string
}

variable "public_keycloak_realm" {
  description = "Whether to add the single allowlisted keycloak.<domain_name>, path /realms/homelab/* tunnel route (#33/#39) — never a wildcard route for the whole hostname, so /admin stays internal/VPN-only by construction. Only needed once a var.public_apps entry requires Keycloak OIDC login from outside the LAN/VPN."
  type        = bool
  default     = false
}
