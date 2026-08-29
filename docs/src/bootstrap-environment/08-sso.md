# 9. Single Sign-On (Keycloak)

[Keycloak](https://www.keycloak.org/) is the identity provider for homelab services, backed by a dedicated Postgres instance. Both are Tofu-managed, split across two Terragrunt units (see [Terragrunt Units](./10-terragrunt-units.md)): `keycloak-infra` (`tofu/modules/keycloak-infra/`) stands up Postgres and Keycloak itself, and `keycloak-realm` (`tofu/modules/keycloak-realm/`) manages the `homelab` realm and its clients via the [`keycloak` Terraform provider](https://registry.terraform.io/providers/keycloak/keycloak/latest/docs) — the same "talk to the app's own API declaratively" pattern already used for `unifi_network.this`.

---

## What's deployed

**Postgres**: a hand-rolled single-instance `StatefulSet` (not a chart — see the comment at the top of `tofu/modules/keycloak-infra/main.tf` for why), on the same NFS-backed `StorageClass` as everything else. Postgres-on-NFS has known caveats (fsync/locking semantics differ from local disk); accepted at this homelab scale and write volume, revisit if a Ceph-backed `StorageClass` ever exists (#28).

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

No forward-auth proxy needed — configure the app directly against the realm. Issuer URL:

{{#tabs global="domain" }}
{{#tab name="Production" }}
`https://keycloak.thepugh.family/realms/homelab`
{{#endtab }}
{{#tab name="Development" }}
`https://keycloak.dev.thepugh.family/realms/homelab`
{{#endtab }}
{{#endtabs }}

**Client ID/secret**: create a new `keycloak_openid_client` resource in `tofu/modules/keycloak-realm/main.tf` (copy `keycloak_openid_client.oauth2_proxy` as a starting point — `access_type = "CONFIDENTIAL"`, `standard_flow_enabled = true`, and the app's actual callback URL in `valid_redirect_uris`).

### Apps without native OIDC support (e.g. Grocy)

Copy the `oauth2-proxy` + Ingress `auth-url`/`auth-signin` pattern from `tofu/modules/keycloak-realm/main.tf`'s `helm_release.oauth2_proxy` and `kubernetes_ingress_v1.whoami`. Two things to change from the demo:

1. **The client secret should be ksops-encrypted, not Tofu-generated.** The demo's `oauth2_proxy` client is Tofu-managed end-to-end because it exists purely to prove the wiring, not as a real app — but a real app's per-client secret belongs in that app's `apps/<app>/` directory under ArgoCD's management (see `docs/src/bootstrap-environment/06-gitops.md`), the same way `apps/cluster-addons/letsencrypt-prod-issuer.enc.yaml` keeps its one sensitive field encrypted. Create the Keycloak client with an explicit `client_secret` (a `random_password`, as the demo does), then commit that value ksops-encrypted under the app's own directory rather than only in Tofu state.
2. **One oauth2-proxy per protected app** (or a shared one, if several apps can tolerate a shared session cookie domain) — the demo's `sso-demo` namespace/hostname pairing is illustrative, not something to reuse directly.

## Upstream identity federation (deferred)

Brokering an upstream identity provider (e.g. Google) through Keycloak — so a real login could use an existing Google account instead of a Keycloak-local password — was considered as part of #32 and deliberately deferred, not implemented. Local Keycloak accounts are sufficient for a single-operator homelab today, and deferring avoids standing up a Google Cloud OAuth app/credentials for no immediate benefit. This is also why group membership (see above) is managed by hand rather than via a Tofu `keycloak_user` resource: with accounts staying local for now, there's no real automation to gain by managing them declaratively, and doing so would mean putting a real person's identity into this repo's code.

Revisit if/when more real users need access (e.g. family members) — at that point it means a Keycloak `keycloak_identity_provider` resource (or realm identity-provider config) plus a Google Cloud OAuth app/credentials.

## No bootstrap quirk anymore

This used to need a manual two-phase apply on a from-scratch rebuild: the `keycloak` provider authenticates with an admin password generated in the same apply, which the old single flat module couldn't resolve in one pass. Splitting `keycloak-infra` and `keycloak-realm` into separate Terragrunt units fixed this structurally — `keycloak-realm`'s `dependency` block on `keycloak-infra` explicitly disallows mock outputs at apply time, so `terragrunt run --all apply` blocks until Keycloak has genuinely started and its real admin password exists before generating the `keycloak` provider block with it. See [Terragrunt Units](./10-terragrunt-units.md). A from-scratch rebuild is a single `terragrunt run --all apply` from `tofu/live/dev/`, same as everything else — no targeting, no special first-apply step.
