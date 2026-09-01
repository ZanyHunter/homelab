# --- Realm + a demo OIDC client, managed via the keycloak provider (same
# "provider talks to the app's own API declaratively" pattern already used
# for unifi_network.this) -----------------------------------------------------
# No explicit dependency on Keycloak having finished starting: Terragrunt's
# unit-level dependency ordering already guarantees the keycloak-infra unit
# (including its time_sleep.wait_for_keycloak) is fully applied before this
# unit starts — see modules/keycloak-infra/outputs.tf.
resource "keycloak_realm" "homelab" {
  realm        = "homelab"
  enabled      = true
  display_name = "Homelab"
}

# A real per-app client secret should be ksops-encrypted under that app's
# apps/<app>/ directory once a real app lands (see
# docs/src/explanation/gitops-app-of-apps.md) — this demo client is Tofu-managed end-to-end
# instead, since oauth2-proxy here exists purely to prove the Keycloak wiring
# works, not as a real app.
resource "random_password" "oauth2_proxy_client_secret" {
  length  = 32
  special = false
}

resource "keycloak_openid_client" "oauth2_proxy" {
  realm_id  = keycloak_realm.homelab.id
  client_id = "oauth2-proxy"
  name      = "oauth2-proxy (forward-auth demo)"
  enabled   = true

  access_type           = "CONFIDENTIAL"
  standard_flow_enabled = true
  client_secret         = random_password.oauth2_proxy_client_secret.result

  valid_redirect_uris = ["https://sso-demo.${var.domain_name}/oauth2/callback"]
  web_origins         = ["+"]
}

# A real test user so the forward-auth flow can actually be logged into, not
# just have a client that exists.
resource "random_password" "demo_user_password" {
  length  = 20
  special = false
}

resource "keycloak_user" "demo" {
  realm_id = keycloak_realm.homelab.id
  username = "demo"
  enabled  = true

  email          = "demo@${var.domain_name}"
  email_verified = true
  first_name     = "Demo"
  last_name      = "User"

  initial_password {
    value     = random_password.demo_user_password.result
    temporary = false
  }
}

# --- SSO for management apps (ArgoCD, Grafana) — #32 -------------------------
# Access control is group-based, not tied to any specific person's identity:
# nothing below names a real user. Real accounts and their membership in
# platform-admins are created/managed by hand in Keycloak's admin console
# after the fact (https://keycloak.<domain_name>) — see
# docs/src/explanation/sso-and-keycloak.md.
resource "keycloak_group" "platform_admins" {
  realm_id = keycloak_realm.homelab.id
  name     = "platform-admins"
}

# Keycloak doesn't include group membership in a token by default — this is
# a reusable client scope (rather than a per-client mapper) so any future
# app needing group-based RBAC can attach it the same way.
resource "keycloak_openid_client_scope" "groups" {
  realm_id = keycloak_realm.homelab.id
  name     = "groups"
}

resource "keycloak_openid_group_membership_protocol_mapper" "groups" {
  realm_id        = keycloak_realm.homelab.id
  client_scope_id = keycloak_openid_client_scope.groups.id
  name            = "group-membership"
  claim_name      = "groups"
  # Just the group name (e.g. "platform-admins"), not the full "/platform-admins"
  # path, so RBAC rules in ArgoCD/Grafana can match on a plain string.
  full_path = false
}

resource "keycloak_openid_client" "argocd" {
  realm_id  = keycloak_realm.homelab.id
  client_id = "argocd"
  name      = "ArgoCD"
  enabled   = true

  access_type           = "CONFIDENTIAL"
  standard_flow_enabled = true
  client_secret         = var.argocd_oidc_client_secret

  valid_redirect_uris = ["https://argocd.${var.domain_name}/auth/callback"]
  web_origins         = ["+"]
}

# keycloak_openid_client_optional_scopes is authoritative over the whole
# optional-scopes list, not additive — the first 4 entries are Keycloak's own
# built-in optional scopes (present on every client by default), repeated
# here only because adding "groups" means fully replacing the list.
resource "keycloak_openid_client_optional_scopes" "argocd" {
  realm_id  = keycloak_realm.homelab.id
  client_id = keycloak_openid_client.argocd.id

  optional_scopes = [
    "address",
    "phone",
    "offline_access",
    "microprofile-jwt",
    keycloak_openid_client_scope.groups.name,
  ]
}

resource "keycloak_openid_client" "grafana" {
  realm_id  = keycloak_realm.homelab.id
  client_id = "grafana"
  name      = "Grafana"
  enabled   = true

  access_type           = "CONFIDENTIAL"
  standard_flow_enabled = true
  client_secret         = var.grafana_oidc_client_secret

  valid_redirect_uris = ["https://grafana.${var.domain_name}/login/generic_oauth"]
  web_origins         = ["+"]
}

resource "keycloak_openid_client_optional_scopes" "grafana" {
  realm_id  = keycloak_realm.homelab.id
  client_id = keycloak_openid_client.grafana.id

  optional_scopes = [
    "address",
    "phone",
    "offline_access",
    "microprofile-jwt",
    keycloak_openid_client_scope.groups.name,
  ]
}

