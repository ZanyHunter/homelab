# 17. Self-Hosted Apps: Actual Budget, Paperless-ngx, Vaultwarden, Homebox, changedetection.io

Five more real workloads under `apps/`, following [Immich](./15-immich.md)'s pattern: one `apps/<app>/` directory each, storage split by locking-sensitivity (Ceph-backed for anything SQLite/Postgres, NFS-backed for bulk files), and Keycloak SSO wherever the app supports it. Reachable on the LAN/VPN at:

| App | Subdomain | Hostname |
| --- | --- | --- |
| [Actual Budget](https://actualbudget.org/) | `actual` | `actual.dev.thepugh.family` |
| [Paperless-ngx](https://docs.paperless-ngx.com/) | `paperless` | `paperless.dev.thepugh.family` |
| [Vaultwarden](https://github.com/dani-garcia/vaultwarden) | `vaultwarden` | `vaultwarden.dev.thepugh.family` |
| [Homebox](https://homebox.software/) | `inventory` | `inventory.dev.thepugh.family` |
| [changedetection.io](https://github.com/dgtlmoon/changedetection.io) | `changedetection` | `changedetection.dev.thepugh.family` |

None of these are public — same LAN/VPN-only posture Immich started at, before public exposure was scoped to prod-only (see [Public Ingress](./14-public-ingress.md)).

---

## Storage

Every app here persists to either SQLite or Postgres except changedetection.io (JSON-based watch/history files) — all five land on the Ceph-backed `ceph-rbd-dev` StorageClass rather than NFS, for the same fsync/locking-correctness reasoning as Immich's and Keycloak's Postgres (see [Ceph-Backed Storage](./13-ceph-storage.md)). Paperless-ngx is the one exception with a *second* PVC: its document library (originals, thumbnails, search index, consume-folder) is bulk file storage with no locking-sensitivity, so it's on `nfs-dev`, split the same way Immich splits database vs. media.

| App | Database | Storage |
| --- | --- | --- |
| Actual Budget | SQLite (bundled) | 5Gi, `ceph-rbd-dev` |
| Paperless-ngx | Postgres (hand-rolled `postgres:16-alpine`, uid 70 — same image/uid as Keycloak's Postgres) | DB: 10Gi `ceph-rbd-dev`. Media: 100Gi `nfs-dev` |
| Vaultwarden | SQLite (bundled) | 5Gi, `ceph-rbd-dev` |
| Homebox | SQLite (bundled) | 2Gi, `ceph-rbd-dev` |
| changedetection.io | None — flat JSON datastore | 5Gi, `ceph-rbd-dev` |

Paperless-ngx also needs a Redis-compatible broker (task queue + websocket backend) regardless of DB choice — `paperless-redis` is the chart-free, hand-rolled Valkey image already used nowhere else in this repo, ephemeral (`emptyDir`, no PVC): losing the broker on a restart just means in-flight tasks re-run, no durable data lives there.

All five Deployments/StatefulSets use an explicit `strategy: { type: Recreate }` (or, for Paperless's Postgres, the StatefulSet default) — every PVC here is `ReadWriteOnce`, so a default rolling update would try to schedule the replacement pod before the old one releases the volume and deadlock on a multi-attach error.

## A real gotcha found live: Kubernetes' auto-injected service-links env vars

Actual Budget's server crashed on first deploy with:

```
Error: port: ports must be within range 0 - 65535
```

Root cause: Kubernetes auto-injects Docker-links-style `<SVCNAME>_PORT`/`<SVCNAME>_SERVICE_*` env vars into every pod in a namespace, for every Service that namespace has, unless `enableServiceLinks: false` is set on the pod spec. The `actual` Service triggers an auto-injected `ACTUAL_PORT=tcp://<cluster-ip>:5006` — a URI string — which collides with Actual's *own* `ACTUAL_PORT` config key (convict's `port` format expects a bare integer). The app never had a chance to read its intended default; it read Kubernetes' injected value instead, got `NaN`, and failed range validation.

Paperless-ngx carries the same risk for the identical reason: its own internal listen-port setting is *also* named `PAPERLESS_PORT`, and its Service is also named `paperless` — the exact same collision shape, just not yet triggered at deploy time. Rather than fix only the app that actually broke, `enableServiceLinks: false` is set on every pod spec across all five apps in this batch — none of them rely on legacy Docker-links-style service discovery (they all use real Kubernetes DNS names like `paperless-postgres`, `paperless-redis` directly in config), so there's no downside to disabling it everywhere.

## Authentication

### Native OIDC: Actual Budget, Paperless-ngx, Vaultwarden, Homebox

All four support Keycloak login directly — no oauth2-proxy needed, same pattern as Immich/ArgoCD/Grafana. Each has its own `keycloak_openid_client` in `tofu/modules/keycloak-realm/main.tf`, secret Tofu-generated and hand-carried into that app's ksops-encrypted config under `apps/<app>/`, following `docs/src/bootstrap-environment/08-sso.md`'s "Apps with native OIDC support" guidance.

- **Actual Budget**: `ACTUAL_OPENID_*` env vars (`ACTUAL_LOGIN_METHOD=openid`, `ACTUAL_ALLOWED_LOGIN_METHODS=openid` — no password fallback). No per-user roles to wire; Actual's whole model is one shared server login, not per-user RBAC.
- **Paperless-ngx**: native OIDC via django-allauth's `openid_connect` provider, configured through `PAPERLESS_SOCIALACCOUNT_PROVIDERS` (a JSON blob — see `apps/paperless/paperless-config.enc.yaml`) and `PAPERLESS_APPS=allauth.socialaccount.providers.openid_connect`. **platform-admins → Django superuser**: `PAPERLESS_SOCIAL_ACCOUNT_SYNC_GROUPS=true` + `PAPERLESS_SOCIAL_ACCOUNT_SYNC_SUPERUSER_GROUP=platform-admins`, matched against the same reusable `groups` claim (plain group name, `full_path = false`) already used for ArgoCD/Grafana's RBAC — re-evaluated on *every* login, unlike Immich v3.0.0's account-creation-only behavior, so removing someone from `platform-admins` correctly demotes them here too. Getting the group claim into the token at all needs Paperless's Keycloak client to request the `groups` optional scope (`keycloak_openid_client_optional_scopes.paperless`) *and* the provider's own `SCOPE` array in `PAPERLESS_SOCIALACCOUNT_PROVIDERS` to include `"groups"` — both sides have to ask for it. `PAPERLESS_DISABLE_REGULAR_LOGIN=true` blocks the frontend password form and rejects any password-based login attempt server-side, regardless of whether a local account exists (see the gotcha below on why one now does).
- **Vaultwarden**: `SSO_ENABLED=true`, `SSO_ONLY=true` (no local-password account creation — Keycloak is the only login path). SSO only gates *account* login: vault items are still encrypted client-side with a separate master password the IdP never sees, so this doesn't remove that step. `SIGNUPS_ALLOWED=true` is left on so a real Keycloak account's first SSO login can actually create a Vaultwarden account — worth tightening (e.g. an invite-only flow) once every real household account has logged in once; this was a judgment call, not something verified against a documented "correct" setting, so revisit it live. Vaultwarden's `/admin` panel is gated by a separate static `ADMIN_TOKEN`, unrelated to Keycloak.
- **Homebox**: `HBOX_OIDC_ENABLED=true`, `HBOX_OPTIONS_ALLOW_LOCAL_LOGIN=false`. No app-wide admin role to wire — Homebox's ownership model is per-household (the first user of a household becomes its owner), not a single superuser concept like Paperless's.

### A real gotcha found live: Paperless-ngx's open signup window on a fresh install

The first real visit to `paperless.dev.thepugh.family` — before anyone had ever logged in via Keycloak — landed on what looked like a "create a superuser" signup page instead of going straight to Keycloak. Root cause, confirmed against the actual source (`src/documents/context_processors.py`'s `FIRST_INSTALL`, `src/documents/allauth_adapter.py`'s `is_open_for_signup`): paperless-ngx computes `FIRST_INSTALL` as "zero real `User` rows and zero `Document` rows exist," and when that's true, the login page unconditionally redirects to `/accounts/signup/` (django-allauth's local account registration) via inline JavaScript — **completely independent of `PAPERLESS_DISABLE_REGULAR_LOGIN`**, which only hides the password form and rejects password-based login attempts, but has no effect on this specific redirect or on `is_open_for_signup()`. On a genuinely empty database, this meant *whoever visited the app first* — not necessarily the intended `platform-admins` member — could register a local account there and be auto-granted Django superuser.

The fix isn't a config toggle (none exists), it's removing the precondition: `PAPERLESS_ADMIN_USER`/`PAPERLESS_ADMIN_PASSWORD` (consumed by the `manage_superuser` management command paperless-ngx's own entrypoint runs at container start) creates one real `User` row before anyone can ever visit, permanently falsifying `FIRST_INSTALL` and closing the `/accounts/signup/` bypass for good. This bootstrap account (`bootstrap-admin`, password ksops-encrypted in `apps/paperless/paperless-config.enc.yaml` even though it's provably inert) coexists safely with the `platform-admins` → superuser group-sync above — confirmed against the source that group sync (`handle_social_account_updated`) only ever mutates the specific user tied to a social login, never touching unrelated local rows — and can never itself be used to log in, since `PAPERLESS_DISABLE_REGULAR_LOGIN` rejects password auth unconditionally regardless of which account is attempting it. Verified live: after creating the bootstrap account, the login page no longer contains the signup-redirect script and shows only the Keycloak button, and a direct POST attempt to log in as `bootstrap-admin` with its real password is rejected with "Regular login is disabled" — not just "the config looks right."

### Forward-auth: changedetection.io

changedetection.io has no OIDC/SSO integration at all — confirmed against the project's own tracker (a feature request has been open since 2022 with no implementation), it only supports a single shared password. This is the first *real* app to use the `oauth2-proxy` + Ingress `auth-url`/`auth-signin` forward-auth template documented in `08-sso.md` and proven by the `sso-demo` reference deployment — copied as plain manifests under `apps/changedetection/` (`oauth2-proxy.yaml`) rather than the Tofu-managed Helm release `sso-demo` uses, matching every other app under `apps/` being plain Kustomize resources.

Two Ingresses share one hostname, same split as `sso-demo`/`whoami`: oauth2-proxy's own Ingress owns `/oauth2` and the actual TLS Certificate (`cert-manager.io/cluster-issuer` annotation); changedetection's Ingress handles `/` and reuses the same `secretName` without its own cluster-issuer annotation, avoiding two Certificates racing to manage one Secret. The same `proxy-buffer-size: "16k"` annotation `sso-demo` needed (oauth2-proxy's session cookie bundles Keycloak's access/ID/refresh tokens, routinely exceeding ingress-nginx's default buffer) is carried over here too, applied proactively rather than waiting to hit the same 502 live again.

## Verification

```bash
kubectl get pvc -n actual -n paperless -n vaultwarden -n inventory -n changedetection
kubectl get pods -n actual -n paperless -n vaultwarden -n inventory -n changedetection
```

Confirms every PVC bound on its intended StorageClass and every pod healthy, not just that resources exist. Real logins (not just "the login button appears") are the actual bar for each: visiting each hostname above should redirect through Keycloak (or, for changedetection.io, oauth2-proxy's own login page) and land back in the app authenticated.
