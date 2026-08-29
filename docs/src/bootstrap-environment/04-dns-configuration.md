# 5. DNS Configuration

Every ingress hostname in this repo (ArgoCD, Keycloak, Grafana, sso-demo, and any future `apps/<app>/` addition) lives under one **domain suffix** for the environment — `dev.thepugh.family` for `dev`, the real `thepugh.family` apex for `prod` (see `env.hcl`'s `domain_name`). Local DNS resolution for that whole suffix is a single **Tofu-managed wildcard record** in the Unifi controller (`unifi_dns_record.wildcard_ingress`, `tofu/modules/network/main.tf`), created automatically as part of a from-scratch stand-up — no manual step, and no per-hostname records to maintain as new apps land under `apps/`.

---

## How it works

- `env.hcl`'s `domain_name` drives every ingress hostname/OIDC redirect URI across every unit (`core-addons`, `keycloak-infra`, `keycloak-realm`, `observability`) — see `tofu/modules/network/variables.tf`'s `domain_name` description for the full picture.
- `env.hcl`'s `ingress_ip` is a **static** IP (not MetalLB's dynamically-assigned one) that both the wildcard DNS record and ingress-nginx's own Service (pinned via the `metallb.universe.tf/loadBalancerIPs` annotation, `core-addons`) point at. Static specifically so the `network` unit's DNS record doesn't need a live Tofu dependency on `core-addons`, which applies after it in the DAG — see the design note in `tofu/modules/network/variables.tf`'s `ingress_ip` description.
- The Unifi provider (`ubiquiti-community/unifi`, pinned in `tofu/modules/network/terraform.tf`) manages this via its `unifi_dns_record` resource — the same feature the UniFi Network Application's own UI calls **Local DNS Records** (Settings → Routing → DNS), just Tofu-managed instead of clicked through by hand.

## Verification

```bash
dig +short 'argocd.dev.thepugh.family' @<unifi-gateway-ip>
```

Should return the pinned `ingress_ip` value. Any new service deployed under `apps/<app>/` resolves automatically under the same wildcard — no DNS step needed, ever, matching the app-of-apps "just add a directory, push" model.

## A real hostname migration

This mechanism replaced an older manual wildcard record scoped to `k8s.thepugh.family` (retired as part of #10 — every hostname moved to the environment's real `domain_name` instead, and the old record was imported into Tofu state and destroyed cleanly rather than left as an unmanaged leftover). Two real things worth knowing if this ever needs redoing on a `domain_name` change:

- **cert-manager needs a minute to catch up.** Every Ingress with a `cert-manager.io/cluster-issuer` annotation gets a *new* Certificate request the moment its hostname changes (DNS-01 via Cloudflare, same `letsencrypt-prod`/`letsencrypt-staging` issuers, no cert-manager config change needed — DNS-01 doesn't care about subdomain depth within the zone). `kubectl get certificate -A` / `kubectl wait --for=condition=Ready certificate/<name> -n <ns>` before trying to actually log into anything on the new hostname, or `tofu`/`curl` calls against it will fail TLS verification against the *old* cert briefly.
- **DNS changes on the Unifi controller aren't instant.** A `tofu apply` that creates/deletes a `unifi_dns_record` completes immediately from Tofu's point of view, but the controller can take ~10–20s to actually start answering the new/removed record — a `dig` run immediately after `apply` can show a stale answer that resolves correctly moments later.
