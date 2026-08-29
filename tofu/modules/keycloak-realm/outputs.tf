output "immich_oidc_client_secret" {
  description = "Immich's Keycloak client secret — retrieve once via `terragrunt output -raw immich_oidc_client_secret` and hand-carry it into a ksops-encrypted Secret under apps/immich/ (#33/#39). Not consumed by any other Terragrunt unit."
  value       = keycloak_openid_client.immich.client_secret
  sensitive   = true
}
