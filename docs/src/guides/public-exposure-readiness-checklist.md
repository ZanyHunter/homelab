# Public Exposure Readiness Checklist

Work through this before adding any app's entry to `public_apps` in `tofu/live/prod/env.hcl` (see [Expose an App Publicly](./expose-an-app-publicly.md), whose own step 6 points here). The Cloudflare Tunnel mechanism itself is a one-time, already-built thing ([Public Ingress via Cloudflare Tunnel](../explanation/public-ingress.md)) — this checklist is about *this specific app*, plus one cluster-wide item worth closing before more than one app is public.

---

## Per-app checklist

- [ ] **WAF / rate-limiting** — already covered, no action needed. Cloudflare's edge provides both for free on every hostname routed through the existing Tunnel, before traffic ever reaches the cluster (see [Public Ingress via Cloudflare Tunnel](../explanation/public-ingress.md#why-cloudflare-tunnel)). The only way to lose this is exposing an app some other way (a direct port-forward) instead of through the Tunnel — don't do that.

- [ ] **NetworkPolicies reviewed for this specific app**, not just "a default-deny policy exists somewhere." The base default-deny trio ([NetworkPolicies and Pod Security Admission](../explanation/network-policies.md#the-base-pattern)) already applies to every managed namespace, but confirm for *this* app:
  - Its ingress allow rule scopes to the `ingress-nginx` namespace only, not a broader source — `kubectl get networkpolicy -n <app> -o yaml` should show an `allow-*-ingress`-style rule with a `namespaceSelector` matching `ingress-nginx`'s `kubernetes.io/metadata.name` label, not an `ipBlock` or an unscoped rule.
  - Its egress rules are no broader than what it actually needs (its own database, NFS, Keycloak, DNS, outbound internet if the app itself calls out) — nothing granting it reach into another app's namespace.
  - Its Pod Security Admission level is still the most restrictive achievable (`restricted` unless a specific, documented gap prevents it — see the table in [NetworkPolicies and Pod Security Admission](../explanation/network-policies.md#pod-security-admission-what-landed-where-and-why)).

- [ ] **Image(s) scanned for known CVEs.** No scanner runs in this cluster today (a real gap — there's no CI at all yet, see `CLAUDE.md`'s Known gaps). Until that's automated, run a manual scan against the *exact* pinned image reference (the tag in that app's `base/*.yaml`, or `chart_versions`/image tag in `env.hcl` for a Helm-rendered app like Immich) before it goes public:
  ```bash
  trivy image --severity HIGH,CRITICAL <image>:<tag>
  ```
  No unaddressed `HIGH`/`CRITICAL` finding without a documented reason it doesn't apply (not exploitable in this deployment, no fix available yet, etc.) — write that reason down somewhere durable (a code comment next to the pinned tag, or a line in this doc) rather than just running the scan once and moving on.

- [ ] **A patching cadence exists for this app specifically.** Every image/chart version in this repo is a static pin (`env.hcl`, or a literal tag in `apps/<app>/base/`) with no automated update mechanism (no Dependabot/Renovate configured). Once an app is public, commit to checking its upstream image/chart for new releases — security fixes specifically, not just new features — on a real cadence, at minimum monthly. Note the app and its cadence in [Deployed Apps](../reference/deployed-apps.md) if it doesn't already have one, so "is anyone actually checking this" has a durable answer instead of living only in someone's memory.

- [ ] **DMZ-style segmentation confirmed, not just assumed.** The namespace-per-app + default-deny architecture already gives strong segmentation by construction — a public app's namespace should never appear in another app's NetworkPolicy (as a source or a destination) and vice versa. This item is mostly a verification of the NetworkPolicy review above, not new work: spot-check with `kubectl get networkpolicy -n <app> -o yaml` and confirm no `namespaceSelector` in either direction references a namespace this app has no legitimate reason to talk to.

## Cluster-wide item (one-time, not per-app)

- [ ] **Scope `ingress-nginx`'s egress off the whole pod CIDR.** `kubernetes_network_policy.ingress_nginx_allow_backend_egress` (`tofu/modules/core-addons/main.tf`) currently allows egress from every `ingress-nginx` pod to the *entire* pod network (`10.244.0.0/16`, any port) — broad by design, specifically so onboarding a new app never needs a matching NetworkPolicy edit here. That's a real least-privilege gap once more than one app is public: any pod reachable on the pod network is reachable *from* ingress-nginx, whether or not it's meant to be an Ingress backend at all. Not urgent while only Immich is public and every namespace already default-denies unsolicited ingress on its own side — but worth closing before public exposure becomes routine rather than a one-off.

  **The fix, sketched and ready to execute, not yet done:** replace the `ip_block` rule with a `namespaceSelector` matched against a shared opt-in label (e.g. `ingress-allowed: "true"`) stamped on each namespace that legitimately has an Ingress backend — applied via the app-of-apps `ApplicationSet`'s `managedNamespaceMetadata` (`helm_release.argocd_apps`'s values in `tofu/modules/core-addons/main.tf`) rather than by hand per namespace, so a new app opts in automatically the same way it already gets discovered by the `ApplicationSet`'s git directory generator. This keeps the "no NetworkPolicy edit needed to onboard a new app" property the current broad rule exists for, while dropping the blast radius from the whole pod network down to just the namespaces that actually need to be reachable from ingress-nginx.

## Status

| App | Public since | Checklist last worked through |
| --- | --- | --- |
| [Immich](../explanation/immich.md) | prod, `photos.thepugh.family` | Not yet — went public before this checklist existed (#33). Work through it retroactively next time it's touched. |

Add a row here for every app added to `public_apps` from now on.
