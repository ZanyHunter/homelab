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

The image is Debian-based (`postgres:18-bookworm`), so it runs as **uid 999** — not Keycloak's Alpine-based uid 70. The `vchord`/`earthdistance` extensions are installed automatically on first boot via a ConfigMap mounted at `/docker-entrypoint-initdb.d/` (`apps/immich/base/postgres.yaml`) — fully declarative, no manual `psql` step. `POSTGRES_USER` is the database's own superuser, same as Keycloak's Postgres, so no `ALTER DATABASE ... OWNER TO` workaround is needed either.

## The chart: rendered once, committed as static YAML

`apps/immich/base/immich.yaml` is a **pinned `helm template` render** of `oci://ghcr.io/immich-app/immich-charts/immich`, not something rendered live at ArgoCD sync time. Two reasons:

1. Kustomize's `helmCharts:` inflator has a real, currently-unresolved bug pulling OCI charts ([kubernetes-sigs/kustomize#4381](https://github.com/kubernetes-sigs/kustomize/issues/4381), [argoproj/argo-cd#21257](https://github.com/argoproj/argo-cd/issues/21257)) — the underlying `helm pull --repo oci://...` invocation it generates is invalid. Not worth building on a currently-broken combination.
2. It's the same "avoid third-party chart pinning risk" reasoning already used for Postgres and MinIO elsewhere in this repo (see `tofu/modules/backup/main.tf`'s MinIO note) — just applied to a whole chart instead of a single container.

The file's header comment has the exact values used and the upgrade procedure. Redis is the chart's own bundled Valkey (`valkey.enabled: true`) — trivial/ephemeral, not worth hand-rolling separately, unlike Postgres.

