# 9. Single Sign-On (Keycloak)

[Keycloak](https://www.keycloak.org/) is the identity provider for homelab services, backed by a dedicated Postgres instance. Both are Tofu-managed, split across two Terragrunt units (see [Terragrunt Units](./10-terragrunt-units.md)): `keycloak-infra` (`tofu/modules/keycloak-infra/`) stands up Postgres and Keycloak itself, and `keycloak-realm` (`tofu/modules/keycloak-realm/`) manages the `homelab` realm and its clients via the [`keycloak` Terraform provider](https://registry.terraform.io/providers/keycloak/keycloak/latest/docs) — the same "talk to the app's own API declaratively" pattern already used for `unifi_network.this`.

---

## What's deployed

**Postgres**: a hand-rolled single-instance `StatefulSet` (not a chart — see the comment at the top of `tofu/modules/keycloak-infra/main.tf` for why), on the Ceph-backed `StorageClass` (real block storage, migrated off NFS — see `docs/src/bootstrap-environment/13-ceph-storage.md`, #28) rather than the NFS-backed one everything else here uses, since Postgres's fsync/locking semantics are exactly the case that StorageClass exists for.

**Keycloak**: the [codecentric/keycloakx](https://github.com/codecentric/helm-charts/tree/master/charts/keycloakx) chart. Chosen over Bitnami's chart for the same pinned-version reason as MinIO (see `tofu/modules/backup/main.tf`). Reachable at:

{{#tabs global="domain" }}
{{#tab name="Production" }}
`https://keycloak.thepugh.family`
{{#endtab }}
{{#tab name="Development" }}
`https://keycloak.dev.thepugh.family`
{{#endtab }}
{{#endtabs }}

**Realm**: `homelab`, with a bootstrap admin account (`admin` / a Tofu-generated password — `kubectl get secret -n keycloak keycloak-admin-credentials`) for the Keycloak console itself, separate from the realm's own users.

**A forward-auth demo**: [oauth2-proxy](https://oauth2-proxy.github.io/oauth2-proxy/) in front of a minimal `whoami` echo server. This exists to prove the Keycloak wiring works end-to-end, and doubles as the copy-paste template for real apps that need forward-auth (see below) — it's a living reference, not a one-off smoke test that gets torn down. Reachable at:

{{#tabs global="domain" }}
{{#tab name="Production" }}
`https://sso-demo.thepugh.family`
{{#endtab }}
{{#tab name="Development" }}
`https://sso-demo.dev.thepugh.family`
{{#endtab }}
{{#endtabs }}

## Admin access

```bash
kubectl get secret -n keycloak keycloak-admin-credentials -o jsonpath='{.data.KC_BOOTSTRAP_ADMIN_PASSWORD}' | base64 -d
```

Log in with username `admin` at:

{{#tabs global="domain" }}
{{#tab name="Production" }}
`https://keycloak.thepugh.family`
{{#endtab }}
{{#tab name="Development" }}
`https://keycloak.dev.thepugh.family`
{{#endtab }}
{{#endtabs }}

**This admin console stays internal/VPN-only, permanently** — even once real apps go public. See [Public Ingress via Cloudflare Tunnel](./14-public-ingress.md): Keycloak never gets a wildcard tunnel route, only a narrowly-scoped `/realms/homelab/*` route once a public app actually needs OIDC login, so `/admin` stays unreachable from the internet by construction.

## Trying the forward-auth demo

A test user (`demo`) already exists in the `homelab` realm:

```bash
kubectl get secret -n sso-demo sso-demo-user-credentials -o jsonpath='{.data.password}' | base64 -d
```

Visit this from a browser on the LAN:

{{#tabs global="domain" }}
{{#tab name="Production" }}
`https://sso-demo.thepugh.family`
{{#endtab }}
{{#tab name="Development" }}
`https://sso-demo.dev.thepugh.family`
{{#endtab }}
{{#endtabs }}

It redirects through Keycloak login, then lands on the `whoami` page showing the request oauth2-proxy forwarded, including `X-Auth-Request-User`/`X-Auth-Request-Email` headers identifying who logged in.

## Management apps: ArgoCD and Grafana

Both authenticate through Keycloak (`tofu/modules/core-addons/main.tf`'s `helm_release.argocd`, `tofu/modules/observability/main.tf`'s `helm_release.kube_prometheus_stack`) using their own native OIDC support — no oauth2-proxy needed, the same "Apps with native OIDC support" pattern documented below. Local admin login is disabled on both (`admin.enabled: "false"` for ArgoCD, `auth.basic.enabled: false` for Grafana — the latter needed alongside `auth.disable_login_form` since that alone still leaves basic-auth reachable via direct API calls).

**Access is group-based, not tied to any specific person.** A `platform-admins` Keycloak group (`tofu/modules/keycloak-realm/main.tf`'s `keycloak_group.platform_admins`) is the only thing either app's RBAC checks — ArgoCD's `policy.csv` is `g, platform-admins, role:admin`, Grafana's `role_attribute_path` checks `contains(groups[*], 'platform-admins')`. Nothing in the Tofu code names a real user.

**To grant someone admin access to ArgoCD/Grafana**: open Keycloak's admin console at:

{{#tabs global="domain" }}
{{#tab name="Production" }}
`https://keycloak.thepugh.family`
{{#endtab }}
{{#tab name="Development" }}
`https://keycloak.dev.thepugh.family`
{{#endtab }}
{{#endtabs }}

create (or use an existing) account, open it, go to the **Groups** tab, and **Join Group** → `platform-admins`. Group membership itself isn't Tofu-managed, by design — see "Upstream identity federation" below for the reasoning.

Under the hood, this needs a `groups` claim in the token, which isn't included by default — `keycloak_openid_client_scope.groups` is a reusable custom client scope with a `keycloak_openid_group_membership_protocol_mapper` (configured with `full_path = false`, so the claim is the plain group name rather than `/platform-admins`), attached to both clients as an *optional* scope (`keycloak_openid_client_optional_scopes`) rather than a default one — both apps already explicitly request it (ArgoCD's `requestedScopes`, Grafana's `scopes` config), so making it default too would only risk fighting Keycloak's own built-in default-scope list for no benefit.

**Break-glass recovery**: both local admin credentials still exist (`kubectl get secret -n argocd argocd-secret -o jsonpath='{.data.admin\.password}' | base64 -d`; `kubectl get secret -n monitoring grafana-admin-credentials -o jsonpath='{.data.admin-password}' | base64 -d`) — if Keycloak itself is ever unreachable, flip `admin.enabled`/`auth.basic.enabled` back in Tofu and reapply to regain local access, then flip them off again once Keycloak's back.

**A real gotcha found live**: the ArgoCD chart ships a default `configs.cm.url` value of `https://argocd.example.com` — this is what ArgoCD actually uses to build its OIDC `redirect_uri` (not the incoming request's `Host` header), so leaving it unset produces a real "Invalid redirect URL" rejection from Keycloak on every login attempt. Set `configs.cm.url` explicitly:

{{#tabs global="domain" }}
{{#tab name="Production" }}
`https://argocd.thepugh.family`
{{#endtab }}
{{#tab name="Development" }}
`https://argocd.dev.thepugh.family`
{{#endtab }}
{{#endtabs }}

## Adding a real app

### Apps with native OIDC support (e.g. Immich, Paperless-ngx)

No forward-auth proxy needed — configure the app directly against the realm. [Immich](./15-immich.md) and the four apps in [Self-Hosted Apps](./16-self-hosted-apps.md) with native OIDC (Actual Budget, Paperless-ngx, Vaultwarden, Homebox) are the real worked examples — copy their `valid_redirect_uris`/client shape for the next app, not `oauth2_proxy`'s (that one's Tofu-managed end-to-end specifically because it's a demo, not a real app — see the note below). Issuer URL:

{{#tabs global="domain" }}
{{#tab name="Production" }}
`https://keycloak.thepugh.family/realms/homelab`
{{#endtab }}
{{#tab name="Development" }}
`https://keycloak.dev.thepugh.family/realms/homelab`
{{#endtab }}
{{#endtabs }}

**Client ID/secret**: create a new `keycloak_openid_client` resource in `tofu/modules/keycloak-realm/main.tf` (copy `keycloak_openid_client.immich` as a starting point — `access_type = "CONFIDENTIAL"`, `standard_flow_enabled = true`, and the app's actual callback URL(s) in `valid_redirect_uris`). No manual `terragrunt output -raw` + hand-carry step anymore (#42): add one `kubernetes_secret` in the same unit, in the `keycloak-secrets` namespace it already owns, following the five existing examples right above the sso-demo section (e.g. `kubernetes_secret.actual_oidc_client_secret`). Then add an `ExternalSecret` under `apps/<app>/base/` pulling that value into the app's own namespace — see `docs/src/bootstrap-environment/06-gitops.md`'s ExternalSecrets section for the exact shape, including the two variants needed when the client secret is nested inside a larger config document or co-located with a key that has no Tofu counterpart. A sensitive Tofu output still exists for each app's client secret (following `immich_oidc_client_secret`'s pattern in `tofu/modules/keycloak-realm/outputs.tf`), kept for break-glass/debugging only — nothing needs to read it during normal operation anymore.

### Apps without native OIDC support (e.g. changedetection.io)

Copy the `oauth2-proxy` + Ingress `auth-url`/`auth-signin` pattern from `tofu/modules/keycloak-realm/main.tf`'s `helm_release.oauth2_proxy` and `kubernetes_ingress_v1.whoami` — [changedetection.io](./16-self-hosted-apps.md) (`apps/changedetection/base/oauth2-proxy.yaml`) is the real worked example, the first app to actually need this. Two things changed from the demo there:

1. **The client secret reaches the app via ExternalSecrets Operator, not by living entirely in Tofu.** The demo's `oauth2_proxy` client is Tofu-managed end-to-end (its `kubernetes_secret` lives in the same unit that also deploys the demo app) because it exists purely to prove the wiring, not as a real app. A real app's client still needs an explicit `client_secret = random_password....result` on its `keycloak_openid_client` (same as the demo), but the value then needs to reach a GitOps-managed namespace this unit doesn't own — add one more `kubernetes_secret` in the `keycloak-secrets` namespace (see the "Apps with native OIDC support" section above), then an `ExternalSecret` under the app's own `apps/<app>/base/` pulling it in (#42, see `docs/src/bootstrap-environment/06-gitops.md`). changedetection.io's own oauth2-proxy client (`apps/changedetection/base/changedetection-oauth2-proxy-credentials.yaml`) is the real worked example.
2. **One oauth2-proxy per protected app** (or a shared one, if several apps can tolerate a shared session cookie domain) — the demo's `sso-demo` namespace/hostname pairing is illustrative, not something to reuse directly.

## Upstream identity federation (deferred)

Brokering an upstream identity provider (e.g. Google) through Keycloak — so a real login could use an existing Google account instead of a Keycloak-local password — was considered as part of #32 and deliberately deferred, not implemented. Local Keycloak accounts are sufficient for a single-operator homelab today, and deferring avoids standing up a Google Cloud OAuth app/credentials for no immediate benefit. This is also why group membership (see above) is managed by hand rather than via a Tofu `keycloak_user` resource: with accounts staying local for now, there's no real automation to gain by managing them declaratively, and doing so would mean putting a real person's identity into this repo's code.

Revisit if/when more real users need access (e.g. family members) — at that point it means a Keycloak `keycloak_identity_provider` resource (or realm identity-provider config) plus a Google Cloud OAuth app/credentials.

## No bootstrap quirk anymore

This used to need a manual two-phase apply on a from-scratch rebuild: the `keycloak` provider authenticates with an admin password generated in the same apply, which the old single flat module couldn't resolve in one pass. Splitting `keycloak-infra` and `keycloak-realm` into separate Terragrunt units fixed this structurally — `keycloak-realm`'s `dependency` block on `keycloak-infra` explicitly disallows mock outputs at apply time, so `terragrunt run --all apply` blocks until Keycloak has genuinely started and its real admin password exists before generating the `keycloak` provider block with it. See [Terragrunt Units](./10-terragrunt-units.md). A from-scratch rebuild is a single `terragrunt run --all apply` from `tofu/live/dev/`, same as everything else — no targeting, no special first-apply step.
