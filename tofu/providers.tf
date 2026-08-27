provider "proxmox" {
  endpoint = local.proxmox_provider.endpoint
  insecure = local.proxmox_provider.insecure

  username = local.proxmox_provider.username
  password = local.proxmox_provider.password
}

provider "unifi" {
  api_key        = local.unifi_provider.api_key
  api_url        = local.unifi_provider.api_url
  allow_insecure = local.unifi_provider.allow_insecure
}

provider "kubernetes" {
  host                   = talos_cluster_kubeconfig.this.kubernetes_client_configuration.host
  client_certificate     = base64decode(talos_cluster_kubeconfig.this.kubernetes_client_configuration.client_certificate)
  client_key             = base64decode(talos_cluster_kubeconfig.this.kubernetes_client_configuration.client_key)
  cluster_ca_certificate = base64decode(talos_cluster_kubeconfig.this.kubernetes_client_configuration.ca_certificate)
}

provider "helm" {
  kubernetes {
    host                   = talos_cluster_kubeconfig.this.kubernetes_client_configuration.host
    client_certificate     = base64decode(talos_cluster_kubeconfig.this.kubernetes_client_configuration.client_certificate)
    client_key             = base64decode(talos_cluster_kubeconfig.this.kubernetes_client_configuration.client_key)
    cluster_ca_certificate = base64decode(talos_cluster_kubeconfig.this.kubernetes_client_configuration.ca_certificate)
  }
}

# Password grant against the built-in admin-cli client, using the same
# bootstrap admin credentials Keycloak itself is given (tofu/sso.tf) — avoids
# a chicken-and-egg problem of needing a dedicated service-account client
# before Tofu can manage anything. Every keycloak_* resource still needs its
# own depends_on on Keycloak actually being up (see tofu/sso.tf) since this
# provider block has no direct reference forcing that ordering.
provider "keycloak" {
  client_id = "admin-cli"
  username  = "admin"
  password  = random_password.keycloak_admin_password.result
  url       = "https://keycloak.k8s.thepugh.family"
}

