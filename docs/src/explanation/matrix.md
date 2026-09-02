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

## Real-time calling (Element Call / MatrixRTC)

Split out from #57 into its own follow-up (#72) once it became clear "real-time calling with anonymous-joinable meeting links" was roughly as much new infrastructure as the base homeserver — a self-hosted LiveKit SFU, a small MatrixRTC Authorization Service (`lk-jwt-service`), and new Synapse experimental flags, added under `apps/matrix-livekit/` as a sibling app rather than folded into `apps/matrix/` itself.

**This first rollout ships authenticated group calling only — no anonymous/guest joining.** Research found a real, previously-unknown tradeoff: Synapse's `allow_guest_access: true` opens the *entire* homeserver to unauthenticated account creation, not just "can join the one call a link points at" — a materially different posture than every other app in this repo, where everything gates through Keycloak with no exceptions so far. Element's own recommended containment pattern (a second, disposable, closed-federated "guest" homeserver) properly isolates that exposure but is genuinely a second full Matrix homeserver deployment. Rather than build either speculatively, this phase targets any Keycloak-authorized identity only; anonymous joining is a distinctly-scoped later phase once authenticated calling is proven live.

### No coturn, no privileged namespace — a real correction mid-design

The initial design followed LiveKit's own "typical" self-hosting guidance: a wide ephemeral UDP port range (`rtc.port_range_start`/`port_range_end`) needing `hostNetwork: true`, which would have made LiveKit's namespace a **fourth** `privileged`-PSA namespace in a repo that otherwise holds that to exactly 3 (`metallb-system`, `csi-driver-nfs`, `monitoring`). The user rejected that shape outright — not comfortable exposing a privileged namespace to the internet — and pointed out LiveKit supports a **single-port UDP mux** (`rtc.udp_port`, all media multiplexed over one port via SSRC identifiers) as an alternative. A single port behaves like any other Service port, so:

- LiveKit runs as an ordinary `restricted`-PSA pod, no different in kind from every other app here.
- Its media port (`livekit-media`, `livekit.yaml`) is a normal `type: LoadBalancer` Service, announced by the same MetalLB instance already fronting ingress-nginx (protocol-agnostic, no special UDP handling needed), pinned to a static IP the same way `core-addons` pins ingress-nginx's own.
- `tofu/modules/network`'s new `unifi_port_forward` resource forwards exactly **one** WAN UDP port to that IP, not a wide range.

This also closed out a real gap in #72's own draft scope: a separate self-hosted `coturn` isn't actually needed at all — LiveKit ships its own built-in TURN server, and the thing that needs a UDP-reachable path is LiveKit itself. LiveKit's built-in TURN listener is deliberately left off for this rollout, though — it needs its own additional listener/port, and this deployment is LAN/VPN-only for now, where same-network peers connect directly and never exercise TURN at all; worth revisiting once real off-LAN usage surfaces actual restrictive-NAT connection failures, not before.

Two genuinely new NetworkPolicy shapes follow directly from this design (`apps/matrix-livekit/base/network-policies.yaml`): an ingress rule allowing `0.0.0.0/0` on LiveKit's single UDP port (every other app's ingress here only ever allows from the `ingress-nginx` namespace, since this port is reached directly rather than proxied), and an egress rule allowing LiveKit's own external-IP/STUN detection (`443`/TCP, `3478`/UDP to `0.0.0.0/0`) — the first genuine internet-egress rule in this repo, everything else only ever reaching this cluster's own `ingress-nginx` namespace.

### Config shape