**A real gotcha found live**: neither the `immich-server` nor `immich-machine-learning` images ship a built-in non-root user, and `restricted` Pod Security Admission requires an explicit non-root declaration regardless — the first deploy attempt failed with a real `container has runAsNonRoot and image will run as root` on both. Fixed with an arbitrary `runAsUser: 1000`/`fsGroup: 1000` (not any specific image UID — there isn't one to match) applied globally via `defaultPodOptions`. Root-squash is disabled on the NFS export (same as elsewhere in this repo), so the exact UID writing to the media PVC doesn't matter.

## Machine learning

`machine-learning.enabled: true` from the start, with explicit resource requests/limits (`500m`/`512Mi` requests, `2`/`3Gi` limits) rather than the chart's unset default — deliberately conservative given this cluster's per-node RAM, sized alongside the worker node resize (see `CLAUDE.md`'s Kubernetes cluster section) that made room for it in the first place.

## Authentication: Keycloak, native OIDC

Immich has native OIDC support (see the "Apps with native OIDC support" section of `docs/src/bootstrap-environment/08-sso.md`) — no oauth2-proxy needed. `keycloak_openid_client.immich` (`tofu/modules/keycloak-realm/main.tf`) is Tofu-managed like ArgoCD/Grafana's clients, but its secret is generated *here* directly (`random_password.immich_client_secret`) rather than passed in from another unit — Immich's own config lives in `apps/immich/` under GitOps, not in any Terragrunt unit's Helm values, so there's no cross-unit dependency to wire.

The secret reaches the running Immich automatically (#42, no manual `terragrunt output`/hand-carry step): `keycloak-realm` also writes it into a plain `kubernetes_secret.immich_oidc_client_secret` in the `keycloak-secrets` namespace it owns, and `apps/immich/base/immich-config-externalsecret.yaml` — an `ExternalSecret` reading from that namespace via ESO's `ClusterSecretStore` (`apps/cluster-addons/base/`) — renders the full `immich-config.yaml` (note: **YAML**, not JSON — the chart mounts it at `IMMICH_CONFIG_FILE=/config/immich-config.yaml`) with the `oauth` block, interpolating just `clientSecret` from the live value. Referenced via `immich.existingConfiguration: immich-config` / `immich.configurationKind: Secret` in the chart values, rather than threading the secret through the Kustomize helm-chart values pipeline directly. See `docs/src/bootstrap-environment/06-gitops.md`'s ExternalSecrets section for the general mechanism.

`autoRegister: true` — any homelab Keycloak account can log into Immich on first OIDC login, matching how this is a personal/family photo app where Keycloak account creation itself is already the real gate (managed by hand in Keycloak's admin console, same as every other real account in this repo).

### Local login is disabled — platform-admins gets Immich's own admin role

`passwordLogin.enabled: false` in `immich-config-externalsecret.yaml`'s template, plus `IMMICH_ALLOW_SETUP=false` on the server container (a separate env-var-level gate on the local admin-setup wizard, independent of `passwordLogin`) — the only way into Immich is Keycloak, and the only way to bootstrap the very first admin is a `platform-admins` member's first OIDC login.

Getting the Keycloak side of this right took real iteration, and both gotchas are worth knowing before touching this again:

1. **The claim had to be a bare string, not an array — because of the specific Immich version deployed at the time (`v3.0.0`).** `oauth.roleClaim` (`tofu/modules/keycloak-realm/main.tf`'s `keycloak_openid_user_client_role_protocol_mapper.immich_role`) had to resolve to the literal string `"admin"`, not an array containing it: `v3.0.0`'s `getClaim` (`auth.service.ts`) checked `typeof value === 'string'`, so an array value silently failed that check and fell back to the `"user"` default — no error, no log. Found live as a real "logged in via Keycloak but landed as a normal user" bug. This is why the mapper is a **client role** scoped to Immich's own client (`client_id_for_role_mappings`) with `multivalued = false`, rather than the more obvious realm-role approach: a realm-role mapper's claim is unavoidably an array, since every user also carries Keycloak's own `default-roles-homelab`/`offline_access`/`uma_authorization` realm roles alongside "admin" — there's no way to filter a realm-role mapper down to just one role. A client-role mapper scoped to one client sidesteps this entirely, since Immich's client has no other client roles to compete with. **This constraint is gone as of `v3.1.0`** (see "Kept up to date" below — that release explicitly added array-value support), but the client-role mapper is left as-is rather than simplified back to a realm role: no reason to reintroduce noisy default realm roles into the claim just because a newer server version happens to tolerate them.
2. **`client_id_for_role_mappings` wants the client's `client_id` string, not its Keycloak-internal UUID** — despite the field name suggesting otherwise, and independent of the `v3.1.0` upgrade above. Passing `keycloak_openid_client.immich.id` (the UUID) produces a mapper that matches nothing, silently omitting the claim from the token entirely (verified via Keycloak's own `evaluate-scopes/generate-example-id-token` admin API, which is a much faster way to check what a mapper actually produces than a real login round-trip). The correct value is `keycloak_openid_client.immich.client_id` (the string `"immich"`).

`v3.0.0` also only evaluated `roleClaim` **at account creation**, not on every login — a role change didn't retroactively fix an already-created Immich user; the fix each time this session was to delete the user (`DELETE FROM "user" WHERE email = ...` — Immich's own foreign keys all cascade, confirmed via `pg_constraint` before doing this live) and let their next login recreate it, or use `immich-admin grant-admin`/`revoke-admin` (a CLI available via `kubectl exec` into the server pod) to patch an existing account directly instead. **Also fixed by the `v3.1.0` upgrade** — the role now re-syncs on every login, so removing someone from `platform-admins` correctly demotes them in Immich on their next login too, matching the behavior this repo already relies on for ArgoCD/Grafana's `platform-admins` gating.

## Kept up to date

Bumped `v3.0.0` → `v3.1.0` shortly after the initial deploy, specifically because that release ships "re-evaluate OIDC role claim on every login and support array values" — the exact two `v3.0.0` gaps documented above. Chart version stayed at `0.13.1` (immich-charts doesn't track every Immich release — see the `immich.yaml` header comment for the exact upgrade procedure); only the `image.tag` override changed, applied to both `immich-server` and `immich-machine-learning` since the chart drives both from one shared top-level value. No config/template changes were needed — verified via the release notes' own breaking-changes list (mobile-only) before upgrading, not after.

## Public access

Not enabled today — `dev`'s `env.hcl` has `public_ingress_enabled = false`, `public_apps = []`. It briefly was (`{ hostname = "photos" }`, `public_keycloak_realm = true`), which is exactly what proved the Cloudflare Tunnel mechanism end-to-end and surfaced both gotchas documented in `docs/src/bootstrap-environment/14-public-ingress.md` — that exposure was always meant to be temporary, since only prod is meant to be publicly exposed long-term and prod's own `domain_name` (the bare apex) avoids the hostname-split complexity dev hit entirely. Immich's own internal Ingress/hostname (`photos.dev.thepugh.family`) is completely unaffected either way — only the Cloudflare Tunnel's routing to it was ever added or removed.

## Verification

```bash
kubectl get pvc -n immich
kubectl get pods -n immich
```

Confirms the DB PVC bound on `ceph-rbd-dev` and the media PVC bound on `nfs-dev`, not just that pods exist. A real login (not just "the OAuth button appears") is the actual bar: visiting `https://photos.dev.thepugh.family` should redirect through Keycloak and land back in Immich authenticated.