# --- Immich (#33/#39): first real app under apps/, native OIDC support ------
# Client secret is Tofu-generated here (like the oauth2-proxy demo client)
# rather than passed in from another unit — Immich's own config lives in
# apps/immich/ under ArgoCD's GitOps management, not in any Terragrunt
# unit's Helm values, so there's no cross-unit dependency to wire. The value
# reaches the running Immich automatically via ExternalSecrets Operator (#42)
# rather than a manual hand-carry step — see
# docs/src/explanation/sso-and-keycloak.md's guidance on real apps' client secrets, and
# docs/src/explanation/immich.md for the full picture.
resource "random_password" "immich_client_secret" {
  length  = 32
  special = false
}

resource "keycloak_openid_client" "immich" {
  realm_id  = keycloak_realm.homelab.id
  client_id = "immich"
  name      = "Immich"
  enabled   = true

  access_type           = "CONFIDENTIAL"
  standard_flow_enabled = true
  client_secret         = random_password.immich_client_secret.result

  valid_redirect_uris = [
    "app.immich:///oauth-callback",
    "https://photos.${var.domain_name}/auth/login",
    "https://photos.${var.domain_name}/user-settings",
  ]
  web_origins = ["+"]
}

# platform-admins -> Immich's own admin role, via oauth.roleClaim (defaults
# to "immich_role" in Immich itself, set explicitly below for clarity). A
# *client* role on Immich's own client, not a realm role: the deployed
# Immich version (v3.0.0) reads this claim with `typeof value === 'string'`
# (see server/src/services/auth.service.ts@v3.0.0's getClaim helper) — an
# *array* value (what a realm-role mapper produces, since every user also
# carries Keycloak's own default-roles-<realm>/offline_access/
# uma_authorization realm roles alongside "admin") fails that check and
# silently falls back to "user", found live as a real "logged in via
# Keycloak but landed as a normal user" bug. Scoping the mapper to just this
# one client's roles (client_id_for_role_mappings) with multivalued = false
# is what actually gets a bare "admin" string with nothing else competing
# for the single value — realm roles have no equivalent per-client scoping.
#
# Note this is evaluated only at account creation in v3.0.0, not on every
# login (a newer, not-yet-released Immich version does re-evaluate on every
# login — worth revisiting when that ships). A role change here won't
# retroactively fix an already-created Immich user; see
# docs/src/explanation/immich.md.
resource "keycloak_role" "immich_admin" {
  realm_id    = keycloak_realm.homelab.id
  client_id   = keycloak_openid_client.immich.id
  name        = "admin"
  description = "Grants Immich's own admin role via oauth.roleClaim — the literal claim value Immich's auth code checks for."
}

resource "keycloak_group_roles" "platform_admins_immich_admin" {
  realm_id   = keycloak_realm.homelab.id
  group_id   = keycloak_group.platform_admins.id
  role_ids   = [keycloak_role.immich_admin.id]
  exhaustive = true
}

resource "keycloak_openid_user_client_role_protocol_mapper" "immich_role" {
  realm_id  = keycloak_realm.homelab.id
  client_id = keycloak_openid_client.immich.id
  name      = "immich-role"

  claim_name = "immich_role"
  # The underlying Keycloak config key (usermodel.clientRoleMapping.clientId)
  # actually wants the client's human-readable client_id string ("immich"),
  # not its internal UUID (keycloak_openid_client.immich.id) despite this
  # Terraform field's name — found live: passing the UUID here silently
  # produced a mapper that never matched anything, so the claim was simply
  # absent from the token rather than erroring.
  client_id_for_role_mappings = keycloak_openid_client.immich.client_id
  multivalued                 = false
}

# --- Five more real apps under apps/, same "generated here, hand-carried
# into a ksops-encrypted Secret under that app's own apps/<app>/ directory"
# shape as Immich above. See docs/src/explanation/self-hosted-apps.md.

resource "random_password" "actual_client_secret" {
  length  = 32
  special = false
}

# Actual Budget's OIDC support (ACTUAL_OPENID_* env vars) computes its own
# callback from ACTUAL_OPENID_SERVER_HOSTNAME — no separate role/admin
# concept to wire (the server has one shared login, not per-user roles).
resource "keycloak_openid_client" "actual" {
  realm_id  = keycloak_realm.homelab.id
  client_id = "actual"
  name      = "Actual Budget"
  enabled   = true

  access_type           = "CONFIDENTIAL"
  standard_flow_enabled = true
  client_secret         = random_password.actual_client_secret.result

  valid_redirect_uris = ["https://actual.${var.domain_name}/openid/callback"]
  web_origins         = ["+"]
}

resource "random_password" "paperless_client_secret" {
  length  = 32
  special = false
}

# provider_id "keycloak" (set in PAPERLESS_SOCIALACCOUNT_PROVIDERS's APPS
# list, apps/paperless/paperless-config.enc.yaml) drives django-allauth's
# generic openid_connect callback path — confirmed against
# allauth/socialaccount/providers/openid_connect/urls.py, not guessed: it's
# /accounts/oidc/<provider_id>/login/callback/, keyed off provider_id, not
# the provider's static "openid_connect" id.
resource "keycloak_openid_client" "paperless" {
  realm_id  = keycloak_realm.homelab.id
  client_id = "paperless"
  name      = "Paperless-ngx"
  enabled   = true

  access_type           = "CONFIDENTIAL"
  standard_flow_enabled = true
  client_secret         = random_password.paperless_client_secret.result

  valid_redirect_uris = ["https://paperless.${var.domain_name}/accounts/oidc/keycloak/login/callback/"]
  web_origins         = ["+"]
}

