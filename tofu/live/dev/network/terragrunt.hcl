include "root" {
  path   = find_in_parent_folders("root.hcl")
  expose = true
}

include "env" {
  path   = find_in_parent_folders("env.hcl")
  expose = true
}

terraform {
  source = "${get_repo_root()}/tofu/modules/network"
}

generate "secrets" {
  path      = "secrets.tf"
  if_exists = "overwrite"
  contents  = include.root.locals.secrets_tf
}

generate "provider" {
  path      = "provider.tf"
  if_exists = "overwrite"
  contents  = <<-EOF
    provider "unifi" {
      api_key        = local.unifi_provider.api_key
      api_url        = local.unifi_provider.api_url
      allow_insecure = local.unifi_provider.allow_insecure
    }
  EOF
}

inputs = {
  network_cidr = include.env.locals.network_cidr
  vlan_id      = include.env.locals.vlan_id
  domain_name  = include.env.locals.domain_name
  network_name = include.env.locals.network_name
  ingress_ip   = include.env.locals.ingress_ip
}
