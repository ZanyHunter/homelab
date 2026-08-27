variable "network_cidr" {
  type        = string
  description = "IP Address and CIDR of Kubernetes cluster, in the format XXX.XXX.XXX.XXX/YY, where each XXX is a numerical value between 0-255 and YY is a numerical value between 0-32"

  validation {
    condition     = can(regex("^((?:25[0-5]|2[0-4]\\d|1\\d{2}|[1-9]\\d|\\d)\\.){3}(?:25[0-5]|2[0-4]\\d|1\\d{2}|[1-9]\\d|\\d)(?:\\/(?:[0-9]|[12]\\d|3[0-2]))?$", var.network_cidr))
    error_message = "Value must be of format XXX.XXX.XXX.XXX/YY, where each XXX is a numerical value between 0-255 and YY is a numerical value between 0-32"
  }
}

variable "vlan_id" {
  type        = number
  description = "VLAN ID of Kubernetes Cluster network"

  validation {
    condition     = var.vlan_id >= 0 && var.vlan_id <= 4096
    error_message = "VLAN ID must be between 0 and 4096"
  }
}

variable "k8s_nodes" {
  type = map(object({
    proxmox_node  = string
    role          = string
    startup_order = optional(number)
    vm_id         = number
    ip_address    = string
  }))

  validation {
    condition = alltrue([
      for node in var.k8s_nodes : contains(["worker", "controlplane"], node.role)
    ])
    error_message = "`role` must be either `worker` or `controlplane`"
  }
}

variable "cluster" {
  type = object({
    name            = string
    endpoint        = string
    gateway         = string
    talos_version   = string
    proxmox_cluster = string
  })
}

variable "chart_versions" {
  description = "Pinned Helm chart versions for cluster add-ons, so upgrades across dev/prod are deliberate rather than floating. Plain numbers.periods only, no leading \"v\" — cert-manager's chart version uses one upstream, so the resource that consumes it prepends the \"v\" itself, keeping this variable consistent across all five entries."
  type = object({
    metallb        = string
    ingress_nginx  = string
    cert_manager   = string
    argocd         = string
    argocd_apps    = string
    csi_driver_nfs = string
    minio          = string
    velero         = string
  })
}

variable "velero_plugin_for_aws_version" {
  description = "Pinned velero/velero-plugin-for-aws image tag — the S3-compatible object storage plugin Velero uses to talk to MinIO. Plain numbers.periods only, no leading \"v\" — same convention as ksops_version, kept as its own variable since this is a container image tag, not a Helm chart version."
  type        = string
}

variable "backup" {
  description = "Velero/MinIO cluster backup tuning — schedule, retention, and MinIO's own storage size. Environment-specific since dev/prod will want different retention and sizing; MinIO's data volume lives on the same nfs_storage-backed StorageClass as everything else."
  type = object({
    schedule           = string # cron expression for the daily Velero Schedule
    ttl                = string # Velero backup retention, a Go duration string (e.g. "720h")
    minio_bucket       = string
    minio_storage_size = string # PVC size for MinIO's NFS-backed data volume
  })
}

variable "nfs_storage" {
  description = "NFS server/share backing this cluster's default StorageClass. Each cluster (dev/prod) gets its own dedicated export — clusters do not share an NFS backend."
  type = object({
    server = string
    share  = string
  })
}

variable "gitops" {
  description = "Git repository ArgoCD's app-of-apps ApplicationSet watches under the `apps/` directory. Each cluster (dev/prod) can track a different revision of the same repo (e.g. `main` vs. a release branch) without needing a separate fork."
  type = object({
    repo_url = string
    revision = string
  })
}

variable "ksops_version" {
  description = "Pinned viaductoss/ksops image tag used to install the ksops/kustomize binaries into ArgoCD's repo-server, so it can decrypt SOPS-encrypted manifests under `apps/`. Plain numbers.periods only, no leading \"v\" — same convention as chart_versions, kept as its own variable since this is a container image tag, not a Helm chart version."
  type        = string
}