# platform-admins -> Django superuser, via paperless-ngx's own
# PAPERLESS_SOCIALACCOUNT_SYNC_GROUPS_SYNC_SUPERUSER_GROUP, which matches
# against the same reusable "groups" claim (plain group name, e.g.
# "platform-admins") already used for ArgoCD/Grafana's RBAC below — no
# client-role gymnastics needed here the way Immich's oauth.roleClaim
# required, since paperless-ngx matches on group *name* directly rather than
# needing a single-valued custom claim.
resource "keycloak_openid_client_optional_scopes" "paperless" {
  realm_id  = keycloak_realm.homelab.id
  client_id = keycloak_openid_client.paperless.id

  optional_scopes = [
    "address",
    "phone",
    "offline_access",
    "microprofile-jwt",
    keycloak_openid_client_scope.groups.name,
  ]
}

resource "random_password" "vaultwarden_client_secret" {
  length  = 32
  special = false
}

# Vaultwarden's SSO only gates account login, not vault decryption (still a
# separate client-side master password regardless) — no group/role wiring
# needed. Its own /admin panel is gated by a static ADMIN_TOKEN instead,
# generated directly into apps/vaultwarden/vaultwarden-config.enc.yaml, not
# a Keycloak concept.
resource "keycloak_openid_client" "vaultwarden" {
  realm_id  = keycloak_realm.homelab.id
  client_id = "vaultwarden"
  name      = "Vaultwarden"
  enabled   = true

  access_type           = "CONFIDENTIAL"
  standard_flow_enabled = true
  client_secret         = random_password.vaultwarden_client_secret.result

  valid_redirect_uris = ["https://vaultwarden.${var.domain_name}/identity/connect/oidc-signin"]
  web_origins         = ["+"]
}

resource "random_password" "homebox_client_secret" {
  length  = 32
  special = false
}

# Homebox's admin/ownership model is per-household (the first user of a
# household becomes its owner), not a single app-wide admin role — nothing
# analogous to Immich's platform-admins->admin mapping to wire here.
resource "keycloak_openid_client" "homebox" {
  realm_id  = keycloak_realm.homelab.id
  client_id = "homebox"
  name      = "Homebox"
  enabled   = true

  access_type           = "CONFIDENTIAL"
  standard_flow_enabled = true
  client_secret         = random_password.homebox_client_secret.result

  valid_redirect_uris = ["https://inventory.${var.domain_name}/api/v1/users/login/oidc/callback"]
  web_origins         = ["+"]
}

resource "random_password" "homepage_client_secret" {
  length  = 32
  special = false
}

# Homepage (#59) has native OIDC support (HOMEPAGE_OIDC_* env vars) but,
# per its own docs, applies no claim-based authorization at all — it grants
# access to any identity the IdP authorizes for this client. Same as every
# other app here: a real Keycloak account is already this homelab's access
# gate, so no group/role wiring is needed (nothing analogous to Immich's or
# Paperless-ngx's platform-admins mapping).
resource "keycloak_openid_client" "homepage" {
  realm_id  = keycloak_realm.homelab.id
  client_id = "homepage"
  name      = "Homepage"
  enabled   = true

  access_type           = "CONFIDENTIAL"
  standard_flow_enabled = true
  client_secret         = random_password.homepage_client_secret.result

  valid_redirect_uris = ["https://homepage.${var.domain_name}/api/auth/callback/homepage-oidc"]
  web_origins         = ["+"]
}

# changedetection.io has no native OIDC support (confirmed: only a single
# shared password, no IdP integration) — this client is oauth2-proxy acting
# as forward-auth in front of it, the same copy-paste shape as the sso-demo
# client below, just for a real app instead of the demo/whoami target.
resource "random_password" "changedetection_oauth2_proxy_client_secret" {
  length  = 32
  special = false
}

resource "keycloak_openid_client" "changedetection_oauth2_proxy" {
  realm_id  = keycloak_realm.homelab.id
  client_id = "changedetection-oauth2-proxy"
  name      = "oauth2-proxy (changedetection.io forward-auth)"
  enabled   = true

  access_type           = "CONFIDENTIAL"
  standard_flow_enabled = true
  client_secret         = random_password.changedetection_oauth2_proxy_client_secret.result

  valid_redirect_uris = ["https://changedetection.${var.domain_name}/oauth2/callback"]
  web_origins         = ["+"]
}

# Pinchflat (#54) has no OIDC support of its own — originally deployed
# gated by its own static basic auth instead (the RSS-feed-needs-to-stay-
# unauthenticated concern that usually rules out oauth2-proxy didn't
# actually apply, since EXPOSE_FEED_ENDPOINTS was left off and RSS wasn't
# needed) — moved to this repo's standard oauth2-proxy forward-auth
# pattern instead, for the same reason changedetection.io above uses it:
# consistency with every other app's Keycloak login, avoiding a second
# credential set to remember.
resource "random_password" "pinchflat_oauth2_proxy_client_secret" {
  length  = 32
  special = false
}

