# Consumed by the keycloak-realm unit to create a matching keycloak_openid_client
# with this same secret pre-set — mirrors the keycloak-infra.admin_password ->
# keycloak-realm pattern (see docs/src/bootstrap-environment/08-sso.md). This
# is what makes observability a new upstream dependency of keycloak-realm.
output "grafana_oidc_client_secret" {
  value     = random_password.grafana_oidc_client_secret.result
  sensitive = true
}
