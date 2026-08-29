variable "cluster_name" {
  type        = string
  description = "Cluster name (e.g. \"dev\"), used only to name the NFS StorageClass (\"nfs-<cluster_name>\") so it's identifiable across environments sharing a Proxmox host."
}

variable "chart_versions" {
  description = "Pinned Helm chart versions for the add-ons this unit manages. Plain numbers.periods only, no leading \"v\"."
  type = object({
    csi_driver_nfs = string
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
