# Public Ingress via Cloudflare Tunnel

**Only prod is meant to be publicly exposed, long-term.** [Immich](./immich.md) proved this whole mechanism live in dev — a real Cloudflare Tunnel, `cloudflared` registering healthy connections, real end-to-end OAuth logins — but that exposure was always temporary, gated by `public_ingress_enabled` in `env.hcl` and now switched back off (`false` for dev, `true` for prod). Two real gotchas were found live before it came back down (see below), both fixed and both worth knowing before prod ever repeats this. The module code (`tofu/modules/core-addons/main.tf`) is unchanged either way, only `env.hcl` values differ per environment — see the [Expose an App Publicly](../guides/expose-an-app-publicly.md) guide for the ready-to-execute runbook.

Why dev's exposure was temporary rather than kept: the user has an existing Immich instance running elsewhere at `photos.thepugh.family` today, which needs migrating to a legacy domain before prod can claim that hostname — and prod's own `domain_name` is already the bare apex (`thepugh.family`), so it doesn't hit the hostname-split complexity dev's `dev.thepugh.family` did (see below). Standing up dev's own permanent, separately-addressed public presence alongside that migration plan wasn't worth the complexity it would have added for a proof that had already served its purpose.

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

## Gotcha #1 (dev-only): public hostnames needed to live one level under the real apex

