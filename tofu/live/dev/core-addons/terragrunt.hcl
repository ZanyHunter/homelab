include "root" {
  path   = find_in_parent_folders("root.hcl")
  expose = true
}

include "env" {
  path   = find_in_parent_folders("env.hcl")
  expose = true
}

terraform {
  source = "${get_repo_root()}/tofu/modules/core-addons"
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

generate "secrets" {
  path      = "secrets.tf"
  if_exists = "overwrite"
  contents  = include.root.locals.secrets_tf
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
  cluster_name = include.env.locals.cluster.name
  chart_versions = {
    csi_driver_nfs = include.env.locals.chart_versions.csi_driver_nfs
    metallb        = include.env.locals.chart_versions.metallb
    ingress_nginx  = include.env.locals.chart_versions.ingress_nginx
    cert_manager   = include.env.locals.chart_versions.cert_manager
    argocd         = include.env.locals.chart_versions.argocd
    argocd_apps    = include.env.locals.chart_versions.argocd_apps
  }
  ksops_version = include.env.locals.ksops_version
  nfs_storage   = include.env.locals.nfs_storage
  gitops        = include.env.locals.gitops
}
