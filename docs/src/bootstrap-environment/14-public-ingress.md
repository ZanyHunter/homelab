# 15. Public Ingress via Cloudflare Tunnel

This is live — [Immich](./15-immich.md) (public: `photos-dev.thepugh.family`, internal: `photos.dev.thepugh.family`) is the first real app exposed publicly through it, split out of the [public exposure readiness checklist](https://github.com/ZanyHunter/homelab/issues/33) (#33). This page doubles as the reusable runbook for onboarding the *next* public app: everything below describes the actual deployed shape, not a plan waiting to be executed.

---

## Why Cloudflare Tunnel

The alternative is port-forwarding: opening an inbound port on the home router and pointing it at ingress-nginx's LoadBalancer IP. That works, but it means the router has an open inbound port at all, and WAF/rate-limiting has to be built or bolted on separately.

A [Cloudflare Tunnel](https://developers.cloudflare.com/cloudflare-one/networks/connectors/cloudflare-tunnel/) (`cloudflared`) is **outbound-only** — a pod in-cluster opens a connection *to* Cloudflare's edge, and Cloudflare routes public hostnames back through that connection. The router's inbound side never opens at all, and Cloudflare's edge gives WAF and rate-limiting for free, before traffic ever reaches the tunnel — closing #33's first checklist bullet with no new component to run or secure.

The tradeoff: Cloudflare sees the traffic (TLS terminates at their edge, or passes through to origin in Full-strict mode — see below), and their uptime becomes a dependency for anything public. Accepted as the right tradeoff for a single-operator homelab with no dedicated edge hardware.

## Architecture

```
Internet → Cloudflare edge → cloudflared (pod, outbound-only) → ingress-nginx's
existing ClusterIP Service → the app's existing Ingress → the app's Service/Pods
```

The tunnel is a second *path* into the same front door, not a parallel ingress stack. Once traffic reaches `cloudflared`, it hits ingress-nginx's ClusterIP Service exactly the way LAN traffic hits its LoadBalancer Service today — same Ingress objects, same cert-manager certs, same per-namespace NetworkPolicies. Nothing about how an app is exposed internally changes when it also becomes reachable publicly.

## Public hostnames live one level under the real apex, not under `domain_name`

**Found live**, on the very first real app: Cloudflare's free Universal SSL certificate only covers one subdomain level (`*.thepugh.family`) — it does *not* cover a two-levels-deep hostname like `photos.dev.thepugh.family` (which is `*.dev.thepugh.family` from the wildcard's point of view). A hostname built from `domain_name` gets no valid edge certificate at all: the browser sees a raw TLS handshake failure (`ERR_SSL_VERSION_OR_CYPHER_MISMATCH` in Chrome) before any request reaches the tunnel — plain HTTP still "works" in the sense of reaching Cloudflare's edge, just with nothing to negotiate TLS with. This is a Cloudflare edge-certificate limitation, unrelated to Full (strict)'s origin-cert validation above — see "Authentication" below for why those are two genuinely separate TLS legs.

The fix, rather than paying for [Advanced Certificate Manager](https://developers.cloudflare.com/ssl/edge-certificates/advanced-certificate-manager/) (~$10/month/zone) to cover deeper subdomains: **public hostnames live one level under the real apex** (`public_apex_domain`, `thepugh.family` for every environment) instead of under `domain_name`, with a `public_hostname_suffix` (`-dev` for dev, empty for prod, since prod's own `domain_name` is already the bare apex with no coverage gap) so dev and prod never collide on the same public hostname for the same app. `photos` becomes `photos-dev.thepugh.family` publicly, while `photos.dev.thepugh.family` keeps working exactly as before for LAN/VPN access and is still what cert-manager issues a certificate for and what ingress-nginx's Ingress object actually matches.

The tunnel's ingress rule reconciles the two: it matches on the *public* hostname, but rewrites `origin_request.http_host_header`/`origin_server_name` back to the app's real *internal* hostname before forwarding to ingress-nginx — see `local.public_hostnames` in `tofu/modules/core-addons/main.tf`. Without that rewrite, ingress-nginx would see the public hostname on the wire, find no matching Ingress rule, and fail to route at all. The practical effect: the URL you'd bookmark differs slightly depending on whether you're on the LAN/VPN or not — a real, accepted tradeoff for staying on Cloudflare's free tier rather than a $10/month recurring cost for something a naming convention solves for free.

## TLS: Full (strict)

Cloudflare's strictest mode validates that the origin (ingress-nginx) presents a certificate that's both trusted and hostname-matching — no self-signed or expired certs accepted. This is effectively free here: cert-manager already issues real Let's Encrypt certs via DNS-01 for every hostname, so the "you need a publicly-trusted origin cert" requirement Full (strict) usually forces on people is already satisfied.

**This is not the same thing as "serving cert-manager's cert to the browser."** A Tunnel means TLS terminates twice, not once: browser ↔ Cloudflare's edge (Cloudflare's own certificate — see the Universal SSL section below for why that leg has its own coverage rules) and, separately, `cloudflared` ↔ origin (cert-manager's certificate, which is what Full (strict) actually validates). The browser never talks to `cloudflared` or ingress-nginx directly, so there's no way to make cert-manager's certificate the one the browser itself sees — that's inherent to proxying through Cloudflare at all, not a gap in this setup specifically.

The real tradeoff is operational, not security: Full (strict) **fails closed**. If a cert-manager renewal ever hiccups (an ACME rate limit, a transient DNS-01 failure), public traffic gets a hard `526` error until it's fixed, rather than silently falling back to an unverified connection. That's the right trade — a loud outage beats a silent security gap — but it does mean a cert problem becomes public-facing-visible immediately, worth knowing going in rather than discovering live.

## Authentication: Cloudflare is transport, Keycloak is the authority

A bare Cloudflare Tunnel does not participate in authentication at all — it's a pipe. A public app using Keycloak OIDC still redirects the browser straight to `keycloak.<domain>/realms/homelab/...` exactly like it does on the LAN today; Cloudflare never inspects or gates that flow.

**Cloudflare Access (Zero Trust) is explicitly not used.** It's a separate product that *could* insert a Cloudflare-hosted login page in front of a hostname before forwarding through the tunnel — useful as a second gate in front of something sensitive. It's deliberately skipped here: the user has VPN on every device, so there's no real remote-access need it would solve, and it would just be an extra moving part with its own login flow to maintain. This mirrors the "Upstream identity federation (deferred)" call-out in [SSO](./08-sso.md) — a considered rejection, not an oversight, so a future session doesn't "helpfully" add it back without re-litigating why.

## Keycloak admin: internal/VPN-only, permanently

This is a hard design constraint, not a default that happens to be true today: **`keycloak.<domain>` never gets a wildcard route through the tunnel.** The admin console (`/admin/*`) must never become reachable from the public internet — internal LAN and VPN access, which already reaches it today, is sufficient and is the only access path that should ever exist for it.

The *first* time a real public app needs Keycloak login, the only thing that changes is one narrowly-scoped tunnel route added for exactly `/realms/homelab/*` on that hostname — nothing else. This is an **allowlist, not a denylist**: rather than trying to enumerate every sensitive path to block (`/admin`, and whatever else might exist or get added later), only the one path public OIDC flows actually need is ever forwarded, and everything else on that hostname is unreachable through the tunnel by construction. See the runbook below for the exact `cloudflare_zero_trust_tunnel_cloudflared_config` shape.

## Manual step already done: Cloudflare token scope

The existing Cloudflare API token (`tofu/secrets.enc.yaml`'s `cloudflare_api_token`, also used by cert-manager for DNS-01) needed **Account: Cloudflare Tunnel Edit** added to its permissions (on top of its existing Zone DNS Edit scope) before the Tunnel object could be Tofu-managed — a real permission increase on the one credential in this repo with blast radius outside the homelab, done with the user's explicit sign-off per `CLAUDE.md`'s standing Cloudflare guardrail. The token's value itself never changed, only its scope — no `secrets.enc.yaml` update was needed for this step.

If this is ever redone from scratch (a new Cloudflare account, a lost token), the same manual step applies: widen an API token's permissions to include Account: Cloudflare Tunnel Edit before `core-addons` can apply.

## Where things live

All in the **`core-addons`** unit, alongside ingress-nginx/cert-manager — the existing home for ingress-adjacent add-ons:

| Concern | Resource |
|---|---|
| The Tunnel object `cloudflared` authenticates as | `cloudflare_zero_trust_tunnel_cloudflared` |
| Public hostname → internal Service routing rules | `cloudflare_zero_trust_tunnel_cloudflared_config` (remote-managed mode — `cloudflared` runs with just `--token`, no mounted config file to keep in sync) |
| Public DNS record per app (`<hostname> → <tunnel-id>.cfargotunnel.com`) | `cloudflare_dns_record` (provider v5 name — v4's `cloudflare_record` is deprecated). Uses the *existing* DNS-Zone-Edit token scope, no new permission needed for this piece specifically. |
| The `cloudflared` pod itself | Hand-rolled `kubernetes_deployment`, not a chart — Cloudflare doesn't publish an official one, and this repo already avoids third-party charts for pinned-version risk (see Postgres in `keycloak-infra`, MinIO in `backup`) |
| NetworkPolicy | Reuse the existing `allow_internet_egress` pattern (port 443 to `0.0.0.0/0`, already used by cert-manager/ArgoCD in `core-addons/main.tf`) plus DNS egress. No `hostNetwork`/`hostPID`/`hostPath` need, so `restricted` PSA should be achievable — unlike the `privileged` node-level DaemonSets elsewhere in this cluster. |

**The app list is an `env.hcl` object-typed variable** (`public_apps`), mirroring the existing `chart_versions`/`nfs_storage` pattern this repo already uses for environment-specific config. Onboarding a public app means adding one entry and running `terragrunt apply` — not a Cloudflare dashboard click, and not a GitOps manifest edit. GitOps was considered (matching the precedent set by the MetalLB `IPAddressPool`/cert-manager `ClusterIssuer`s, which moved off Tofu) and rejected: those moved to GitOps specifically to dodge a CRD-creation-ordering problem between Tofu/Helm and the Kubernetes API — Cloudflare-side resources aren't Kubernetes CRs at all, so that problem doesn't exist here, and a plain Tofu variable keeps everything in one auditable `apply` instead of splitting the concern across two systems for no benefit.

## The onboarding runbook

Immich (`photos`) was the first app through this — its `env.hcl` entry and the Keycloak realm route are the worked example. Exposing the *next* app publicly is:

1. **Confirm prerequisites**: the app already works internally — a real Ingress, a cert-manager-issued cert, and NetworkPolicies scoped for it (see [NetworkPolicies and Pod Security Admission](./12-network-policies.md)).
2. **Add one entry** to `env.hcl`'s `public_apps` variable: `{ hostname = "<app>" }`. Its public hostname is derived automatically as `<app><public_hostname_suffix>.<public_apex_domain>` — no need to compute that by hand.
3. **If this is the first public app that needs Keycloak login** (it already isn't, since Immich already added it): add the one `/realms/homelab/*`-only route for `keycloak.<domain>` alongside it (see "Keycloak admin" above) — otherwise skip this step entirely.
4. `terragrunt apply` in `core-addons`.
5. **Verify from outside the LAN/VPN** (mobile data, not a laptop still on Wi-Fi): the app's hostname loads end-to-end, and `keycloak.<domain>/admin` and anything else not explicitly allowlisted does *not* resolve through the tunnel. Internal/VPN access to everything, including Keycloak's admin console, should be completely unaffected throughout.
6. **Work through #33's remaining per-app checklist items** — stricter NetworkPolicies for that specific app, DMZ-style segmentation, image scanning, a patching cadence. This doc covers the ingress path only; #33 has the rest.
