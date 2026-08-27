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

variable "domain_name" {
  type        = string
  description = "Local DNS domain for this cluster (e.g. k8s.thepugh.family) — set as the Unifi network's domain_name, resolved LAN-wide via a wildcard record pointed at the MetalLB ingress IP (see docs/src/bootstrap-environment/04-dns-configuration.md)."
}

variable "network_name" {
  type        = string
  description = "Display name of the Unifi network/VLAN (e.g. \"K8s-Cluster-Dev\"). Environment-specific so dev and a future prod are distinguishable in the Unifi controller UI."
}
