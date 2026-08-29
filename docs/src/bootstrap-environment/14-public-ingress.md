# 15. Public Ingress via Cloudflare Tunnel

Nothing in this cluster is public-facing today — everything lives behind ingress-nginx's LoadBalancer IP, reachable only on the LAN (or over VPN). This page is a **design doc and reusable runbook**, not something already deployed: it's the plan to execute against the first time a real app needs to flip from internal-only to public, split out of the [public exposure readiness checklist](https://github.com/ZanyHunter/homelab/issues/33) (#33). Nothing here should be implemented speculatively — build it when there's a real app to route to, not before.

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

## TLS: Full (strict)

Cloudflare's strictest mode validates that the origin (ingress-nginx) presents a certificate that's both trusted and hostname-matching — no self-signed or expired certs accepted. This is effectively free here: cert-manager already issues real Let's Encrypt certs via DNS-01 for every hostname, so the "you need a publicly-trusted origin cert" requirement Full (strict) usually forces on people is already satisfied.

The real tradeoff is operational, not security: Full (strict) **fails closed**. If a cert-manager renewal ever hiccups (an ACME rate limit, a transient DNS-01 failure), public traffic gets a hard `526` error until it's fixed, rather than silently falling back to an unverified connection. That's the right trade — a loud outage beats a silent security gap — but it does mean a cert problem becomes public-facing-visible immediately, worth knowing going in rather than discovering live.

## Authentication: Cloudflare is transport, Keycloak is the authority

A bare Cloudflare Tunnel does not participate in authentication at all — it's a pipe. A public app using Keycloak OIDC still redirects the browser straight to `keycloak.<domain>/realms/homelab/...` exactly like it does on the LAN today; Cloudflare never inspects or gates that flow.

**Cloudflare Access (Zero Trust) is explicitly not used.** It's a separate product that *could* insert a Cloudflare-hosted login page in front of a hostname before forwarding through the tunnel — useful as a second gate in front of something sensitive. It's deliberately skipped here: the user has VPN on every device, so there's no real remote-access need it would solve, and it would just be an extra moving part with its own login flow to maintain. This mirrors the "Upstream identity federation (deferred)" call-out in [SSO](./08-sso.md) — a considered rejection, not an oversight, so a future session doesn't "helpfully" add it back without re-litigating why.

## Keycloak admin: internal/VPN-only, permanently

This is a hard design constraint, not a default that happens to be true today: **`keycloak.<domain>` never gets a wildcard route through the tunnel.** The admin console (`/admin/*`) must never become reachable from the public internet — internal LAN and VPN access, which already reaches it today, is sufficient and is the only access path that should ever exist for it.

The *first* time a real public app needs Keycloak login, the only thing that changes is one narrowly-scoped tunnel route added for exactly `/realms/homelab/*` on that hostname — nothing else. This is an **allowlist, not a denylist**: rather than trying to enumerate every sensitive path to block (`/admin`, and whatever else might exist or get added later), only the one path public OIDC flows actually need is ever forwarded, and everything else on that hostname is unreachable through the tunnel by construction. See the runbook below for the exact `cloudflare_zero_trust_tunnel_cloudflared_config` shape.

## ⚠️ Required manual step (when this is actually implemented): Cloudflare token scope

The existing Cloudflare API token (`tofu/secrets.enc.yaml`'s `cloudflare_api_token`, today used only by cert-manager for DNS-01) is scoped to Zone DNS Edit only. Managing the Tunnel object itself via Tofu needs **Account: Cloudflare Tunnel Edit** added to that token's permissions (or a second, separately-scoped token) — a real permission increase on the one credential in this repo with blast radius outside the homelab.

Per `CLAUDE.md`'s standing Cloudflare guardrail, this is an ask-first change: propose and confirm with the user before widening the token's scope, the same as any other new Cloudflare-related Tofu resource. Not needed today — only at the point this doc is actually executed against.

## Where things live (for whoever implements this)

All in the **`core-addons`** unit, alongside ingress-nginx/cert-manager — the existing home for ingress-adjacent add-ons:

| Concern | Resource |
|---|---|
| The Tunnel object `cloudflared` authenticates as | `cloudflare_zero_trust_tunnel_cloudflared` |
| Public hostname → internal Service routing rules | `cloudflare_zero_trust_tunnel_cloudflared_config` (remote-managed mode — `cloudflared` runs with just `--token`, no mounted config file to keep in sync) |
| Public DNS record per app (`<hostname> → <tunnel-id>.cfargotunnel.com`) | `cloudflare_dns_record` (provider v5 name — v4's `cloudflare_record` is deprecated). Uses the *existing* DNS-Zone-Edit token scope, no new permission needed for this piece specifically. |
| The `cloudflared` pod itself | Hand-rolled `kubernetes_deployment`, not a chart — Cloudflare doesn't publish an official one, and this repo already avoids third-party charts for pinned-version risk (see Postgres in `keycloak-infra`, MinIO in `backup`) |
| NetworkPolicy | Reuse the existing `allow_internet_egress` pattern (port 443 to `0.0.0.0/0`, already used by cert-manager/ArgoCD in `core-addons/main.tf`) plus DNS egress. No `hostNetwork`/`hostPID`/`hostPath` need, so `restricted` PSA should be achievable — unlike the `privileged` node-level DaemonSets elsewhere in this cluster. |

**The app list is an `env.hcl` object-typed variable** (e.g. `public_apps`), mirroring the existing `chart_versions`/`nfs_storage` pattern this repo already uses for environment-specific config. Onboarding a public app means adding one entry and running `terragrunt apply` — not a Cloudflare dashboard click, and not a GitOps manifest edit. GitOps was considered (matching the precedent set by the MetalLB `IPAddressPool`/cert-manager `ClusterIssuer`s, which moved off Tofu) and rejected: those moved to GitOps specifically to dodge a CRD-creation-ordering problem between Tofu/Helm and the Kubernetes API — Cloudflare-side resources aren't Kubernetes CRs at all, so that problem doesn't exist here, and a plain Tofu variable keeps everything in one auditable `apply` instead of splitting the concern across two systems for no benefit.

## The onboarding runbook

Once the infrastructure above exists, exposing a new app publicly is:

1. **Confirm prerequisites**: the app already works internally — a real Ingress, a cert-manager-issued cert, and NetworkPolicies scoped for it (see [NetworkPolicies and Pod Security Admission](./12-network-policies.md)).
2. **Add one entry** to `env.hcl`'s `public_apps` variable: the public hostname and the internal Service/port it should route to.
3. **If this is the first public app that needs Keycloak login**: add the one `/realms/homelab/*`-only route for `keycloak.<domain>` alongside it (see "Keycloak admin" above) — otherwise skip this step entirely.
4. `terragrunt apply` in `core-addons`.
5. **Verify from outside the LAN/VPN** (mobile data, not a laptop still on Wi-Fi): the app's hostname loads end-to-end, and — if step 3 applied — `keycloak.<domain>/admin` and anything else not explicitly allowlisted does *not* resolve through the tunnel. Internal/VPN access to everything, including Keycloak's admin console, should be completely unaffected throughout.
6. **Work through #33's remaining per-app checklist items** — stricter NetworkPolicies for that specific app, DMZ-style segmentation, image scanning, a patching cadence. This doc covers the ingress path only; #33 has the rest.
