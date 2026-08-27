# Consumed by the keycloak-realm unit to build its `keycloak` provider block.
# Terragrunt's dependency ordering waits for this entire unit's apply — time_sleep.wait_for_keycloak
# included — to finish before keycloak-realm starts, regardless of which
# specific resource this value happens to reference; that's what replaces
# the old `-target=time_sleep.wait_for_keycloak` two-phase bootstrap.
output "admin_password" {
  value     = random_password.keycloak_admin_password.result
  sensitive = true
}
