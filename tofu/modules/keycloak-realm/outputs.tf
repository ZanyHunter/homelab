output "immich_oidc_client_secret" {
  description = "Immich's Keycloak client secret. No longer needs manual action (#42) — automatically synced into Immich's own namespace via ExternalSecrets Operator, reading kubernetes_secret.immich_oidc_client_secret in the keycloak-secrets namespace this unit also manages. This output exists for break-glass/debugging only."
  value       = keycloak_openid_client.immich.client_secret
  sensitive   = true
}

output "actual_oidc_client_secret" {
  description = "Actual Budget's Keycloak client secret. No longer needs manual action (#42) — automatically synced via ExternalSecrets Operator, same mechanism as immich_oidc_client_secret above. This output exists for break-glass/debugging only."
  value       = keycloak_openid_client.actual.client_secret
  sensitive   = true
}

output "paperless_oidc_client_secret" {
  description = "Paperless-ngx's Keycloak client secret. No longer needs manual action (#42) — automatically synced via ExternalSecrets Operator, same mechanism as immich_oidc_client_secret above. This output exists for break-glass/debugging only."
  value       = keycloak_openid_client.paperless.client_secret
  sensitive   = true
}

output "vaultwarden_oidc_client_secret" {
  description = "Vaultwarden's Keycloak client secret. No longer needs manual action (#42) — automatically synced via ExternalSecrets Operator, same mechanism as immich_oidc_client_secret above. This output exists for break-glass/debugging only."
  value       = keycloak_openid_client.vaultwarden.client_secret
  sensitive   = true
}

output "homebox_oidc_client_secret" {
  description = "Homebox's Keycloak client secret. No longer needs manual action (#42) — automatically synced via ExternalSecrets Operator, same mechanism as immich_oidc_client_secret above. This output exists for break-glass/debugging only."
  value       = keycloak_openid_client.homebox.client_secret
  sensitive   = true
}

output "changedetection_oauth2_proxy_client_secret" {
  description = "changedetection.io's forward-auth oauth2-proxy Keycloak client secret. No longer needs manual action (#42) — automatically synced via ExternalSecrets Operator, same mechanism as immich_oidc_client_secret above. This output exists for break-glass/debugging only."
  value       = keycloak_openid_client.changedetection_oauth2_proxy.client_secret
  sensitive   = true
}
