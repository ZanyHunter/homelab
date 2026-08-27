locals {
  # Calculate total number of usable IPs (excluding network and broadcast) —
  # kept for the commented-out DHCP sizing below, not consumed elsewhere.
  total_k8s_ips = pow(2, 32 - tonumber(split("/", var.network_cidr)[1])) - 2
}

resource "unifi_network" "this" {
  name         = var.network_name
  purpose      = "corporate"
  dhcp_enabled = false
  # dhcp_lease = 3600
  # dhcp_start = cidrhost(var.network_cidr, 2)
  # dhcp_stop = cidrhost(var.network_cidr, local.total_k8s_ips)

  domain_name = var.domain_name
  # internet_access_enabled = false
  # network_isolation_enabled = true
  subnet  = var.network_cidr
  vlan_id = var.vlan_id
}