resource "keycloak_openid_client" "pinchflat_oauth2_proxy" {
  realm_id  = keycloak_realm.homelab.id
  client_id = "pinchflat-oauth2-proxy"
  name      = "oauth2-proxy (Pinchflat forward-auth)"
  enabled   = true

  access_type           = "CONFIDENTIAL"
  standard_flow_enabled = true
  client_secret         = random_password.pinchflat_oauth2_proxy_client_secret.result

  valid_redirect_uris = ["https://youtube.${var.domain_name}/oauth2/callback"]
  web_origins         = ["+"]
}

resource "random_password" "vikunja_client_secret" {
  length  = 32
  special = false
}

# Vikunja's own frontend (the combined vikunja/vikunja image serves both)
# redirects back to /auth/openid/<provider key> after authentication — the
# provider key ("keycloak") is freely chosen in
# apps/vikunja/base/vikunja.yaml's VIKUNJA_AUTH_OPENID_PROVIDERS_KEYCLOAK_*
# env vars and must match here. No group/role wiring, same reasoning as
# Homebox: Vikunja has no single app-wide admin concept to map
# platform-admins onto.
resource "keycloak_openid_client" "vikunja" {
  realm_id  = keycloak_realm.homelab.id
  client_id = "vikunja"
  name      = "Vikunja"
  enabled   = true

  access_type           = "CONFIDENTIAL"
  standard_flow_enabled = true
  client_secret         = random_password.vikunja_client_secret.result

  valid_redirect_uris = ["https://projects.${var.domain_name}/auth/openid/keycloak"]
  web_origins         = ["+"]
}

resource "random_password" "mealie_client_secret" {
  length  = 32
  special = false
}

# Mealie's redirect URIs per its v2 OIDC docs: /login (standard) and
# /login?direct=1 (RP-Initiated Logout, which Keycloak supports) — a
# wildcard on /login* covers both with one entry.
#
# platform-admins -> Mealie admin, via OIDC_ADMIN_GROUP
# (apps/mealie/base/mealie.yaml) matching against the same reusable "groups"
# claim already used for ArgoCD/Grafana/Paperless-ngx above — same
# plain-group-name-matching pattern as Paperless, no client-role gymnastics.
# OIDC_USER_GROUP is deliberately left unset: unlike OIDC_ADMIN_GROUP, it
# actually *restricts* login to that group, which would break this repo's
# established "any Keycloak-authorized identity gets in" access model.
resource "keycloak_openid_client" "mealie" {
  realm_id  = keycloak_realm.homelab.id
  client_id = "mealie"
  name      = "Mealie"
  enabled   = true

  access_type           = "CONFIDENTIAL"
  standard_flow_enabled = true
  client_secret         = random_password.mealie_client_secret.result

  valid_redirect_uris = ["https://recipes.${var.domain_name}/login*"]
  web_origins         = ["+"]
}

resource "keycloak_openid_client_optional_scopes" "mealie" {
  realm_id  = keycloak_realm.homelab.id
  client_id = keycloak_openid_client.mealie.id

  optional_scopes = [
    "address",
    "phone",
    "offline_access",
    "microprofile-jwt",
    keycloak_openid_client_scope.groups.name,
  ]
}

resource "random_password" "lubelogger_client_secret" {
  length  = 32
  special = false
}

# LubeLogger's OpenIDConfig__RedirectURL is a single fixed path
# (Controllers/LoginController.cs's RemoteAuth action) — no wildcard needed,
# unlike Mealie's. No group/role wiring: LubeLogger has no group-claim
# support at all (confirmed against its source), so no client-scope mapper
# and no optional_scopes resource here, unlike Mealie/Paperless-ngx above —
# same "no single app-wide admin concept" reasoning as Homebox/Vikunja.
resource "keycloak_openid_client" "lubelogger" {
  realm_id  = keycloak_realm.homelab.id
  client_id = "lubelogger"
  name      = "LubeLogger"
  enabled   = true

  access_type           = "CONFIDENTIAL"
  standard_flow_enabled = true
  client_secret         = random_password.lubelogger_client_secret.result

  valid_redirect_uris = ["https://lubelogger.${var.domain_name}/Login/RemoteAuth"]
  web_origins         = ["+"]
}

resource "random_password" "matrix_client_secret" {
  length  = 32
  special = false
}

# Synapse's OIDC callback is a single fixed path (Synapse's own
# /_synapse/client/oidc/callback, registered per-provider) — no wildcard
# needed, same reasoning as LubeLogger's single-path client above. Note this
# client's redirect_uri is the *subdomain* Synapse itself actually runs on
# (apps/matrix/), which is deliberately different from this realm's
# server_name identity Matrix presents to the outside world
# (apex-based — see docs/src/explanation/matrix.md) — the two are unrelated:
# server_name is Matrix's own user-ID namespace, valid_redirect_uris is
# purely "where does Keycloak send the browser back to."
#
# groups optional scope attached for consistency with every other app's
# client here, though Synapse itself has no built-in way to map a "groups"
# claim onto its own server-admin flag the way Jellyfin's plugin/Mealie's
# OIDC_ADMIN_GROUP do — granting Matrix server-admin, if ever needed, is a
# manual step via Synapse's own Admin API, same "managed by hand" category as
# Keycloak group membership itself. See docs/src/explanation/matrix.md.
resource "keycloak_openid_client" "matrix" {
  realm_id  = keycloak_realm.homelab.id
  client_id = "matrix"
  name      = "Matrix (Synapse)"
  enabled   = true

  access_type           = "CONFIDENTIAL"
  standard_flow_enabled = true
  client_secret         = random_password.matrix_client_secret.result

  valid_redirect_uris = ["https://matrix.${var.domain_name}/_synapse/client/oidc/callback"]
  web_origins         = ["+"]
}

