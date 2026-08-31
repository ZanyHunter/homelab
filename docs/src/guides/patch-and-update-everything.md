# Patch and Update Everything

**Recommended cadence**: a monthly batched sweep through every category below, plus an independent weekly `trivy image` CVE scan against every app's currently-pinned image (not just public ones — see the [Public Exposure Readiness Checklist](./public-exposure-readiness-checklist.md), which only mandates this for apps going public). A `HIGH`/`CRITICAL` finding gets patched out-of-cycle, not held for the next monthly sweep.

Every bump — however small — goes through the same two-stage pipeline as any other change (see `CLAUDE.md`'s Git workflow): a branch off `development`, apply and verify live on dev, PR into `development`, then a second PR promotes it to `main` for you to apply to prod. This doc doesn't repeat that mechanic per category below — assume it for every step.

This repo has no automated dependency-update tooling today (no Renovate/Dependabot) — every check below is manual. See the note at the bottom on Renovate as a future option.

---

## 1. Tofu provider versions

Each unit's `terraform.tf` pins providers with a `~>` constraint (e.g. `~> 2.38.0`), resolved to an exact version in that unit's `.terraform.lock.hcl`. A `~>` constraint already allows patch-level updates automatically on the next `init` — what needs a deliberate check is whether a new *minor* version is available, which the constraint itself won't pick up.

- **Check**: for each `tofu/modules/*/terraform.tf`, look up the provider's latest release (e.g. `hashicorp/kubernetes`, `hashicorp/helm`, `cloudflare/cloudflare`, `siderolabs/talos`, `bpg/proxmox`, `keycloak/keycloak`, `paultyng/unifi`, `carlpett/sops`, `hashicorp/random` — all on the [Terraform Registry](https://registry.terraform.io/)).
- **Bump**: edit the `~> X.Y.Z` constraint in the relevant `terraform.tf`, then run `terragrunt init -upgrade` in that unit's `tofu/live/dev/<unit>/` directory — this regenerates `.terraform.lock.hcl` with the new resolved version. Commit the updated lock file alongside the constraint edit.
- **Verify**: `terragrunt plan` should show no unexpected diff (a provider bump alone shouldn't change any resource); apply and confirm the unit's normal health signals (see each unit's own explanation page).

## 2. Helm chart versions (`chart_versions` in `env.hcl`)

Every Tofu-installed Helm release reads its version from the `chart_versions` object — set independently in `tofu/live/dev/env.hcl` and `tofu/live/prod/env.hcl` (per this repo's per-environment design). Bump dev's copy, verify live, then bump prod's copy as part of the same promotion PR (there's no reason for the two to drift once a version is verified good).

| `chart_versions` key | Helm repository | Installed by |
| --- | --- | --- |
| `metallb` | `https://metallb.github.io/metallb` | `core-addons` |
| `ingress_nginx` | `https://kubernetes.github.io/ingress-nginx` | `core-addons` |
| `cert_manager` | `https://charts.jetstack.io` | `core-addons` — **note**: the Tofu code prepends `v` to this value (`version = "v${var.chart_versions.cert_manager}"`), so the pin itself is unprefixed (`1.15.1`) even though cert-manager's own releases are tagged `v1.15.1` |
| `argocd`, `argocd_apps` | `https://argoproj.github.io/argo-helm` | `core-addons` (both charts live in the same repo) |
| `csi_driver_nfs` | `https://raw.githubusercontent.com/kubernetes-csi/csi-driver-nfs/master/charts` | `core-addons` |
| `ceph_csi_rbd` | `https://ceph.github.io/csi-charts` | `core-addons` |
| `external_secrets` | `https://charts.external-secrets.io` | `core-addons` — **extra step**: `files/external-secrets-crds.yaml` is a pinned `helm template` render of this chart's CRDs, committed separately from the Helm release (see [GitOps: App-of-Apps and Secrets](../explanation/gitops-app-of-apps.md)). Regenerate it by hand on every bump — the live chart won't install its own CRDs (`installCRDs = false`), so a stale render means the new chart version runs against old CRD schemas. |
| `minio` | `https://charts.min.io/` | `backup` |
| `velero` | `https://vmware-tanzu.github.io/helm-charts/` | `backup` — **extra step**: the `velero` CLI pin in `mise.toml` must move in lockstep with this value (its `Chart.yaml` `appVersion` is the matching CLI/server version) — see `CLAUDE.md`'s Toolchain section and [Backup and Restore](../explanation/backup-and-restore.md). |
| `keycloak` | `https://codecentric.github.io/helm-charts` | `keycloak-infra` |
| `oauth2_proxy` | `https://oauth2-proxy.github.io/manifests` | `keycloak-realm` — this is the **sso-demo** deployment specifically; changedetection.io runs its own separate, hand-rolled oauth2-proxy (see §4 below) with its own image tag to check independently. |
| `kube_prometheus_stack` | `https://prometheus-community.github.io/helm-charts` | `observability` |
| `loki`, `alloy` | `https://grafana.github.io/helm-charts` | `observability` |

- **Check**: each repository URL above serves a standard Helm `index.yaml` — search it on [Artifact Hub](https://artifacthub.io/) (which aggregates all of these) for the latest version, or check the chart's own upstream GitHub repo's releases/`Chart.yaml`.
- **Bump**: edit the value in both `tofu/live/dev/env.hcl` and `tofu/live/prod/env.hcl`'s `chart_versions` object, `terragrunt apply` the owning unit on dev.
- **Verify**: unit-specific — `terragrunt plan` clean, the workload's pods healthy, and (where applicable) a real functional check per that unit's own explanation page (a real login, a real backup, a real alert). Don't assume "pods Running" alone is sufficient for anything with its own documented verification bar.

## 3. Other `env.hcl` version scalars

A handful of pins outside `chart_versions` follow the same "edit `env.hcl`, `terragrunt apply`" mechanic but aren't Helm charts:

- `velero_plugin_for_aws_version` — the AWS plugin `helm_release.velero` installs alongside the chart itself; check compatibility against the `velero` chart version being run before bumping independently.
- `postgres_version` — Keycloak's own hand-rolled Postgres `StatefulSet` image tag (`keycloak-infra`), not a chart.
- `whoami_version` — the sso-demo reference deployment's image tag.
- `cloudflared_version` — the hand-rolled `cloudflared` Deployment's image tag (`core-addons`, only relevant where `public_ingress_enabled = true`).
- `ksops_version` — the `ksops`/`kustomize` binary version ArgoCD's repo-server init container installs. Check compatibility against the ArgoCD version being run (`chart_versions.argocd`) before bumping independently — see [GitOps: App-of-Apps and Secrets](../explanation/gitops-app-of-apps.md).
- `cluster.talos_version` — **the riskiest pin in this repo.** This repo has no documented in-place Talos upgrade procedure — don't assume one is safe without testing it. The proven-safe path is what every major infra change here already uses: bump it on dev, run a full `terragrunt run --all destroy` + `apply` (a verified, repeatable procedure — see `CLAUDE.md`'s History), and confirm dev comes back healthy before ever touching prod's pin. Check [Talos releases](https://github.com/siderolabs/talos/releases) for what's new, and read the release notes for breaking changes before bumping, not after.

## 4. GitOps-managed app images (`apps/`)

Two different shapes here, patched differently:

- **Static Helm-template renders** — today just Immich (`apps/immich/immich.yaml`). This is a pinned `helm template` output committed as plain YAML, not a live Helm release (see [Immich](../explanation/immich.md) for why). Bumping the chart or app version means re-rendering the chart at the new version, then carefully re-applying this repo's placeholder tokens (`__APP_HOSTNAME__`, `__STORAGE_CLASS_CEPH__`, etc. — see [GitOps: App-of-Apps and Secrets](../explanation/gitops-app-of-apps.md)) into the fresh render by hand, since a plain re-render would overwrite them with real values. Diff carefully against the previous render before committing.
- **Hand-rolled Kustomize manifests with literal image tags** — every other real app, plus sidecars (Postgres/Redis for Paperless-ngx, changedetection.io's own separate oauth2-proxy). These live directly in each app's `base/*.yaml`, shared across environments by the `base/`/`overlays/<env>/` split, so one edit patches both dev and prod once promoted. Enumerate every current pin with:
  ```bash
  grep -rn "image:" apps/*/base/*.yaml
  ```
  This command — not a hardcoded list in this doc — is the source of truth for what needs checking, so this section doesn't need editing every time a new app under `apps/` lands. Check each image's registry (GHCR/Docker Hub) tags page or the project's GitHub releases for what's current, bump the literal tag, and re-verify that app's own functional check (see [Deployed Apps](../reference/deployed-apps.md) for what each app needs — an OIDC login, a working data write, etc.).

## 5. `mise.toml`-pinned CLI tools

```bash
mise outdated
```

lists every pinned tool with a newer version available. Bump the pin in `mise.toml`, run `mise install`. Remember `velero`'s lockstep requirement with `chart_versions.velero` (§2 above) — the one pin here that can't be bumped in isolation.

## 6. GitHub Actions versions (`.github/workflows/docs.yml`)

Five pinned actions: `actions/checkout`, `jdx/mise-action`, `actions/upload-artifact`, `peaceiris/actions-gh-pages`, `rossjrw/pr-preview-action`. Check each action's own GitHub releases page for its latest major/minor tag, bump the `@vX` reference. Low-risk relative to everything else in this doc (docs-only workflow, no cluster blast radius) — fine to batch into the same monthly sweep without extra caution.

---

## On automating this: Renovate, not Dependabot

Not adopted today — this is a recommendation for a future, separate decision, not something this doc's existence implies is already in place.

**Renovate over Dependabot** specifically because Dependabot only understands fixed ecosystems (npm, pip, Docker, GitHub Actions, basic Terraform provider blocks) — it has no way to detect a version bump embedded in a `chart_versions` HCL object, a raw Kustomize `image:` tag, or a `mise.toml` pin. Renovate's custom regex managers can be pointed at each of those exact patterns, and — once configured — would open PRs against `development`, fitting the two-stage pipeline directly: Renovate proposes, a normal dev-verify-then-promote cycle handles the rest.

What it wouldn't remove: the Talos upgrade risk (§3) and the Immich static-render re-templating step (§4) both need human judgment regardless of how the version bump itself is detected. And granting a bot repo write/PR-creation access is its own decision worth making deliberately, with the regex managers tested per file type before trusting its output — not something to bolt on casually.
