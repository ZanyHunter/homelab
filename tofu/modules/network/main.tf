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

# Every app's ingress hostname lives under this one wildcard (#10) — new
# apps under apps/<app>/ need zero DNS changes, ever, the same "just add a
# directory, push" zero-touch promise app-of-apps already gives for
# everything else. port=0 since this is a plain A record, not SRV — the
# provider schema requires *some* int value even though it's meaningless
# here.
resource "unifi_dns_record" "wildcard_ingress" {
  name        = "*.${var.domain_name}"
  record_type = "A"
  value       = var.ingress_ip
  port        = 0
}

# A wildcard never matches the zero-label case, so the bare domain_name
# itself needs its own explicit record — first needed by Matrix's apex-based
# server_name identity (#57), which requires serving
# /.well-known/matrix/client at https://<domain_name>/ rather than any
# subdomain. See docs/src/explanation/matrix.md.
resource "unifi_dns_record" "apex_ingress" {
  name        = var.domain_name
  record_type = "A"
  value       = var.ingress_ip
  port        = 0
}