resource "keycloak_openid_client_optional_scopes" "matrix" {
  realm_id  = keycloak_realm.homelab.id
  client_id = keycloak_openid_client.matrix.id

  optional_scopes = [
    "address",
    "phone",
    "offline_access",
    "microprofile-jwt",
    keycloak_openid_client_scope.groups.name,
  ]
}

resource "random_password" "mas_client_secret" {
  length  = 32
  special = false
}

# Matrix Authentication Service (MAS, #74) — replaces the matrix client
# above as the thing that actually talks to Keycloak. Synapse now delegates
# all auth to MAS (matrix_authentication_service in
# apps/matrix/base/synapse-config.yaml) rather than holding its own OIDC
# client credentials, so this client's redirect_uri is MAS's own upstream
# callback path (its documented shape, confirmed against MAS's own docs —
# https://<auth-service-domain>/upstream/callback/<provider-id>), not
# Synapse's. <provider-id> is a fixed ULID chosen once and mirrored exactly
# in apps/matrix-mas/base/mas-secrets-externalsecret.yaml's
# upstream_oauth2.providers[].id — the two must match or Keycloak will
# reject the callback as an unregistered redirect URI.
#
# The matrix client above is deliberately left in place, unused, rather
# than deleted in this same change — a cheap rollback path while MAS is
# being proven out. See docs/src/explanation/matrix.md's MAS section.
resource "keycloak_openid_client" "mas" {
  realm_id  = keycloak_realm.homelab.id
  client_id = "mas"
  name      = "Matrix Authentication Service (MAS)"
  enabled   = true

  access_type           = "CONFIDENTIAL"
  standard_flow_enabled = true
  client_secret         = random_password.mas_client_secret.result

  valid_redirect_uris = ["https://matrix-auth.${var.domain_name}/upstream/callback/01M1G9KN6N45DQKTCZ059X2VXS"]
  web_origins         = ["+"]
}

resource "keycloak_openid_client_optional_scopes" "mas" {
  realm_id  = keycloak_realm.homelab.id
  client_id = keycloak_openid_client.mas.id

  optional_scopes = [
    "address",
    "phone",
    "offline_access",
    "microprofile-jwt",
    keycloak_openid_client_scope.groups.name,
  ]
}

# Jellyfin (#52) has no native OIDC — the community
# Buco7854/jellyfin-plugin-sso plugin (an actively-maintained fork of the
# archived 9p4/jellyfin-plugin-sso) is installed by hand through Jellyfin's
# own admin UI after first boot, then pointed at this client. Unlike every
# app above, there is no env var or ExternalSecret this client_secret can
# flow through automatically — the plugin has no env-based config at all, so
# the secret has to be copy-pasted into its admin UI form by hand (see
# outputs.tf and docs/src/explanation/self-hosted-apps.md). "keycloak" is the
# plugin's own free-form provider name, chosen to match the redirect URI
# below (…/sso/OID/redirect/<provider name>). The groups optional scope is
# attached the same way as Mealie/ArgoCD/Grafana above so the plugin's own
# RoleClaim/AdminRoles config can gate Jellyfin admin on platform-admins
# membership, same "any Keycloak-authorized identity gets in, group
# membership only grants admin" model as everywhere else in this repo.
resource "random_password" "jellyfin_client_secret" {
  length  = 32
  special = false
}

resource "keycloak_openid_client" "jellyfin" {
  realm_id  = keycloak_realm.homelab.id
  client_id = "jellyfin"
  name      = "Jellyfin"
  enabled   = true

  access_type           = "CONFIDENTIAL"
  standard_flow_enabled = true
  client_secret         = random_password.jellyfin_client_secret.result

  valid_redirect_uris = ["https://jellyfin.${var.domain_name}/sso/OID/redirect/keycloak"]
  web_origins         = ["+"]
}

resource "keycloak_openid_client_optional_scopes" "jellyfin" {
  realm_id  = keycloak_realm.homelab.id
  client_id = keycloak_openid_client.jellyfin.id

  optional_scopes = [
    "address",
    "phone",
    "offline_access",
    "microprofile-jwt",
    keycloak_openid_client_scope.groups.name,
  ]
}