- `apps/matrix-livekit/base/livekit-secrets.enc.yaml` (ksops) — LiveKit's full config (port, `rtc.udp_port`, `rtc.use_external_ip`, its own `keys` block) as one file, since `livekit-server` takes a single `--config` path with no Synapse-style multi-file merge.
- `apps/matrix-livekit/base/lk-jwt-secrets.enc.yaml` (ksops) — the same API key/secret pair, mirrored into `lk-jwt-service`'s own env vars (`LIVEKIT_KEY`/`LIVEKIT_SECRET`) — a small, deliberate duplication kept in sync by hand, same category as Synapse's own Postgres-password duplication.
- One shared public hostname (`matrix-calls.<domain>`), path-split by ingress-nginx: `/livekit/jwt` to `lk-jwt-service`, everything else to LiveKit's own WebSocket signaling endpoint — avoids sprawling into two new hostnames for one feature.
- `apps/matrix/base/synapse-config.yaml` gained `experimental_features` (`msc3266_enabled`/`msc4143_enabled`/`msc4222_enabled`) and a `matrix_rtc.transports` block pointing at `lk-jwt-service` — still fully static/non-secret, no change to the file-splitting rationale from #57.

### A real gotcha found in a test build: comments count toward token-replacement math too

The Kustomize delimiter/index trick this repo uses to reach a token nested inside a larger text value (splitting the whole field on a character, replacing one indexed segment — see #57's own gotcha with the same mechanism) treats the *entire* field value as one opaque string, YAML comments included. Adding the `matrix_rtc` block's own explanatory comment — which happened to describe file paths using literal `/` characters — silently shifted the delimiter count and made the replacement land inside that comment instead of the intended `livekit_service_url` token, caught in a repo-server test build before it reached a live cluster. Fixed by rewriting the comment to use zero `/` characters at all, and confirmed this is now a standing rule for any comment placed before a delimiter/index-targeted token in this file.

### A real gotcha found live: Element Web's DM call buttons stayed on the legacy stack, needing a version bump to actually fix

A real call from Element Web to a mobile Element X client failed with Element X showing "Unsupported call. Ask if the caller can use the new Element X app" — even though calls between two Element Web browser instances, on the same network, worked fine. That "worked fine" claim turned out to be misleading, caught only by actually watching LiveKit's and `lk-jwt-service`'s logs live during a real call attempt: both showed **zero traffic**. Every prior "verified" web-to-web call in this repo's history, including #72's own verification claims, was almost certainly plain legacy peer-to-peer Matrix calling between two browsers that both understand it — never actually exercising the LiveKit/MatrixRTC infrastructure this repo built at all. Worth remembering: two Element Web instances calling each other successfully is not evidence MatrixRTC/LiveKit works, only that legacy P2P calling does.

The first fix attempt — `element_call.use_exclusively: true` in `element-web-config.yaml`, meant to remove Element Web's legacy-call fallback per its own docs — did **not** work, confirmed by real browser console logs: clicking either the phone or video icon in a DM's room header called straight into Element Web's own legacy `call.ts` module (`placeCallWithCallFeeds()`, `placeVideoCall()`), never touching Element Call/MatrixRTC at all, regardless of the config. The actual root cause: the pinned Element Web version at the time (v1.11.90, January 2025) simply predated upstream work specifically on this exact gap — a "Set Element Call intents when starting and answering DM calls" PR, and an open issue about removing the legacy call option from Element Desktop entirely, both landing in later releases. The real fix was bumping the image tag to v1.12.27 (`element-web.yaml`), not another config workaround — confirmed as the right call only after the config-only fix demonstrably failed against live evidence (Synapse's own access logs showing `GET /_matrix/client/v3/voip/turnServer` and an `m.room.encrypted` call invite sent as a room message — the classic legacy VoIP flow — instead of any LiveKit/`lk-jwt-service` traffic at all).

`element_call.use_exclusively: true` is kept in `element-web-config.yaml` regardless of the version bump — still the documented correct setting for this repo's single-VoIP-stack deployment, just insufficient on its own against the older pinned version. No `element_call.url` needed — that field is for linking to a separate, externally-hosted Element Call web app, not relevant to this repo's embedded/native MatrixRTC calling.

### Deferred / not built

