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

# Real-time calling's LiveKit SFU needs a single UDP-reachable port for
# WebRTC media (#72) — deliberately one port (LiveKit's own single-port UDP
# mux, rtc.udp_port), not the wide ephemeral range LiveKit's own "typical"
# self-hosting example uses, which would have forced hostNetwork/a new
# privileged PSA namespace this repo otherwise holds to exactly 3
# namespaces. Gated off everywhere until calling is actually ready to leave
# LAN/VPN-only testing — see var.matrix_calls_public_udp_forward. Schema
# confirmed against the actual pinned provider version's resource schema
# (flat dst_port/fwd_ip/fwd_port attributes, not the newer nested wan/forward
# blocks shown in the provider's latest docs) rather than assumed.
resource "unifi_port_forward" "matrix_calls_udp" {
  count = var.matrix_calls_public_udp_forward ? 1 : 0

  name                   = "Matrix Calls (LiveKit UDP)"
  protocol               = "udp"
  port_forward_interface = "wan"
  dst_port               = "7882"
  fwd_ip                 = var.matrix_calls_udp_ip
  fwd_port               = "7882"
}