# --- Canonical secrets for External Secrets Operator (#42) -------------------
# Every client secret generated above for a real, GitOps-managed app used to
# need a manual `terragrunt output -raw` + hand-carry into a ksops-encrypted
# file — which silently drifts the moment this unit is destroyed/recreated or
# a secret is deliberately rotated, since nothing updates the already-
# committed file. var.keycloak_secrets_namespace (the "keycloak-secrets"
# namespace) is the canonical source ESO's ClusterSecretStore
# (apps/cluster-addons/base/, GitOps-managed) reads from via its kubernetes
# provider, mirroring each Secret out into that app's own namespace through
# an ExternalSecret living in that app's own apps/<app>/base/ — see
# docs/src/explanation/gitops-app-of-apps.md. No pods run here; this
# namespace exists purely to hold secret material and the RBAC scoping read
# access to it.
#
# The namespace itself (and its NetworkPolicies) is created in core-addons,
# not here (#44) — this unit is the last of core-addons' 4 dependents to
# apply, often minutes after ArgoCD (also part of core-addons) is already up
# and syncing apps/cluster-addons/'s RBAC against this exact namespace name;
# creating it there instead means it reliably exists well before ArgoCD's
# first sync pass. See core-addons/main.tf's kubernetes_namespace.keycloak_secrets
# and this variable's own description.
resource "kubernetes_secret" "immich_oidc_client_secret" {
  metadata {
    name      = "immich-oidc-client-secret"
    namespace = var.keycloak_secrets_namespace
  }

  data = {
    client-secret = keycloak_openid_client.immich.client_secret
  }

  type = "Opaque"
}

resource "kubernetes_secret" "actual_oidc_client_secret" {
  metadata {
    name      = "actual-oidc-client-secret"
    namespace = var.keycloak_secrets_namespace
  }

  data = {
    client-secret = keycloak_openid_client.actual.client_secret
  }

  type = "Opaque"
}

resource "kubernetes_secret" "paperless_oidc_client_secret" {
  metadata {
    name      = "paperless-oidc-client-secret"
    namespace = var.keycloak_secrets_namespace
  }

  data = {
    client-secret = keycloak_openid_client.paperless.client_secret
  }

  type = "Opaque"
}

resource "kubernetes_secret" "vaultwarden_oidc_client_secret" {
  metadata {
    name      = "vaultwarden-oidc-client-secret"
    namespace = var.keycloak_secrets_namespace
  }

  data = {
    client-secret = keycloak_openid_client.vaultwarden.client_secret
  }

  type = "Opaque"
}

resource "kubernetes_secret" "homebox_oidc_client_secret" {
  metadata {
    name      = "homebox-oidc-client-secret"
    namespace = var.keycloak_secrets_namespace
  }

  data = {
    client-secret = keycloak_openid_client.homebox.client_secret
  }

  type = "Opaque"
}

resource "kubernetes_secret" "homepage_oidc_client_secret" {
  metadata {
    name      = "homepage-oidc-client-secret"
    namespace = var.keycloak_secrets_namespace
  }

  data = {
    client-secret = keycloak_openid_client.homepage.client_secret
  }

  type = "Opaque"
}

# Includes client-id alongside client-secret: unlike the other five apps,
# changedetection's ksops file also encrypted its (non-sensitive, Tofu-known)
# client-id purely because ksops operates per-Secret rather than per-key —
# riding it along here means the ExternalSecret can produce both keys without
# a second mechanism.
resource "kubernetes_secret" "changedetection_oauth2_proxy_client_secret" {
  metadata {
    name      = "changedetection-oidc-client-secret"
    namespace = var.keycloak_secrets_namespace
  }

  data = {
    client-id     = keycloak_openid_client.changedetection_oauth2_proxy.client_id
    client-secret = keycloak_openid_client.changedetection_oauth2_proxy.client_secret
  }

  type = "Opaque"
}

resource "kubernetes_secret" "vikunja_oidc_client_secret" {
  metadata {
    name      = "vikunja-oidc-client-secret"
    namespace = var.keycloak_secrets_namespace
  }

  data = {
    client-secret = keycloak_openid_client.vikunja.client_secret
  }

  type = "Opaque"
}

resource "kubernetes_secret" "mealie_oidc_client_secret" {
  metadata {
    name      = "mealie-oidc-client-secret"
    namespace = var.keycloak_secrets_namespace
  }

  data = {
    client-secret = keycloak_openid_client.mealie.client_secret
  }

  type = "Opaque"
}

resource "kubernetes_secret" "lubelogger_oidc_client_secret" {
  metadata {
    name      = "lubelogger-oidc-client-secret"
    namespace = var.keycloak_secrets_namespace
  }

  data = {
    client-secret = keycloak_openid_client.lubelogger.client_secret
  }

  type = "Opaque"
}

# Includes client-id alongside client-secret, same as changedetection's above
# — oauth2-proxy needs both, and ksops/ExternalSecrets both operate
# per-Secret rather than per-key.
resource "kubernetes_secret" "pinchflat_oauth2_proxy_client_secret" {
  metadata {
    name      = "pinchflat-oidc-client-secret"
    namespace = var.keycloak_secrets_namespace
  }

  data = {
    client-id     = keycloak_openid_client.pinchflat_oauth2_proxy.client_id
    client-secret = keycloak_openid_client.pinchflat_oauth2_proxy.client_secret
  }

  type = "Opaque"
}

