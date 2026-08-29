# 16. Immich

[Immich](https://immich.app/) is the first real workload deployed under `apps/` — proving out the app-of-apps GitOps pattern (`docs/src/bootstrap-environment/06-gitops.md`) for something beyond cluster add-ons. Reachable on the LAN/VPN at:

```
https://photos.dev.thepugh.family
```

It was also the first app to actually prove the Cloudflare Tunnel design in [Public Ingress](./14-public-ingress.md) publicly — briefly reachable at `photos-dev.thepugh.family`, which surfaced two real gotchas (a Universal SSL coverage gap and a Keycloak `redirect_uri` mismatch, both documented there) before that exposure was deliberately torn back down. Only prod is meant to be publicly exposed long-term; see "Public access" below.

---

## Storage split

- **Database** (`immich-postgres`, a hand-rolled `StatefulSet`): the Ceph-backed `ceph-rbd-dev` StorageClass — real block storage, since Postgres's fsync/locking needs are exactly what that StorageClass exists for (see `docs/src/bootstrap-environment/13-ceph-storage.md`).
- **Media library** (`immich-media`, a `ReadWriteMany` PVC): the NFS-backed `nfs-dev` StorageClass — bulk files, sequential reads, no locking-sensitivity, and it's what the NAS's disks are for.

## The database: VectorChord, not vanilla Postgres

Immich needs the [VectorChord](https://github.com/tensorchord/VectorChord) extension (the successor to pgvecto.rs) for its ML/search features — Immich checks the extension's version on startup and refuses to start without a compatible one. Rather than hand-rolling vanilla `postgres:alpine` (Keycloak's pattern) and DIY-installing the extension — a path Immich's own docs describe as fragile and "not officially recommended without advanced Postgres knowledge" — this uses [`tensorchord/vchord-postgres`](https://github.com/tensorchord/VectorChord-images), a purpose-built image with the extension pre-installed and correctly configured.

This is deliberately **not** [CloudNativePG](https://cloudnative-pg.io/), which is what the immich-charts project's own README recommends. CNPG would be a whole new operator + CRDs in this cluster to run one single-instance database — a real new component this repo's minimal-new-components philosophy pushes against, and `tensorchord/vchord-postgres` gives the same purpose-built-image guarantee without it.

The image is Debian-based (`postgres:18-bookworm`), so it runs as **uid 999** — not Keycloak's Alpine-based uid 70. The `vchord`/`earthdistance` extensions are installed automatically on first boot via a ConfigMap mounted at `/docker-entrypoint-initdb.d/` (`apps/immich/postgres.yaml`) — fully declarative, no manual `psql` step. `POSTGRES_USER` is the database's own superuser, same as Keycloak's Postgres, so no `ALTER DATABASE ... OWNER TO` workaround is needed either.

## The chart: rendered once, committed as static YAML

`apps/immich/immich.yaml` is a **pinned `helm template` render** of `oci://ghcr.io/immich-app/immich-charts/immich`, not something rendered live at ArgoCD sync time. Two reasons:

1. Kustomize's `helmCharts:` inflator has a real, currently-unresolved bug pulling OCI charts ([kubernetes-sigs/kustomize#4381](https://github.com/kubernetes-sigs/kustomize/issues/4381), [argoproj/argo-cd#21257](https://github.com/argoproj/argo-cd/issues/21257)) — the underlying `helm pull --repo oci://...` invocation it generates is invalid. Not worth building on a currently-broken combination.
2. It's the same "avoid third-party chart pinning risk" reasoning already used for Postgres and MinIO elsewhere in this repo (see `tofu/modules/backup/main.tf`'s MinIO note) — just applied to a whole chart instead of a single container.

The file's header comment has the exact values used and the upgrade procedure. Redis is the chart's own bundled Valkey (`valkey.enabled: true`) — trivial/ephemeral, not worth hand-rolling separately, unlike Postgres.

**A real gotcha found live**: neither the `immich-server` nor `immich-machine-learning` images ship a built-in non-root user, and `restricted` Pod Security Admission requires an explicit non-root declaration regardless — the first deploy attempt failed with a real `container has runAsNonRoot and image will run as root` on both. Fixed with an arbitrary `runAsUser: 1000`/`fsGroup: 1000` (not any specific image UID — there isn't one to match) applied globally via `defaultPodOptions`. Root-squash is disabled on the NFS export (same as elsewhere in this repo), so the exact UID writing to the media PVC doesn't matter.

## Machine learning

`machine-learning.enabled: true` from the start, with explicit resource requests/limits (`500m`/`512Mi` requests, `2`/`3Gi` limits) rather than the chart's unset default — deliberately conservative given this cluster's per-node RAM, sized alongside the worker node resize (see `CLAUDE.md`'s Kubernetes cluster section) that made room for it in the first place.

## Authentication: Keycloak, native OIDC

Immich has native OIDC support (see the "Apps with native OIDC support" section of `docs/src/bootstrap-environment/08-sso.md`) — no oauth2-proxy needed. `keycloak_openid_client.immich` (`tofu/modules/keycloak-realm/main.tf`) is Tofu-managed like ArgoCD/Grafana's clients, but its secret is generated *here* directly (`random_password.immich_client_secret`) rather than passed in from another unit — Immich's own config lives in `apps/immich/` under GitOps, not in any Terragrunt unit's Helm values, so there's no cross-unit dependency to wire.

The secret is retrieved once (`terragrunt output -raw immich_oidc_client_secret` from `tofu/live/dev/keycloak-realm/`) and hand-carried into `apps/immich/immich-config.enc.yaml` — a ksops-encrypted `v1/Secret` (same mechanism already proven in `apps/cluster-addons/`) containing the full `immich-config.yaml` (note: **YAML**, not JSON — the chart mounts it at `IMMICH_CONFIG_FILE=/config/immich-config.yaml`) with the `oauth` block. Referenced via `immich.existingConfiguration: immich-config` / `immich.configurationKind: Secret` in the chart values, rather than threading the secret through the Kustomize helm-chart values pipeline directly.

`autoRegister: true` — any homelab Keycloak account can log into Immich on first OIDC login, matching how this is a personal/family photo app where Keycloak account creation itself is already the real gate (managed by hand in Keycloak's admin console, same as every other real account in this repo).

## Public access

Not enabled today — `dev`'s `env.hcl` has `public_ingress_enabled = false`, `public_apps = []`. It briefly was (`{ hostname = "photos" }`, `public_keycloak_realm = true`), which is exactly what proved the Cloudflare Tunnel mechanism end-to-end and surfaced both gotchas documented in `docs/src/bootstrap-environment/14-public-ingress.md` — that exposure was always meant to be temporary, since only prod is meant to be publicly exposed long-term and prod's own `domain_name` (the bare apex) avoids the hostname-split complexity dev hit entirely. Immich's own internal Ingress/hostname (`photos.dev.thepugh.family`) is completely unaffected either way — only the Cloudflare Tunnel's routing to it was ever added or removed.

## Verification

```bash
kubectl get pvc -n immich
kubectl get pods -n immich
```

Confirms the DB PVC bound on `ceph-rbd-dev` and the media PVC bound on `nfs-dev`, not just that pods exist. A real login (not just "the OAuth button appears") is the actual bar: visiting `https://photos.dev.thepugh.family` should redirect through Keycloak and land back in Immich authenticated.
