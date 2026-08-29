include "root" {
  path   = find_in_parent_folders("root.hcl")
  expose = true
}

include "env" {
  path   = find_in_parent_folders("env.hcl")
  expose = true
}

terraform {
  source = "${get_repo_root()}/tofu/modules/talos-cluster"
}

dependency "network" {
  config_path = "../network"

  mock_outputs_allowed_terraform_commands = ["init", "validate", "plan", "destroy"]
  mock_outputs = {
    vlan_id = 0
  }
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
    provider "proxmox" {
      endpoint = local.proxmox_provider.endpoint
      insecure = local.proxmox_provider.insecure
      username = local.proxmox_provider.username
      password = local.proxmox_provider.password
    }
  EOF
}

inputs = {
  cluster        = include.env.locals.cluster
  k8s_nodes      = include.env.locals.k8s_nodes
  vlan_id        = dependency.network.outputs.vlan_id
  ceph           = include.env.locals.ceph
  node_resources = include.env.locals.node_resources
}
