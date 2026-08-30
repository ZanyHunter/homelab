output "nfs_storage_class_name" {
  value = kubernetes_storage_class.nfs.metadata[0].name
}

# Consumed by keycloak-infra to migrate Postgres's PVC onto Ceph-backed
# storage (#28).
output "ceph_rbd_storage_class_name" {
  value = "ceph-rbd-${var.cluster_name}"
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

# Consumed by the keycloak-realm unit, which populates the 6 real Secret
# values into this namespace (#44) — created here instead, alongside ArgoCD
# itself, so it reliably exists well before ArgoCD's first sync pass of
# apps/cluster-addons/'s RBAC (which targets this same namespace) rather than
# racing keycloak-realm's own apply, the last of core-addons' 4 dependents.
output "keycloak_secrets_namespace" {
  value = kubernetes_namespace.keycloak_secrets.metadata[0].name
}
