# Matrix (Synapse)

[Synapse](https://github.com/element-hq/synapse), the reference Matrix homeserver implementation, plus [Element Web](https://github.com/element-hq/element-web) as its web client (#57), `apps/matrix/`. The most architecturally involved app onboarded into this repo to date — heavier upfront user consultation than usual, since several of its decisions are genuinely one-way doors or break with how every other app here is built. This page covers the "why" behind each of those; see [Deployed Apps](../reference/deployed-apps.md) for the hostname/storage/auth summary table.

---

## Storage: three volumes, three different backends

- **Postgres** (hand-rolled `postgres:16-alpine`, same uid-70 pattern as Keycloak's/Paperless-ngx's/Vikunja's own Postgres), Ceph-backed, 10Gi — messages, room state, device keys, account data. Synapse's own docs recommend Postgres over SQLite for anything beyond the smallest personal deployment.
- **`media_store`** (uploaded images/videos/files), NFS-backed, 30Gi. Unlike Jellyfin's media library, this is fresh/empty and genuinely per-environment — a normal dynamically-provisioned PVC on the existing `nfs-dev`/`nfs-prod` StorageClass, same shape as Paperless-ngx's document library. No static PV, no shared export, no exception to "dev and prod share no infrastructure."
- **Synapse's signing key**, Ceph-backed, 1Gi, mounted at `/data` — Synapse auto-generates the key file on first boot if it doesn't exist yet. Gets the standing `backup.velero.io/backup-volumes` annotation, same as Postgres: issue #57's own acceptance criteria only call out the Postgres PVC, but this repo's rule is every Ceph-backed workload's data volume gets the annotation, no exceptions — losing the signing key is real, non-reconstructable state, not a re-derivable cache.

## `homeserver.yaml`: three files, each a whole logical unit

Synapse's config loader accepts multiple `-c`/`--config-path` files, merging them at startup — used here to keep secrets out of the plain, reviewable config, same motivation as every other app's ExternalSecret-templated config in this repo. What's genuinely different for Synapse: Synapse's own docs don't document whether that merge deep-merges nested lists/dicts or simply lets the last file's top-level key win. Rather than guess, every key that needs a secret value lives as one **complete, self-contained block** in exactly one file, never split field-by-field across two:

- `synapse-config.yaml` (plain `ConfigMap`) — the static majority: `server_name`, listeners, `media_store_path`, `federation_domain_whitelist: []`, `enable_registration: false`, `report_stats: false`. No `database:` or `oidc_providers:` keys at all, not even placeholders.
- `synapse-secrets-externalsecret.yaml` (`ExternalSecret`, same `keycloak-secrets` `ClusterSecretStore` every other app's OIDC client secret uses) — renders the *entire* `oidc_providers` block, not just `client_secret`, mirroring Immich's own "render the whole document, not just the sensitive field" pattern (`immich-config-externalsecret.yaml`).
- `matrix-secrets.enc.yaml` (ksops, no Tofu counterpart) — the *entire* `database:` block (including the non-secret host/port/user fields, kept together with the password for the same whole-block reasoning) plus Synapse's three internal secrets (`registration_shared_secret`, `macaroon_secret_key`, `form_secret`). These have no Tofu-generated counterpart, same as every hand-rolled Postgres app's DB password here — nothing outside the cluster needs to know them.

### A real templating collision, found before it could break anything

`user_mapping_provider`'s `localpart_template`/`display_name_template` are Synapse's own Jinja2 templates (e.g. `{{ user.preferred_username }}`), but they live inside `synapse-secrets-externalsecret.yaml`'s `spec.target.template` — a document ESO renders through its **own** Go-template engine before Synapse ever sees it. Left as plain `{{ user.preferred_username }}`, ESO's renderer would try to evaluate that as one of *its own* template fields (and fail, or silently emit nothing) before Synapse's Jinja engine ever got a chance to. Fixed by escaping each Jinja marker as `{{ "{{" }}`/`{{ "}}" }}` — Go-template syntax for emitting a literal `{{`/`}}` — so ESO's pass emits the Jinja text unchanged and Synapse's own template engine evaluates it normally at login time. Caught by reasoning through the two-template-engine collision before deploying, not found live as a crash.

### The collation gotcha, researched before deploying

Synapse hard-requires the database to have `C` collation/ctype and refuses to start otherwise. Alpine's `postgres` image (musl libc, no real locale data) does *not* reliably give you `C` collation just by virtue of being Alpine — real-world Synapse deployments hit this even there. Fixed explicitly via `POSTGRES_INITDB_ARGS: "--locale=C --lc-collate=C --lc-ctype=C --encoding=UTF-8"` on the container (`postgres.yaml`) rather than assumed — confirmed live afterward via `SELECT datcollate, datctype FROM pg_database`, both `C`.

## Apex identity: a deliberate exception to every other app's hostname shape

Every other app's Matrix ID/username-equivalent lives under a subdomain. The user chose the opposite for Matrix: user IDs are `@user:thepugh.family` (prod) / `@user:dev.thepugh.family` (dev), not `@user:matrix.<domain>` — a real, deliberate one-way-door decision (`server_name` can never change later without an entirely new, unportable identity), confirmed explicitly rather than defaulted.

This requires serving `/.well-known/matrix/client` at the **bare** `domain_name` itself — the first thing this repo serves at an apex hostname rather than a subdomain:

- `matrix-wellknown.yaml`: a small `nginxinc/nginx-unprivileged` static server (chosen specifically so it runs non-root on 8080 with no arbitrary-uid workaround needed) serving one static JSON file, `Ingress` bound to the literal `domain_name` value, path-scoped to `/.well-known/matrix/*`. Deliberately does **not** serve `/.well-known/matrix/server` (the federation discovery file) — with federation off, it has no functional purpose, and it's one fewer templated token to get wrong.
- Synapse's own subdomain (`matrix.<domain>`) is where clients actually connect after being redirected by that discovery file — `server_name` (identity) and the real API hostname are deliberately different values, unrelated to each other mechanically.
- **Local DNS gap**: the existing wildcard record (`*.<domain_name>`) never matches the bare, zero-label apex. Both environments need a new, explicit `unifi_dns_record` (`tofu/modules/network/main.tf`) — written but **not applied** without the user's explicit go-ahead, per this repo's standing Unifi guardrail (a genuinely new Unifi-managed resource, not a config change to an existing one).
- **Public reachability (prod only)**: Cloudflare's CNAME flattening natively proxies the literal zone apex, so a new `cloudflare_record` for bare `thepugh.family` is mechanically identical to any subdomain record. `core-addons`' Cloudflare Tunnel ingress rules gained one new case — `public_matrix_wellknown` (`env.hcl`, prod `true`/dev `false`), mirroring `public_keycloak_realm`'s existing path-scoped-exception shape exactly, rather than trying to force this into the generic `public_apps` list (which assumes a full-hostname forward). Structurally can never be meaningful for dev: dev's `domain_name` is a subdomain of the real apex, not the apex itself, so it could never get valid Cloudflare Universal SSL coverage there regardless. Also flagged for the user's confirmation before applying, per the standing Cloudflare guardrail.

### A real gotcha found live: `pathType: Prefix` rejecting a literal `.` in the path

The first `kubectl apply` of `matrix-wellknown`'s Ingress produced a real admission warning: `path /.well-known/matrix cannot be used with pathType Prefix`. ingress-nginx ≥4.12 validates `Prefix`-typed paths more strictly and flags a literal `.` (from `.well-known`) as needing regex-metacharacter treatment it won't apply under `Prefix` semantics. Fixed by switching that one path to `pathType: ImplementationSpecific` — ingress-nginx's own `ImplementationSpecific` behavior for a plain path with no actual regex is a normal prefix match, so this changes no real routing behavior, just satisfies the stricter validator.

### A real gotcha found live: Kustomize's delimiter/index replacement swallowing a string's tail

The same delimiter/index technique Immich's/Vikunja's overlays already use to reach a token nested inside a larger text value (splitting the whole field on a character, replacing one indexed segment) has a sharp edge: the replacement swaps the **entire** segment, not just the token within it. `matrix-wellknown`'s own `{"m.homeserver": {"base_url": "https://__APP_HOSTNAME__"}}` had no third `/` after the token, so the whole trailing `"}}` got swallowed along with it in a real test build — caught before it reached a live cluster. Fixed by adding a trailing `/` after the token purely to terminate the segment (`.../__APP_HOSTNAME__/"}}`), harmless for a URL either way. Every other token in this app's manifests was checked against the same requirement (immediately followed by another delimiter character) before being trusted.

## Authentication: native OIDC, with two real differences from every other app here

Synapse has genuine, mature OIDC support (`oidc_providers`), unlike Jellyfin's community-plugin workaround — this is native, well-documented delegated authentication, not forward-auth. Two things still differ from every other app in this repo:

- **No group-claim-to-admin mapping.** Synapse has no built-in way to map a `groups` claim onto its own server-admin flag the way Jellyfin's plugin or Mealie's `OIDC_ADMIN_GROUP` do. Granting Matrix server-admin, if ever needed, is a manual one-time step via Synapse's own Admin API — the same "managed by hand, not by Tofu" category as Keycloak group membership itself.
- **`enable_registration: false` does not block OIDC auto-provisioning** — confirmed via research before deploying, not assumed. It only gates Synapse's own native password/email signup flow; any successful Keycloak login still auto-creates a Matrix account on first use, exactly matching this repo's "any Keycloak-authorized identity gets in" model everywhere else (Homepage, Mealie's deliberately-unset `OIDC_USER_GROUP`, etc.) with zero extra config.

## Public exposure: three separate decisions, not one toggle

Issue #57 itself split this into three genuinely different questions, and this repo's answer differs per question:

- **Client-server API** (`matrix.<domain>`) and **Element Web** (`element.<domain>`): public in prod, added to `public_apps` like any other app — plain HTTPS, same shape as Immich's tunnel route, so a phone on cellular can actually reach Matrix.
- **Federation**: off. `federation_domain_whitelist: []` in `synapse-config.yaml` is the actual, authoritative control — not just omitting the `/.well-known/matrix/server` file, which this deployment doesn't serve at all right now anyway.
- **Voice/video calls (TURN)**: out of scope for this issue, same as #57 itself flagged — see below.

## Retention: deliberately indefinite

The user's explicit choice: no `retention:` block in `homeserver.yaml` at all, meaning Synapse never purges messages or media. Mechanically this is the *absence* of configuration, not extra work — matches how this repo already treats Immich's photos and Paperless-ngx's documents as real, non-disposable personal data rather than a cache.

## Deferred: real-time calling (Element Call / MatrixRTC)

The user separately asked for real-time calling with anonymous-joinable meeting links — a materially bigger, genuinely different piece of infrastructure than anything else on this page, phased out into its own follow-up issue rather than folded into #57. Research done before making that call, so it doesn't need re-deriving:

- That feature is **Element Call**, not classic Matrix 1:1 voice calls — it needs a self-hosted **LiveKit SFU**, a small **MatrixRTC Authorization Service** (`lk-jwt-service`, issues LiveKit JWTs — needs its own public HTTPS endpoint), and new Synapse experimental flags (MSC3266/MSC4143/MSC4222).
- **Media relay (TURN)** is the same fundamental problem #57 itself already flagged for voice calls: this repo's Cloudflare Tunnel is outbound-only with no port-forward, and TURN traditionally needs a real UDP-reachable listener. **Cloudflare Realtime TURN** (a managed, edge-hosted TURN service, usable independently of Cloudflare's own SFU offering) looks like it could plug into a self-hosted LiveKit without a port-forward or a new component to operate — but this is unverified in depth and would be a new Cloudflare product/cost surface, needing the same ask-first treatment as any other new Cloudflare config.
- **Anonymous guest joining** specifically requires enabling Matrix's guest-registration flow for the calling path — the first deliberately-open-to-unauthenticated-internet surface this repo would have (everything else gates through Keycloak). A real, distinct security-posture decision, not a technical footnote.

## Verification

Verified live on dev, matching this repo's usual bar of an actual working round-trip rather than "the pod is Running":

- `kustomize build --enable-alpha-plugins --enable-exec` (via the ArgoCD repo-server's own kustomize+ksops setup, this repo's established test-build pattern) succeeded for both `dev`/`prod` overlays with every token correctly substituted and no leftover placeholders.
- Postgres, Synapse, Element Web, and the `.well-known` static server all reached `Running`/`Ready` on the first real apply (after the two live-fixes above); a transient Synapse restart before Postgres was ready self-resolved via normal Kubernetes backoff, not a config bug.
- All three real Let's Encrypt certificates (`synapse-tls`, `element-web-tls`, `matrix-wellknown-tls`) issued cleanly.
- `/.well-known/matrix/client` returns the correct JSON at the bare apex hostname; `/_matrix/client/versions` and `/health` respond correctly on Synapse's own subdomain; Element Web returns `200`.
- The actual OIDC bar this repo always checks, not just "the client exists": Synapse's `/_matrix/client/v3/login/sso/redirect` produces a real Keycloak authorize URL with the correct `client_id=matrix`, `redirect_uri` matching the registered value exactly, and a PKCE challenge — fetching it renders Keycloak's real "Sign in to Homelab" login form, not an error.
- `SELECT datcollate, datctype FROM pg_database` confirms `C`/`C` on the live database, not just "Synapse didn't crash."
- Both Ceph-backed volumes (Postgres, signing key) carry the `backup.velero.io/backup-volumes` annotation live; the NFS-backed media volume correctly carries none.

Not verified: a real message send/receive round-trip and a real interactive Keycloak login completion both need a browser, same limitation as every other app's SSO verification in this repo. Public exposure's actual reachability from outside the LAN, and the apex DNS/Cloudflare records both flagged above, are the user's own remaining steps. Prod deployment deferred, same as every recent app onboarded here.