resource "kubernetes_secret" "matrix_oidc_client_secret" {
  metadata {
    name      = "matrix-oidc-client-secret"
    namespace = var.keycloak_secrets_namespace
  }

  data = {
    client-secret = keycloak_openid_client.matrix.client_secret
  }

  type = "Opaque"
}

resource "kubernetes_secret" "mas_oidc_client_secret" {
  metadata {
    name      = "mas-oidc-client-secret"
    namespace = var.keycloak_secrets_namespace
  }

  data = {
    client-secret = keycloak_openid_client.mas.client_secret
  }

  type = "Opaque"
}

# NetworkPolicies for keycloak-secrets (default-deny-all + the rest of the
# base trio) now come from core-addons' shared for_each, alongside every
# other namespace it owns — see that unit's local.core_addons_namespaces and
# this file's kubernetes_secret.*_oidc_client_secret resources above, which
# is why the namespace itself moved there too (#44).

# --- oauth2-proxy + whoami: the forward-auth demo/template -------------------
# Proves the Keycloak wiring end-to-end and doubles as the copy-paste
# template for real apps that need forward-auth (changedetection.io above is
# the first real one to actually use it — see
# docs/src/explanation/sso-and-keycloak.md). Kept as a living reference
# rather than torn down after verification, since future app integrations
# will want something to copy.
resource "kubernetes_namespace" "sso_demo" {
  metadata {
    name = "sso-demo"
    labels = {
      "pod-security.kubernetes.io/enforce" = "restricted"
      "pod-security.kubernetes.io/audit"   = "restricted"
      "pod-security.kubernetes.io/warn"    = "restricted"
    }
  }
}

# Not read by anything — exists so the demo credentials are recoverable
# (e.g. `kubectl get secret ... -o yaml`) without digging through Tofu state
# directly. Lives in sso-demo (this unit's own namespace) rather than the
# keycloak-infra unit's "keycloak" namespace, since units can't reference
# each other's resources directly.
resource "kubernetes_secret" "demo_user_credentials" {
  metadata {
    name      = "sso-demo-user-credentials"
    namespace = kubernetes_namespace.sso_demo.metadata[0].name
  }

  data = {
    username = keycloak_user.demo.username
    password = random_password.demo_user_password.result
  }

  type = "Opaque"
}

resource "random_password" "oauth2_proxy_cookie_secret" {
  length  = 32
  special = false
}

resource "kubernetes_secret" "oauth2_proxy_credentials" {
  metadata {
    name      = "oauth2-proxy-credentials"
    namespace = kubernetes_namespace.sso_demo.metadata[0].name
  }

  data = {
    client-id     = keycloak_openid_client.oauth2_proxy.client_id
    client-secret = keycloak_openid_client.oauth2_proxy.client_secret
    cookie-secret = random_password.oauth2_proxy_cookie_secret.result
  }

  type = "Opaque"
}

resource "helm_release" "oauth2_proxy" {
  name       = "oauth2-proxy"
  repository = "https://oauth2-proxy.github.io/manifests"
  chart      = "oauth2-proxy"
  version    = var.chart_versions.oauth2_proxy
  namespace  = kubernetes_namespace.sso_demo.metadata[0].name

  values = [
    yamlencode({
      fullnameOverride = "oauth2-proxy"
      config = {
        existingSecret = kubernetes_secret.oauth2_proxy_credentials.metadata[0].name
      }
      extraArgs = {
        provider          = "oidc"
        "oidc-issuer-url" = "https://keycloak.${var.domain_name}/realms/${keycloak_realm.homelab.realm}"
        "redirect-url"    = "https://sso-demo.${var.domain_name}/oauth2/callback"
        "email-domain"    = "*"
        "cookie-secure"   = "true"
        scope             = "openid email profile"
        # So the X-Auth-Request-User/Email headers ingress-nginx's
        # auth-response-headers annotation copies onto the protected app's
        # request actually have something to copy.
        "set-xauthrequest" = "true"
      }
      ingress = {
        enabled   = true
        className = "nginx"
        # oauth2-proxy owns only /oauth2/* on this host; whoami's own
        # Ingress (below) handles "/" behind auth-url/auth-signin.
        path  = "/oauth2"
        hosts = ["sso-demo.${var.domain_name}"]
        annotations = {
          "nginx.ingress.kubernetes.io/ssl-redirect" = "true"
          # Only this Ingress requests the cert for this host — whoami's
          # Ingress below reuses the same secretName without its own
          # cluster-issuer annotation, to avoid two Certificates racing to
          # manage one Secret.
          "cert-manager.io/cluster-issuer" = "letsencrypt-prod"
          # oauth2-proxy's session cookie bundles Keycloak's access/ID/refresh
          # tokens, which routinely exceeds ingress-nginx's default proxy
          # buffer size — found live as a real "upstream sent too big header"
          # 502 on /oauth2/callback, not a transient issue.
          "nginx.ingress.kubernetes.io/proxy-buffer-size" = "16k"
        }
        tls = [
          {
            secretName = "sso-demo-tls"
            hosts      = ["sso-demo.${var.domain_name}"]
          }
        ]
      }
    })
  ]

  depends_on = [
    keycloak_openid_client.oauth2_proxy,
    kubernetes_secret.oauth2_proxy_credentials,
  ]
}

