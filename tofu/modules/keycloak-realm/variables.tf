variable "chart_versions" {
  type = object({
    oauth2_proxy = string
  })
}

variable "whoami_version" {
  description = "Pinned traefik/whoami image tag for the SSO forward-auth demo — a minimal echo-server proving the oauth2-proxy + Keycloak wiring end-to-end, and the template future apps needing forward-auth (Grocy, etc.) can copy. No leading \"v\"."
  type        = string
}

variable "argocd_oidc_client_secret" {
  description = "ArgoCD's OIDC client secret, generated in the core-addons unit (where it's actually consumed by the argocd Helm release) and passed in here so this unit's keycloak_openid_client.argocd is created with a matching value (#32)."
  type        = string
  sensitive   = true
}

variable "grafana_oidc_client_secret" {
  description = "Grafana's OIDC client secret, generated in the observability unit (where it's actually consumed by the kube-prometheus-stack Helm release) and passed in here so this unit's keycloak_openid_client.grafana is created with a matching value (#32)."
  type        = string
  sensitive   = true
}

variable "domain_name" {
  type        = string
  description = "Domain suffix for this environment (e.g. dev.thepugh.family) — drives every hostname/redirect URI this unit manages (sso-demo, the demo user's email, and the argocd/grafana clients' valid_redirect_uris). See tofu/modules/network/variables.tf's domain_name for the full picture."
}
