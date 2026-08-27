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
  description = "Pinned Helm chart versions for cluster add-ons, so upgrades across dev/prod are deliberate rather than floating."
  type = object({
    metallb        = string
    ingress_nginx  = string
    cert_manager   = string
    argocd         = string
    csi_driver_nfs = string
  })
}

variable "nfs_storage" {
  description = "NFS server/share backing this cluster's default StorageClass. Each cluster (dev/prod) gets its own dedicated export — clusters do not share an NFS backend."
  type = object({
    server = string
    share  = string
  })
}