- Anonymous/guest-link joining (see above).
- LiveKit's built-in TURN listener (see above).
- Public exposure: `matrix-calls` is not in `public_apps` for either environment yet, and `matrix_calls_public_udp_forward` stays `false` everywhere — this phase is LAN/VPN-only, verified internally before any public exposure is considered.

## Verification

Verified live on dev, matching this repo's usual bar of an actual working round-trip rather than "the pod is Running":

- `kustomize build --enable-alpha-plugins --enable-exec` (via the ArgoCD repo-server's own kustomize+ksops setup, this repo's established test-build pattern) succeeded for both `dev`/`prod` overlays with every token correctly substituted and no leftover placeholders.
- Postgres, Synapse, Element Web, and the `.well-known` static server all reached `Running`/`Ready` on the first real apply (after the two live-fixes above); a transient Synapse restart before Postgres was ready self-resolved via normal Kubernetes backoff, not a config bug.
- All three real Let's Encrypt certificates (`synapse-tls`, `element-web-tls`, `matrix-wellknown-tls`) issued cleanly.
- `/.well-known/matrix/client` returns the correct JSON at the bare apex hostname; `/_matrix/client/versions` and `/health` respond correctly on Synapse's own subdomain; Element Web returns `200`.
- The actual OIDC bar this repo always checks, not just "the client exists": Synapse's `/_matrix/client/v3/login/sso/redirect` produces a real Keycloak authorize URL with the correct `client_id=matrix`, `redirect_uri` matching the registered value exactly, and a PKCE challenge — fetching it renders Keycloak's real "Sign in to Homelab" login form, not an error.
- `SELECT datcollate, datctype FROM pg_database` confirms `C`/`C` on the live database, not just "Synapse didn't crash."
- Both Ceph-backed volumes (Postgres, signing key) carry the `backup.velero.io/backup-volumes` annotation live; the NFS-backed media volume correctly carries none.
- The apex `unifi_dns_record` flagged above has since been applied and confirmed live — real-world use surfaced Element Web's own "Failed to get autodiscovery configuration from server" error until it was, since the wildcard record never covered the bare apex. `dev.thepugh.family` now resolves correctly, `/.well-known/matrix/client` returns real Let's Encrypt TLS (not ingress-nginx's fallback cert), and Element's autodiscovery succeeds.

Real-time calling (#72), verified live on dev:

- Both `matrix-livekit` overlays (`dev`/`prod`) build cleanly via the same repo-server test-build pattern, every token correctly substituted (including the annotation-path and comment-count gotchas above).
- LiveKit and `lk-jwt-service` pods reached `Running`/`Ready` on the very first apply — no PSA/security-context issues, unlike some other apps' images in this repo.
- LiveKit's own STUN-based external-IP detection succeeded through the new egress NetworkPolicy rule, confirming that rule is correctly scoped rather than just present.
- The shared `matrix-calls.<domain>` Ingress correctly path-splits: a plain request to `/livekit/jwt` reaches `lk-jwt-service` itself (confirmed by hitting the Service directly, bypassing Ingress, and getting the identical response) rather than ingress-nginx's own 404, and the default path reaches LiveKit's signaling endpoint.
- Synapse's `/_matrix/client/versions` now reports `msc4143: true` in `unstable_features`, and its `/_matrix/client/unstable/org.matrix.msc4143/rtc/transports` endpoint returns a real Matrix API auth error (`M_MISSING_TOKEN`) rather than a 404 — confirming the endpoint exists and is wired, addressing the version-compatibility risk #72 itself flagged from a live upstream GitHub issue.

Not verified: a real message send/receive round-trip, a real call between two authenticated participants, and a real interactive Keycloak login completion all need a browser/real client, same limitation as every other app's SSO verification in this repo. Public exposure (Cloudflare Tunnel route, port-forward) remains the user's own remaining step. Prod deployment deferred, same as every recent app onboarded here.
