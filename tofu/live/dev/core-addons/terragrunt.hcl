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

    provider "cloudflare" {
      api_token = local.cloudflare_api_token
    }
  EOF
}

inputs = {
  cluster_name = include.env.locals.cluster.name
  chart_versions = {
    csi_driver_nfs   = include.env.locals.chart_versions.csi_driver_nfs
    ceph_csi_rbd     = include.env.locals.chart_versions.ceph_csi_rbd
    metallb          = include.env.locals.chart_versions.metallb
    ingress_nginx    = include.env.locals.chart_versions.ingress_nginx
    cert_manager     = include.env.locals.chart_versions.cert_manager
    argocd           = include.env.locals.chart_versions.argocd
    argocd_apps      = include.env.locals.chart_versions.argocd_apps
    external_secrets = include.env.locals.chart_versions.external_secrets
  }
  ksops_version = include.env.locals.ksops_version
  nfs_storage   = include.env.locals.nfs_storage
  gitops        = include.env.locals.gitops
  ceph          = include.env.locals.ceph
  # Same name as the pool (client.<pool_name>) — see the CephX bootstrap
  # command in docs/src/guides/deploy-from-scratch.md.
  ceph_rbd_client_id = include.env.locals.ceph.pool_name
  domain_name        = include.env.locals.domain_name
  ingress_ip         = include.env.locals.ingress_ip
  network_cidr       = include.env.locals.network_cidr

  # Same connection details the kubernetes/helm providers above already
  # receive, threaded in separately for null_resource.external_secrets_crds'
  # local-exec provisioner (#44) — a provisioner's shell can't reach a
  # Terraform provider's own authenticated session.
  kubernetes_client_configuration = dependency.talos_cluster.outputs.kubernetes_client_configuration

  cloudflare_account_id  = include.env.locals.cloudflare_account_id
  cloudflare_zone_id     = include.env.locals.cloudflare_zone_id
  cloudflared_version    = include.env.locals.cloudflared_version
  public_ingress_enabled = include.env.locals.public_ingress_enabled
  public_apps            = include.env.locals.public_apps
  public_keycloak_realm  = include.env.locals.public_keycloak_realm
  public_apex_domain     = include.env.locals.public_apex_domain
  public_hostname_suffix = include.env.locals.public_hostname_suffix
}
