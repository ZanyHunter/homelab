include "root" {
  path   = find_in_parent_folders("root.hcl")
  expose = true
}

include "env" {
  path   = find_in_parent_folders("env.hcl")
  expose = true
}

terraform {
  source = "${get_repo_root()}/tofu/modules/keycloak-infra"
}

dependency "talos_cluster" {
  config_path = "../talos-cluster"

  mock_outputs_allowed_terraform_commands = ["init", "validate", "plan", "destroy"]
  mock_outputs = {
    kubernetes_client_configuration = {
      host               = "https://mock:6443"
      client_certificate = "bW9jaw=="
      client_key         = "bW9jaw=="
      ca_certificate     = "bW9jaw=="
    }
  }
}

dependency "core_addons" {
  config_path = "../core-addons"

  mock_outputs_allowed_terraform_commands = ["init", "validate", "plan", "destroy"]
  mock_outputs = {
    nfs_storage_class_name = "mock-nfs"
  }
}

generate "provider" {
  path      = "provider.tf"
  if_exists = "overwrite"
  contents  = <<-EOF
    provider "kubernetes" {
      host                   = "${dependency.talos_cluster.outputs.kubernetes_client_configuration.host}"
      client_certificate     = base64decode("${dependency.talos_cluster.outputs.kubernetes_client_configuration.client_certificate}")
      client_key             = base64decode("${dependency.talos_cluster.outputs.kubernetes_client_configuration.client_key}")
      cluster_ca_certificate = base64decode("${dependency.talos_cluster.outputs.kubernetes_client_configuration.ca_certificate}")
    }

    provider "helm" {
      kubernetes {
        host                   = "${dependency.talos_cluster.outputs.kubernetes_client_configuration.host}"
        client_certificate     = base64decode("${dependency.talos_cluster.outputs.kubernetes_client_configuration.client_certificate}")
        client_key             = base64decode("${dependency.talos_cluster.outputs.kubernetes_client_configuration.client_key}")
        cluster_ca_certificate = base64decode("${dependency.talos_cluster.outputs.kubernetes_client_configuration.ca_certificate}")
      }
    }
  EOF
}

inputs = {
  postgres_version = include.env.locals.postgres_version
  chart_versions = {
    keycloak = include.env.locals.chart_versions.keycloak
  }
  nfs_storage_class_name = dependency.core_addons.outputs.nfs_storage_class_name
  domain_name            = include.env.locals.domain_name
}
