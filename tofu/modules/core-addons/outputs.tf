output "nfs_storage_class_name" {
  value = kubernetes_storage_class.nfs.metadata[0].name
}

# Consumed by the keycloak-realm unit to create a matching keycloak_openid_client
# with this same secret pre-set — mirrors the keycloak-infra.admin_password ->
# keycloak-realm pattern, since core-addons applies before keycloak-realm in the
# Terragrunt DAG and a direct keycloak-realm -> core-addons dependency the other
# way around would cycle back through keycloak-infra.
output "argocd_oidc_client_secret" {
  value     = random_password.argocd_oidc_client_secret.result
  sensitive = true
}