resource "kubernetes_deployment" "whoami" {
  metadata {
    name      = "whoami"
    namespace = kubernetes_namespace.sso_demo.metadata[0].name
    labels    = { app = "whoami" }
  }

  spec {
    replicas = 1
    selector {
      match_labels = { app = "whoami" }
    }
    template {
      metadata {
        labels = { app = "whoami" }
      }
      spec {
        container {
          name  = "whoami"
          image = "traefik/whoami:v${var.whoami_version}"
          port {
            container_port = 80
          }
          resources {
            requests = {
              cpu    = "10m"
              memory = "16Mi"
            }
          }
          security_context {
            allow_privilege_escalation = false
            run_as_non_root            = true
            run_as_user                = 65534
            capabilities {
              drop = ["ALL"]
            }
            seccomp_profile {
              type = "RuntimeDefault"
            }
          }
        }
      }
    }
  }
}

resource "kubernetes_service" "whoami" {
  metadata {
    name      = "whoami"
    namespace = kubernetes_namespace.sso_demo.metadata[0].name
  }
  spec {
    selector = { app = "whoami" }
    port {
      port        = 80
      target_port = 80
    }
  }
}

resource "kubernetes_ingress_v1" "whoami" {
  metadata {
    name      = "whoami"
    namespace = kubernetes_namespace.sso_demo.metadata[0].name
    annotations = {
      "nginx.ingress.kubernetes.io/ssl-redirect"          = "true"
      "nginx.ingress.kubernetes.io/auth-url"              = "http://oauth2-proxy.${kubernetes_namespace.sso_demo.metadata[0].name}.svc.cluster.local/oauth2/auth"
      "nginx.ingress.kubernetes.io/auth-signin"           = "https://sso-demo.${var.domain_name}/oauth2/start?rd=$scheme://$host$request_uri"
      "nginx.ingress.kubernetes.io/auth-response-headers" = "X-Auth-Request-User,X-Auth-Request-Email"
    }
  }

  spec {
    ingress_class_name = "nginx"
    rule {
      host = "sso-demo.${var.domain_name}"
      http {
        path {
          path      = "/"
          path_type = "Prefix"
          backend {
            service {
              name = kubernetes_service.whoami.metadata[0].name
              port {
                number = 80
              }
            }
          }
        }
      }
    }
    tls {
      hosts       = ["sso-demo.${var.domain_name}"]
      secret_name = "sso-demo-tls"
    }
  }

  depends_on = [helm_release.oauth2_proxy]
}

# --- NetworkPolicies: default-deny + only the traffic this namespace
# actually needs (#31) ---------------------------------------------------
resource "kubernetes_network_policy" "default_deny_all" {
  metadata {
    name      = "default-deny-all"
    namespace = kubernetes_namespace.sso_demo.metadata[0].name
  }

  spec {
    pod_selector {}
    policy_types = ["Ingress", "Egress"]
  }
}

resource "kubernetes_network_policy" "allow_dns_egress" {
  metadata {
    name      = "allow-dns-egress"
    namespace = kubernetes_namespace.sso_demo.metadata[0].name
  }

  spec {
    pod_selector {}
    policy_types = ["Egress"]

    egress {
      to {
        namespace_selector {
          match_labels = { "kubernetes.io/metadata.name" = "kube-system" }
        }
      }
      ports {
        port     = "53"
        protocol = "UDP"
      }
      ports {
        port     = "53"
        protocol = "TCP"
      }
    }
  }
}

resource "kubernetes_network_policy" "allow_same_namespace" {
  metadata {
    name      = "allow-same-namespace"
    namespace = kubernetes_namespace.sso_demo.metadata[0].name
  }

  spec {
    pod_selector {}
    policy_types = ["Ingress", "Egress"]

    ingress {
      from {
        pod_selector {}
      }
    }
    egress {
      to {
        pod_selector {}
      }
    }
  }
}

# ingress-nginx -> both oauth2-proxy (the /oauth2 path, and its own
# auth-url subrequest for whoami's Ingress) and whoami (the "/" path).
resource "kubernetes_network_policy" "allow_ingress_nginx_ingress" {
  metadata {
    name      = "allow-ingress-nginx-ingress"
    namespace = kubernetes_namespace.sso_demo.metadata[0].name
  }

  spec {
    pod_selector {}
    policy_types = ["Ingress"]

    ingress {
      from {
        namespace_selector {
          match_labels = { "kubernetes.io/metadata.name" = "ingress-nginx" }
        }
      }
    }
  }
}

# oauth2-proxy's own OIDC calls (discovery/token/jwks) go to the *external*
# keycloak.<domain_name> hostname, which resolves back through
# ingress-nginx's LoadBalancer IP rather than directly to the keycloak
# namespace — so this is the egress rule that actually matters here, not a
# direct sso-demo -> keycloak one.
resource "kubernetes_network_policy" "allow_ingress_nginx_egress" {
  metadata {
    name      = "allow-ingress-nginx-egress"
    namespace = kubernetes_namespace.sso_demo.metadata[0].name
  }

  spec {
    pod_selector {}
    policy_types = ["Egress"]

    egress {
      to {
        namespace_selector {
          match_labels = { "kubernetes.io/metadata.name" = "ingress-nginx" }
        }
      }
    }
  }
}
