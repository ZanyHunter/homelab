include "root" {
  path   = find_in_parent_folders("root.hcl")
  expose = true
}

include "env" {
  path   = find_in_parent_folders("env.hcl")
  expose = true
}

terraform {
  source = "${get_repo_root()}/tofu/modules/keycloak-realm"
}

dependency "talos_cluster" {
  config_path = "../talos-cluster"

  mock_outputs_allowed_terraform_commands = ["init", "validate", "plan"]
  mock_outputs = {
    kubernetes_client_configuration = {
      host                   = "https://mock:6443"
      client_certificate     = "bW9jaw=="
      client_key             = "bW9jaw=="
      ca_certificate         = "bW9jaw=="
    }
  }
}

# Deliberately NOT allowing "apply" in mock_outputs_allowed_terraform_commands
# — this is the fix for the old `-target=time_sleep.wait_for_keycloak`
# two-phase bootstrap. A `run --all apply` blocks until keycloak-infra has
# genuinely applied and produced a real, known admin_password before this
# unit's `keycloak` provider block gets generated with it.
dependency "keycloak_infra" {
  config_path = "../keycloak-infra"

  mock_outputs_allowed_terraform_commands = ["init", "validate", "plan"]
  mock_outputs = {
    admin_password = "mock-password-not-used-at-apply"
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

    # Password grant against the built-in admin-cli client, using the same
    # bootstrap admin credentials Keycloak itself is given
    # (modules/keycloak-infra) — avoids a chicken-and-egg problem of needing
    # a dedicated service-account client before Tofu can manage anything.
    provider "keycloak" {
      client_id = "admin-cli"
      username  = "admin"
      password  = "${dependency.keycloak_infra.outputs.admin_password}"
      url       = "https://keycloak.k8s.thepugh.family"
    }
  EOF
}

inputs = {
  chart_versions = {
    oauth2_proxy = include.env.locals.chart_versions.oauth2_proxy
  }
  whoami_version = include.env.locals.whoami_version
}
