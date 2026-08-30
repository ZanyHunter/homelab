# NetworkPolicies and Pod Security Admission

Every namespace this repo manages is default-deny on both ingress and egress, with explicit allow rules for only the traffic that's actually needed — and carries an explicit, justified Pod Security Admission (PSA) level instead of the cluster's implicit unrestricted default. Both are Tofu-managed `kubernetes_network_policy`/namespace-label resources, living in whichever unit already owns that namespace (`core-addons`, `backup`, `keycloak-infra`, `keycloak-realm`, `observability`) — no new Terragrunt unit or `dependency` wiring needed, since every cross-namespace rule below references another namespace purely by its automatic `kubernetes.io/metadata.name` label, not a Terragrunt output.

---

## The base pattern

Every namespace gets three policies layered together (NetworkPolicies are additive — multiple policies selecting the same pods union their rules, they don't override each other):

1. **`default-deny-all`** — empty pod selector, both `Ingress`/`Egress` policy types, no rules. Everything else is an *additional* allow on top of this.
2. **`allow-dns-egress`** — every pod needs to resolve DNS; egress to `kube-system` on `53/UDP`+`53/TCP`.
3. **`allow-same-namespace`** — ingress+egress between pods in the same namespace. Applied to *every* namespace by default, not judged case-by-case per pod — found live on the very first namespace tackled (`minio`) that even a namespace that looks single-pod can have a same-namespace helper (MinIO's own post-install "make bucket" Job talking to the MinIO Service) that's easy to miss ahead of time. Without this rule, that kind of gap doesn't fail loudly; it just hangs.

Specific cross-namespace traffic gets its own additional policy, e.g. `velero`'s egress to `minio:9000` matched by an ingress rule on the `minio` side, or `ingress-nginx`'s ingress from anywhere on `80`/`443` since it's the cluster's actual entry point, not just another backend.

## Two rules worth knowing about

- **Anything that calls the apiserver directly** (ArgoCD's application-controller, cert-manager, Velero, csi-driver-nfs, kube-state-metrics, MetalLB's controller, Prometheus itself) needs egress to `10.96.0.1/32:443` — the in-cluster `kubernetes.default.svc` ClusterIP. It's stable and has no pod selector to match against, hence an `ipBlock` instead of a namespace/pod selector.
- **Admission/conversion webhooks** (`cert-manager-webhook`, `metallb-webhook-service`) need ingress on their port from the control-plane node subnet — not from any pod, since the apiserver calls webhooks directly from a control-plane node's real IP, which a `namespaceSelector`/`podSelector` can't express. Scoped via `var.network_cidr` (this environment's `env.hcl` value — `192.168.160.0/27` for prod, `192.168.160.32/27` for dev), threaded into `core-addons`/`observability` rather than hardcoded, since a single literal here would have silently been wrong for whichever environment applied second.

## Pod Security Admission: what landed where, and why

| Namespace | Level | Why |
|---|---|---|
| `metallb-system`, `csi-driver-nfs`, `monitoring` | `privileged` | Each runs a DaemonSet doing real host-level things — `hostNetwork`/`hostPID` (MetalLB's speaker, node-exporter) or real `mount(2)` syscalls and `hostPath` log mounts (csi-driver-nfs's node-plugin, Alloy). `baseline` already forbids all of these outright; there's no tightening available while these components exist. |
| `argocd`, `cert-manager`, `ingress-nginx`, `keycloak`, `sso-demo` | `restricted` | Every chart involved already ships a `restricted`-compliant `securityContext` by default, or came within one or two explicit fields of it. |
| `minio`, `velero` | `baseline` | The main workload in both passes `restricted` cleanly with an explicit `containerSecurityContext` — but a one-shot Helm hook Job in each (MinIO's `makeBucketJob`/`makeUserJob`, Velero's pre-upgrade `velero-upgrade-crds`) either doesn't expose enough of a `securityContext` value to satisfy `restricted`, or hits a kubelet-level check requiring an explicit `runAsUser` the hook's own chart values don't support setting. PSA applies namespace-wide, so the whole namespace stays at `baseline` rather than patching around a values schema gap for a Job that only runs once per install/upgrade. |

Getting a workload to `restricted` in this repo means: `allowPrivilegeEscalation: false`, `capabilities.drop: ["ALL"]`, `runAsNonRoot: true`, a `runAsUser`, and a `seccompProfile.type: RuntimeDefault` — either via the chart's own `securityContext`/`containerSecurityContext` values, or (for this repo's own hand-rolled resources, like Postgres and `whoami`) set directly.

## Gotchas found live

- **Postgres's existing data directory was owned by uid 70** (`postgres:alpine`'s real user), not the Debian-image uid 999 convention assumed at first — a guessed `runAsUser` produced a real `initdb: could not access directory: Permission denied` against the *existing* database (the real Keycloak realm/user data, not a fresh volume). Confirmed the actual owning uid live via a throwaway non-root debug pod mounted against the same PVC before picking the right value, rather than guessing twice.
- **A StatefulSet doesn't always replace a crash-looping pod under its new spec promptly.** After correcting Postgres's `runAsUser`, the StatefulSet's own spec updated immediately but the *running* pod kept crash-looping under the *old*, wrong spec for several minutes — Terraform's own post-apply rollout wait doesn't proactively nudge this. A manual `kubectl delete pod` forced the controller to recreate it under the corrected spec right away.
- **The `velero-upgrade-crds` hook Job's image has a non-numeric default user** (`cnb`, a Cloud Native Buildpacks convention) — `runAsNonRoot: true` alone isn't enough there; the kubelet can't verify a non-numeric user is actually non-root without an explicit numeric `runAsUser` alongside it.
- **This repo's own custom `install-ksops` initContainer** (on ArgoCD's repo-server, added when GitOps/ksops was wired up) had no `securityContext` at all — the one real gap keeping the `argocd` namespace off `restricted`, easy to miss since it's not part of any upstream chart's own defaults.

## Verifying it's actually enforced

```bash
kubectl get networkpolicy -A
kubectl get ns -o custom-columns=NAME:.metadata.name,ENFORCE:.metadata.labels."pod-security\.kubernetes\.io/enforce"
```

Every namespace this repo manages should show at least 3 NetworkPolicies (the base trio) and an explicit `ENFORCE` value — no namespace should show `<none>`. Beyond that, this round was verified against real functionality per namespace, not just "the policy applied": a real Velero backup completing against the NetworkPolicy-restricted MinIO target, a real login through Keycloak (both directly and through the full oauth2-proxy OIDC flow), Grafana/Prometheus/Loki/Alertmanager all still working (including a real Discord alert delivery), and ArgoCD staying Synced/Healthy through a forced resync (proving the repo-server's GitHub egress rule, not just cached state).
