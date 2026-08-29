output "immich_oidc_client_secret" {
  description = "Immich's Keycloak client secret — retrieve once via `terragrunt output -raw immich_oidc_client_secret` and hand-carry it into a ksops-encrypted Secret under apps/immich/ (#33/#39). Not consumed by any other Terragrunt unit."
  value       = keycloak_openid_client.immich.client_secret
  sensitive   = true
}

output "actual_oidc_client_secret" {
  description = "Actual Budget's Keycloak client secret — retrieve once via `terragrunt output -raw actual_oidc_client_secret` and hand-carry it into a ksops-encrypted Secret under apps/actual/."
  value       = keycloak_openid_client.actual.client_secret
  sensitive   = true
}

output "paperless_oidc_client_secret" {
  description = "Paperless-ngx's Keycloak client secret — retrieve once via `terragrunt output -raw paperless_oidc_client_secret` and hand-carry it into a ksops-encrypted Secret under apps/paperless/."
  value       = keycloak_openid_client.paperless.client_secret
  sensitive   = true
}

output "vaultwarden_oidc_client_secret" {
  description = "Vaultwarden's Keycloak client secret — retrieve once via `terragrunt output -raw vaultwarden_oidc_client_secret` and hand-carry it into a ksops-encrypted Secret under apps/vaultwarden/."
  value       = keycloak_openid_client.vaultwarden.client_secret
  sensitive   = true
}

output "homebox_oidc_client_secret" {
  description = "Homebox's Keycloak client secret — retrieve once via `terragrunt output -raw homebox_oidc_client_secret` and hand-carry it into a ksops-encrypted Secret under apps/inventory/."
  value       = keycloak_openid_client.homebox.client_secret
  sensitive   = true
}

output "changedetection_oauth2_proxy_client_secret" {
  description = "changedetection.io's forward-auth oauth2-proxy Keycloak client secret — retrieve once via `terragrunt output -raw changedetection_oauth2_proxy_client_secret` and hand-carry it into a ksops-encrypted Secret under apps/changedetection/."
  value       = keycloak_openid_client.changedetection_oauth2_proxy.client_secret
  sensitive   = true
}