**Found live** the first time Immich's public hostname was actually tested: Cloudflare's free Universal SSL certificate only covers one subdomain level (`*.thepugh.family`) — it does *not* cover a two-levels-deep hostname like `photos.dev.thepugh.family` (which is `*.dev.thepugh.family` from the wildcard's point of view). A hostname built from `domain_name` gets no valid edge certificate at all: the browser sees a raw TLS handshake failure (`ERR_SSL_VERSION_OR_CYPHER_MISMATCH` in Chrome) before any request reaches the tunnel — plain HTTP still "works" in the sense of reaching Cloudflare's edge, just with nothing to negotiate TLS with. This is a Cloudflare edge-certificate limitation, unrelated to Full (strict)'s origin-cert validation below — see "Authentication" below for why those are two genuinely separate TLS legs.

**This is specific to environments whose `domain_name` is itself a subdomain — i.e. dev only.** The fix, rather than paying for [Advanced Certificate Manager](https://developers.cloudflare.com/ssl/edge-certificates/advanced-certificate-manager/) (~$10/month/zone) to cover deeper subdomains: public hostnames live one level under the real apex (`public_apex_domain`, `thepugh.family` for every environment) instead of under `domain_name`, with a `public_hostname_suffix` (`-dev` for dev, empty for prod). `photos` became `photos-dev.thepugh.family` publicly in dev, while `photos.dev.thepugh.family` kept working exactly as before for LAN/VPN access. **Prod never hits this at all**: its own `domain_name` is already the bare apex (`thepugh.family`), so its public and internal hostnames for the same app are identical — no split, no suffix needed (`public_hostname_suffix = ""` in `tofu/live/prod/env.hcl`), and `local.public_hostnames` in `tofu/modules/core-addons/main.tf` collapses to a no-op for prod as a result.

## Gotcha #2 (why dev's split made this worse): Keycloak rejected the public redirect_uri

**Also found live**, once Immich's public login was actually attempted end-to-end: Keycloak returned `Invalid parameter: redirect_uri`. Immich's OAuth flow computes its `redirect_uri` from whichever hostname the browser is actually using — `https://photos-dev.thepugh.family/auth/login` when reached publicly — but `keycloak_openid_client.immich`'s `valid_redirect_uris` only listed the *internal* hostname's URIs (`photos.dev.thepugh.family`), since that's what existed when the client was created. Keycloak correctly rejected a redirect URI it didn't recognize.

This is a direct consequence of gotcha #1's hostname split, not an independent bug: any app split across two different public/internal hostnames needs *every* hostname it might be reached on registered as a valid redirect URI. **Prod avoids this the same way it avoids gotcha #1** — with no hostname split, there's only ever one redirect URI to register per app, exactly the shape the [Onboard a New App](../guides/onboard-a-new-app.md) guide's OIDC client instructions already assume. If a future environment's `domain_name` is ever a subdomain again and needs this same split, the Keycloak client's `valid_redirect_uris` must include *both* hostnames' callback URLs, not just the internal one — worth remembering rather than rediscovering live a second time.

## TLS: Full (strict)

Cloudflare's strictest mode validates that the origin (ingress-nginx) presents a certificate that's both trusted and hostname-matching — no self-signed or expired certs accepted. This is effectively free here: cert-manager already issues real Let's Encrypt certs via DNS-01 for every hostname, so the "you need a publicly-trusted origin cert" requirement Full (strict) usually forces on people is already satisfied.

**This is not the same thing as "serving cert-manager's cert to the browser."** A Tunnel means TLS terminates twice, not once: browser ↔ Cloudflare's edge (Cloudflare's own certificate — see the Universal SSL section above for why that leg has its own coverage rules) and, separately, `cloudflared` ↔ origin (cert-manager's certificate, which is what Full (strict) actually validates). The browser never talks to `cloudflared` or ingress-nginx directly, so there's no way to make cert-manager's certificate the one the browser itself sees — that's inherent to proxying through Cloudflare at all, not a gap in this setup specifically.

The real tradeoff is operational, not security: Full (strict) **fails closed**. If a cert-manager renewal ever hiccups (an ACME rate limit, a transient DNS-01 failure), public traffic gets a hard `526` error until it's fixed, rather than silently falling back to an unverified connection. That's the right trade — a loud outage beats a silent security gap — but it does mean a cert problem becomes public-facing-visible immediately, worth knowing going in rather than discovering live.

## Authentication: Cloudflare is transport, Keycloak is the authority

A bare Cloudflare Tunnel does not participate in authentication at all — it's a pipe. A public app using Keycloak OIDC still redirects the browser straight to `keycloak.<domain>/realms/homelab/...` exactly like it does on the LAN today; Cloudflare never inspects or gates that flow.

**Cloudflare Access (Zero Trust) is explicitly not used.** It's a separate product that *could* insert a Cloudflare-hosted login page in front of a hostname before forwarding through the tunnel — useful as a second gate in front of something sensitive. It's deliberately skipped here: the user has VPN on every device, so there's no real remote-access need it would solve, and it would just be an extra moving part with its own login flow to maintain. This mirrors the "Upstream identity federation (deferred)" call-out in [SSO](./sso-and-keycloak.md) — a considered rejection, not an oversight, so a future session doesn't "helpfully" add it back without re-litigating why.

## Keycloak admin: internal/VPN-only, permanently

This is a hard design constraint, not a default that happens to be true today: **`keycloak.<domain>` never gets a wildcard route through the tunnel.** The admin console (`/admin/*`) must never become reachable from the public internet — internal LAN and VPN access, which already reaches it today, is sufficient and is the only access path that should ever exist for it.

The *first* time a real public app needs Keycloak login, the only thing that changes is one narrowly-scoped tunnel route added for exactly `/realms/homelab/*` on that hostname — nothing else. This is an **allowlist, not a denylist**: rather than trying to enumerate every sensitive path to block (`/admin`, and whatever else might exist or get added later), only the one path public OIDC flows actually need is ever forwarded, and everything else on that hostname is unreachable through the tunnel by construction. See the [Expose an App Publicly](../guides/expose-an-app-publicly.md) guide for the exact `cloudflare_zero_trust_tunnel_cloudflared_config` shape.

## Manual step already done: Cloudflare token scope

The existing Cloudflare API token (`tofu/secrets.enc.yaml`'s `cloudflare_api_token`, also used by cert-manager for DNS-01) needed **Account: Cloudflare Tunnel Edit** added to its permissions (on top of its existing Zone DNS Edit scope) before the Tunnel object could be Tofu-managed — a real permission increase on the one credential in this repo with blast radius outside the homelab, done with the user's explicit sign-off per `CLAUDE.md`'s standing Cloudflare guardrail. The token's value itself never changed, only its scope — no `secrets.enc.yaml` update was needed for this step.

This scope widening is account-level, not tied to dev's now-torn-down Tunnel specifically — **prod does not need to redo this step**, the same token already has what it needs whenever `public_ingress_enabled = true` is actually applied there.

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

**Whether the Tunnel exists at all is `public_ingress_enabled`** (`env.hcl`, `false` for dev, `true` for prod) — disabling it removes every Cloudflare Tunnel resource entirely (Tunnel object, `cloudflared` Deployment, DNS records), not just the routes, via `count = var.public_ingress_enabled ? 1 : 0` on each one in `tofu/modules/core-addons/main.tf`. **The app list within that is a separate `env.hcl` object-typed variable** (`public_apps`), mirroring the existing `chart_versions`/`nfs_storage` pattern this repo already uses for environment-specific config. Onboarding a public app means adding one entry and running `terragrunt apply` — not a Cloudflare dashboard click, and not a GitOps manifest edit. GitOps was considered (matching the precedent set by the MetalLB `IPAddressPool`/cert-manager `ClusterIssuer`s, which moved off Tofu) and rejected: those moved to GitOps specifically to dodge a CRD-creation-ordering problem between Tofu/Helm and the Kubernetes API — Cloudflare-side resources aren't Kubernetes CRs at all, so that problem doesn't exist here, and a plain Tofu variable keeps everything in one auditable `apply` instead of splitting the concern across two systems for no benefit.
