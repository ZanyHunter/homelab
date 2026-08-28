# 12. Observability

Metrics, logs, and alerting are handled by [kube-prometheus-stack](https://github.com/prometheus-community/helm-charts/tree/main/charts/kube-prometheus-stack) (Prometheus + Alertmanager + Grafana + node-exporter + kube-state-metrics) plus [Loki](https://grafana.com/oss/loki/) + [Grafana Alloy](https://grafana.com/docs/alloy/latest/) for log aggregation — all installed via Tofu (`tofu/modules/observability/main.tf`), not GitOps, same reasoning as `backup`/`keycloak-infra`: their configuration is expressed entirely through Helm chart values, not a separate hand-rolled object.

---

## Why a separate unit

`observability` sits alongside `backup`/`keycloak-infra` in the Terragrunt dependency graph (`core-addons` → {`backup`, `keycloak-infra`, `observability`} → `keycloak-realm`) rather than folding into `core-addons` — nothing downstream depends on its outputs, and it's a distinct operational concern, the same reasoning that already kept `backup` and `keycloak-infra` split out. See `docs/src/bootstrap-environment/10-terragrunt-units.md` for the full unit layout.

## What's deployed

- **Prometheus** (via the Prometheus Operator) scrapes cluster/node metrics and evaluates alerting rules. Retention is 15 days on a 20Gi NFS-backed PVC.
- **Alertmanager** routes firing alerts to a Discord webhook.
- **Grafana**, reachable at `https://grafana.k8s.thepugh.family` (`admin` / a Tofu-generated password in the `grafana-admin-credentials` Secret, `monitoring` namespace). Ships with the chart's own default dashboards for cluster and node metrics — no dashboard JSON authored in this repo.
- **node-exporter** and **kube-state-metrics** — bundled with the chart, give node-level and Kubernetes-object-level metrics respectively.
- **Loki**, deployment mode `SingleBinary` (the chart's own term for what's now generally called "Monolithic" mode) — right-sized for homelab log volume, storing chunks on a 20Gi NFS-backed PVC rather than requiring an S3-compatible backend.
- **Grafana Alloy**, a DaemonSet on every node (including control planes — see "Talos control-plane taint" below) shipping every pod's container logs into Loki, labeled by namespace/pod/container. The current, maintained log-shipping agent — Promtail is deprecated upstream.

## Alerting: what's covered, and where it goes

Node down/not-ready, pod crash-looping, and PVC-nearly-full are already covered by kube-prometheus-stack's own bundled default alert rules (`defaultRules.create`, on by default) — no extra work needed for those. Two more are added explicitly via the chart's `additionalPrometheusRulesMap` value:

- **`CertManagerCertificateExpiringSoon`** — fires when any cert-manager-managed certificate is within 7 days of expiry.
- **`VeleroBackupStale`** — fires when a Velero schedule hasn't produced a successful backup in the last ~28 hours (a buffer past the daily 03:00 schedule — see `docs/src/bootstrap-environment/07-backup-restore.md`).

Every alert (aside from the chart's always-firing `Watchdog` heartbeat, deliberately routed to a `null` receiver) routes to a **Discord** webhook, configured via `alertmanager.config` in `tofu/modules/observability/main.tf`'s `helm_release.kube_prometheus_stack`. The webhook URL lives encrypted at `discord_alert_webhook` in `tofu/secrets.enc.yaml` — see "Secrets management" in `CLAUDE.md`.

### Why cert-manager/Velero don't get a `ServiceMonitor`

The obvious way to add a new scrape target to a Prometheus-Operator-managed Prometheus is a `ServiceMonitor` custom resource. That would mean creating one in `core-addons` (for cert-manager) and `backup` (for Velero) — but a `ServiceMonitor` needs the Prometheus Operator's CRDs to already exist, and `core-addons`/`backup` apply *before* `observability` in the Terragrunt DAG. That's a real ordering conflict, not a cosmetic one.

Instead, both cert-manager and Velero already expose Prometheus-annotation-style metrics (`prometheus.io/scrape`/`.../port`/`.../path` pod annotations) by default in their own charts — no values change needed on their side. `tofu/modules/observability/main.tf` picks those up via `prometheus.prometheusSpec.additionalScrapeConfigs`, a plain scrape-config addition rendered by the *same* `helm_release` as the Prometheus Operator CRDs themselves — no separate custom resource, no ordering risk. The two new alert rules above use the same reasoning: `additionalPrometheusRulesMap` is rendered by that same `helm_release`, unlike a standalone `PrometheusRule`.

### Talos control-plane taint

Talos control-plane nodes carry a `NoSchedule` taint, and neither the node-exporter subchart nor the Alloy chart tolerate it by default — without an explicit toleration, both DaemonSets would silently skip 3 of this cluster's 6 nodes. `tofu/modules/observability/main.tf` adds a blanket `{ operator = "Exists", effect = "NoSchedule" }` toleration to both.

### kube-proxy/scheduler/controller-manager scrape targets

kube-prometheus-stack's default scrape jobs for `kube-proxy`, `kube-scheduler`, and `kube-controller-manager` assume kubeadm-style exposure — each component's metrics port reachable directly on the node's host IP. Talos binds these to loopback only, so all three came up as permanently `connection refused` targets (and a permanently-firing `TargetDown` alert) the first time this was tested against the real cluster. Rather than chasing Talos-side metrics exposure for three components this repo doesn't otherwise need visibility into, `kubeControllerManager`/`kubeScheduler`/`kubeProxy` (and their matching `defaultRules.rules` alert groups) are disabled in `tofu/modules/observability/main.tf`.

### Loki's chunks-cache defaults to an 8Gi memory request

Loki's `chunksCache` (an optional memcached-based query-performance cache, enabled by default) requests `allocatedMemory: 8192` — sized for a much larger deployment than any single node in this 4GB-RAM-per-node cluster has, leaving `loki-chunks-cache-0` permanently `Pending` ("Insufficient memory" on all 6 nodes) on the first real apply. Same class of oversized-chart-default problem already hit with MinIO (`docs/src/bootstrap-environment/07-backup-restore.md`). Not worth tuning a cache size for at this log volume, so both `chunksCache` and `resultsCache` are disabled outright.

## Verifying it's actually working

```bash
kubectl -n monitoring get pods
```

Everything (`kube-prometheus-stack-*`, `loki-0`, `alloy-*` DaemonSet pods) should be `Running`, with one `alloy` pod per node (6 total).

- **Metrics**: open Grafana, check the built-in "Kubernetes / Compute Resources / Cluster" and "Node Exporter / Nodes" dashboards show real data. In Prometheus's own UI (`kubectl -n monitoring port-forward svc/kube-prometheus-stack-prometheus 9090`) under Status → Targets, the `cert-manager` and `velero` jobs should both show `UP`.
- **Logs**: in Grafana, Explore → Loki datasource, query `{namespace="monitoring"}` (or any known namespace) and confirm real log lines come back.
- **Alerting**: the real bar, not just "the rule exists" — deliberately trigger a firing alert (e.g. scale a Deployment covered by a default rule to 0 replicas, or temporarily break a scrape target) and confirm it lands in the configured Discord channel within its `group_wait`/`repeat_interval` window.

## Restoring into a fresh cluster

Same shape as every other add-on unit: `terragrunt run --all apply` after a full destroy (or onto new hardware) recreates the `observability` unit from scratch — a fresh Prometheus/Loki with empty history, since neither is covered by Velero's object-level backups (see `docs/src/bootstrap-environment/07-backup-restore.md`) or has any external persistence beyond its own NFS-backed PVC. That's an accepted tradeoff: historical metrics/logs aren't disaster-recovery-critical the way the workloads they observe are.
