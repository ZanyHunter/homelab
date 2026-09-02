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
  description = "Domain suffix for this environment (e.g. dev.thepugh.family) — drives every ingress hostname/OIDC redirect URI across every unit, and is set as the Unifi network's own domain_name here. Resolved LAN-wide via a Tofu-managed wildcard DNS record (unifi_dns_record.wildcard_ingress, this unit) pointed at var.ingress_ip. See docs/src/explanation/dns-and-hostnames.md."
}

variable "ingress_ip" {
  type        = string
  description = "Static IP the wildcard DNS record points at — also what core-addons pins ingress-nginx's LoadBalancer Service to (metallb.universe.tf/loadBalancerIPs), rather than letting MetalLB assign it dynamically. Kept static (an env.hcl literal both units read directly) specifically so this unit doesn't need a Tofu dependency on core-addons, which applies after it in the DAG."
}

variable "network_name" {
  type        = string
  description = "Display name of the Unifi network/VLAN (e.g. \"K8s-Cluster-Dev\"). Environment-specific so dev and a future prod are distinguishable in the Unifi controller UI."
}

variable "matrix_calls_udp_ip" {
  type        = string
  description = "Static MetalLB IP (from this environment's own lb-pool-range, apps/cluster-addons/overlays/<env>/env-values.yaml) that LiveKit's UDP mux Service pins itself to (#72) — kept static and passed in directly, same reasoning as var.ingress_ip, so this unit's port-forward resource doesn't need a Tofu dependency on core-addons/the app itself, which apply after it in the DAG."
}

variable "matrix_calls_public_udp_forward" {
  description = "Whether to create the unifi_port_forward routing WAN UDP 7882 to var.matrix_calls_udp_ip (#72) — false everywhere until real-time calling is actually ready to go beyond LAN/VPN testing, and even then only ever meaningful for prod (the one environment meant to be publicly exposed long-term), same as public_matrix_wellknown in core-addons."
  type        = bool
  default     = false
}
