# Expose an App Publicly

**Only prod is meant to be publicly exposed, long-term** — see [Public Ingress via Cloudflare Tunnel](../explanation/public-ingress.md) for the full reasoning, the two real gotchas dev's brief exposure surfaced, and the architecture this runbook builds on. Immich (`photos`) was dev's worked example, proving this whole runbook before it was ever meant to run against prod for real.

---

1. **Confirm prerequisites**: the app already works internally on prod — a real Ingress, a cert-manager-issued cert, and NetworkPolicies scoped for it (see [NetworkPolicies and Pod Security Admission](../explanation/network-policies.md)).
2. **Add one entry** to `tofu/live/prod/env.hcl`'s `public_apps` variable: `{ hostname = "<app>" }`. Since prod's `public_hostname_suffix` is empty, its public hostname is just `<app>.thepugh.family` — identical to its internal one, no split (see [Public Ingress via Cloudflare Tunnel](../explanation/public-ingress.md) for why dev needed one and prod doesn't).
3. **If this is the first public app that needs Keycloak login**: add the one `/realms/homelab/*`-only route for `keycloak.thepugh.family` alongside it (`public_keycloak_realm = true`) — otherwise skip this step entirely. Since there's no hostname split on prod, the redirect_uri mismatch dev hit shouldn't recur — but double-check `keycloak_openid_client.<app>`'s `valid_redirect_uris` actually lists the hostname being used before assuming it will just work.
4. `terragrunt apply` in `core-addons`.
5. **Verify from outside the LAN/VPN** (mobile data, not a laptop still on Wi-Fi): the app's hostname loads end-to-end, a real login completes, and `keycloak.thepugh.family/admin` and anything else not explicitly allowlisted does *not* resolve through the tunnel. Internal/VPN access to everything, including Keycloak's admin console, should be completely unaffected throughout.
6. **Work through #33's remaining per-app checklist items** — stricter NetworkPolicies for that specific app, DMZ-style segmentation, image scanning, a patching cadence. This guide covers the ingress path only; #33 has the rest.
