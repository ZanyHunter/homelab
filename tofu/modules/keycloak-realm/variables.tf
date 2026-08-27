variable "chart_versions" {
  type = object({
    oauth2_proxy = string
  })
}

variable "whoami_version" {
  description = "Pinned traefik/whoami image tag for the SSO forward-auth demo — a minimal echo-server proving the oauth2-proxy + Keycloak wiring end-to-end, and the template future apps needing forward-auth (Grocy, etc.) can copy. No leading \"v\"."
  type        = string
}
