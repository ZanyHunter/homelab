output "vlan_id" {
  value = unifi_network.this.vlan_id
}

output "network_cidr" {
  value = unifi_network.this.subnet
}
