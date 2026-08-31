# GitOps: App-of-Apps and Secrets

ArgoCD is bootstrapped by Tofu (part of the `core-addons` unit, `tofu/modules/core-addons/main.tf` — see [Terragrunt Units](./terragrunt-units.md)), but the applications it manages live in git, under this repo's `apps/` directory, not in Tofu. This page documents how that wiring works. For the actual step-by-step procedures (adding a new app, a new environment, a new encrypted secret), see the [Onboard a New App](../guides/onboard-a-new-app.md) and [Stand Up a New Environment](../guides/stand-up-a-new-environment.md) guides.

---

## App-of-apps

An ArgoCD `ApplicationSet` (`helm_release.argocd_apps` in `tofu/modules/core-addons/main.tf`, installed via argo-helm's `argocd-apps` chart) watches `apps/*/overlays/<cluster_name>` in this repo at the revision pinned by `var.gitops.revision` — `<cluster_name>` is `var.cluster_name` (`"dev"`/`"prod"`), so each environment's own ArgoCD only ever discovers its own overlay, never the other's, even though both read from the same git path. Since the two-stage promotion pipeline (#51, see `CLAUDE.md`'s Git workflow section), dev and prod deliberately pin *different* revisions: dev tracks the persistent `development` branch, prod tracks `main` — a change only reaches prod's ArgoCD once its `development → main` promotion PR merges, giving every change a real window validated live on dev before it can touch prod. Its git directory generator turns each matching directory into its own ArgoCD `Application`. The generated name/namespace use `{{path[1]}}` (the app-name path segment, e.g. `actual` out of `apps/actual/overlays/dev`) rather than `{{path.basename}}` (which would resolve to `dev`/`prod` here), synced automatically (`prune` + `selfHeal`).

### The `base/` + `overlays/<env>/` structure

Every directory under `apps/` (including `apps/cluster-addons/`) is split into:

- `base/` — the actual manifests, environment-agnostic. Anywhere a value differs by environment (a hostname, a StorageClass name, a MetalLB IP range), the base file has an obviously-fake placeholder token instead (`__APP_HOSTNAME__`, `__KEYCLOAK_HOSTNAME__`, `__STORAGE_CLASS_CEPH__`, `__STORAGE_CLASS_NFS__`) rather than a real value.
- `overlays/<env>/` — one per environment (`dev`, `prod` today), each just two small files: `env-values.yaml` (a plain `ConfigMap` holding that environment's real values — the *only* place the real value is written down for that app) and `kustomization.yaml` (`resources: [../../base, env-values.yaml]` plus a `replacements:` block wiring each `ConfigMap` key to the base files' placeholder tokens).

This exists specifically to avoid duplicating whole manifests per environment — `overlays/<env>/` is a handful of lines, not a second copy of the app. See "Environment-specific values" below for exactly how the substitution works and why `replacements:` (not raw `patches:`) is the mechanism. See the [Onboard a New App](../guides/onboard-a-new-app.md) guide for the checklist to add a new app, and [Stand Up a New Environment](../guides/stand-up-a-new-environment.md) for adding a new `overlays/<env>/` across every existing app.

**Removing an app** has one caveat worth knowing: the ApplicationSet's `preserveResourcesOnDeletion` is set to `true`, specifically so a renamed directory or a transient git-generator hiccup can't cascade-delete live resources (the `Application` object gets pruned, but whatever it was managing — Deployments, the MetalLB pool, ClusterIssuers, etc. — is left running, orphaned, until a matching `Application` reappears and re-adopts it). If decommissioning an app for real, clean up its resources explicitly (e.g. `kubectl delete namespace <app>`) rather than assuming removing the directory will do it.

`apps/cluster-addons/` is the one directory that predates any "real" application — it holds cluster-level objects (the MetalLB `IPAddressPool`/`L2Advertisement`, the `letsencrypt-prod`/`letsencrypt-staging` `ClusterIssuer`s) that used to be applied by Tofu via `terraform_data` + `local-exec` provisioners shelling out to `kubectl`. Those provisioners are gone; this is where that configuration lives now — and it gets the same `base/`/`overlays/<env>/` split as every real app, since its MetalLB `IPAddressPool` range is itself environment-specific.

## Environment-specific values

Every app has at least one value that legitimately differs per environment — its own external hostname, at minimum, plus (for most apps) a Ceph and/or NFS StorageClass name suffixed by cluster (`ceph-rbd-dev` vs `ceph-rbd-prod`, per [Ceph-Backed Storage](./ceph-backed-storage.md)'s naming convention). Kustomize deliberately has no general templating/string-concatenation language (that's Helm's job, not Kustomize's) — the two real levers it gives you are `patches:` (verbose: one explicit op per field, repeating the literal value every time) and `replacements:` (used here: the real value is written down exactly once per environment, in that environment's `env-values.yaml`, and copied into every field that needs it).

**The trick that keeps this minimal**: base files keep their real, correct structure — including any static suffix (`/realms/homelab`, `/oauth2/callback`) — with *only* the hostname segment itself replaced by a placeholder token, e.g. `value: https://__APP_HOSTNAME__/oauth2/callback`. `replacements:`' `options.delimiter`/`index` (splitting the target string on `/` and touching only one indexed segment) then substitutes just that token, leaving everything else in the string untouched:

```yaml
# overlays/dev/kustomization.yaml
replacements:
  - source:
      kind: ConfigMap
      name: env-values
      fieldPath: data.app-hostname
    targets:
      - select:
          kind: Deployment
          name: my-app
        fieldPaths:
          - spec.template.spec.containers.0.env.[name=SOME_URL].value
        options:
          delimiter: "/"
          index: 2 # "https:" "" "__APP_HOSTNAME__" "oauth2" "callback" -> index 2
```

A bare hostname field (an Ingress `host`, or `HBOX_OPTIONS_HOSTNAME`, which — unlike most of these apps' OIDC env vars — takes a scheme-less hostname) needs no `options:` at all; a whole-value replace is correct since there's nothing else in the string to preserve.

This same mechanism reaches values embedded inside a ksops-encrypted `Secret` or an `ExternalSecret`'s rendered template — `replacements:` operates on the fully-built resource list, after any generator has already produced the real object, so it doesn't matter whether the target field came from a plain YAML file or a generator, or whether the target `kind` is `Secret` or `ExternalSecret`. Immich's `issuerUrl` and Paperless-ngx's `PAPERLESS_SOCIALACCOUNT_PROVIDERS` JSON blob (a value nested inside a single string field) both get their embedded Keycloak hostname swapped this same way — for the JSON case, the *entire* JSON string is still just one `/`-delimited value as far as `replacements:` is concerned, so the same delimiter/index approach works even though the surrounding text is JSON, not a bare URL.

### Verifying a build without a live ArgoCD sync

Local Bash sessions in this repo don't have `kustomize`/`ksops` installed (only ArgoCD's repo-server does, via `helm_release.argocd`'s init container). To check a `kustomization.yaml`/`replacements:` change actually builds correctly — and, critically, that ksops can still decrypt through it — before pushing:

```bash
POD=$(kubectl get pods -n argocd -l app.kubernetes.io/name=argocd-repo-server -o jsonpath='{.items[0].metadata.name}')
kubectl cp apps/ argocd/"$POD":/tmp/test-build -c repo-server
kubectl exec -n argocd "$POD" -c repo-server -- \
  kustomize build --enable-alpha-plugins --enable-exec /tmp/test-build/apps/my-app/overlays/dev
kubectl exec -n argocd "$POD" -c repo-server -- rm -rf /tmp/test-build
```

This uses the exact same binaries (and the exact same in-cluster age key) ArgoCD itself uses at sync time — a stronger check than anything a local `kustomize`/`sops` install could give, and the only way to test the ksops decryption path without actually syncing.

## ksops: encrypted manifests under apps/

ArgoCD's repo-server has [ksops](https://github.com/viaduct-ai/kustomize-sops) installed (patched in via `helm_release.argocd`'s values in `tofu/modules/core-addons/main.tf`: an init container copies the `ksops`/`kustomize` binaries into the repo-server, overriding the built-in `kustomize`), and is handed the same age private key already used for `tofu/secrets.enc.yaml` (mounted from a `kubernetes_secret.sops_age_key`, itself sourced from `~/.config/sops/age/keys.txt` — see `CLAUDE.md`'s "Secrets management"). This means any `kustomization.yaml` under `apps/` can reference a `ksops` generator to decrypt SOPS-encrypted files at sync time, the same way `tofu/secrets.enc.yaml` gets decrypted at plan time.

`.sops.yaml`'s rule for `apps/.*\.enc\.yaml$` only encrypts keys named `data`, `stringData`, or `email` — everything else in the manifest (the resource's `kind`, `metadata.name`, non-sensitive `spec` fields) stays plaintext and human-reviewable in git. `email` is there specifically for cert-manager's `ClusterIssuer`, which has no `secretRef` indirection for its ACME registration email — see `apps/cluster-addons/base/letsencrypt-prod-issuer.enc.yaml` for a worked example of a mostly-plaintext manifest with one encrypted leaf. If a new kind of genuinely sensitive field shows up in some other resource later, extend that regex rather than leaving it in plaintext. See the [Onboard a New App](../guides/onboard-a-new-app.md) guide for the exact steps to add a new encrypted secret.

### Verifying the pipeline end-to-end

There's no permanent canary secret sitting in the cluster for this — it was validated once, live, while wiring this up (a throwaway `Secret` under a temporary `apps/ksops-smoke-test/` directory, confirmed to sync healthy and decrypt correctly, then removed). To re-verify after an ArgoCD or ksops version bump, the fastest check is:

```bash
kubectl get applications -n argocd
kubectl get clusterissuers
```

Both `letsencrypt-prod` and `letsencrypt-staging` should show `READY: True` — an ACME `ClusterIssuer` only reaches `Ready` after successfully registering an account with the ACME server using the decrypted `email`, which is a strong end-to-end signal that ksops decryption is working, not just that the manifest applied.

## ExternalSecrets: for values Tofu also generates (#42)

ksops is the right mechanism for any secret with no other source of truth — a Postgres password, an admin token, a cookie secret. It's the *wrong* mechanism for a value Tofu also independently generates and needs to keep matching, like a Keycloak OIDC client's `client_secret` (`random_password.*_client_secret` in `tofu/modules/keycloak-realm/main.tf`): a ksops-encrypted copy is a snapshot, not a live link, so a `keycloak-realm` destroy/recreate or a deliberate secret rotation regenerates the Tofu-side value with nothing updating the already-committed file — OIDC login for that app breaks silently until someone notices.

**[External Secrets Operator](https://external-secrets.io/)** (`helm_release.external_secrets` in `tofu/modules/core-addons/main.tf`) closes this gap for exactly that subset of secrets, without introducing Vault or any new secrets-store *service* — its `kubernetes` provider just mirrors a Kubernetes Secret that already exists in one namespace out into another. The pattern mirrors this repo's existing "Tofu owns secret material + the namespace holding it, GitOps owns everything else" split:

- **Tofu (`core-addons`)** owns the `keycloak-secrets` namespace itself (created early, alongside ArgoCD); **Tofu (`keycloak-realm`)** populates it with one plain `kubernetes_secret` per app, each with that app's live Keycloak client secret — the same shape as this unit's pre-existing `kubernetes_secret.oauth2_proxy_credentials` (the sso-demo forward-auth demo), just multiplied across the six real apps that need it. See "Bootstrap ordering gotchas" below for why the namespace itself lives in a different unit than the Secrets populating it.
- **GitOps (`apps/cluster-addons/base/`)** owns the RBAC (`ServiceAccount`/`Role`/`RoleBinding`, read-only on Secrets in `keycloak-secrets` only) and a `ClusterSecretStore` pointing at it — no secret material in either, so no ksops encryption needed, same as the MetalLB `IPAddressPool`/`ClusterIssuer`s already living there.
- **GitOps (`apps/<app>/base/`)** owns an `ExternalSecret` per app, replacing (or partially replacing) the ksops file that used to hold the client secret:

  ```yaml
  apiVersion: external-secrets.io/v1
  kind: ExternalSecret
  metadata:
    name: actual-oidc-credentials
    namespace: actual
  spec:
    refreshInterval: 1h
    secretStoreRef:
      name: keycloak-secrets
      kind: ClusterSecretStore
    target:
      name: actual-oidc-credentials
    data:
      - secretKey: client-secret
        remoteRef:
          key: actual-oidc-client-secret
          property: client-secret
  ```

**When a Secret co-locates a Tofu-generated key with one that has no Tofu counterpart** (e.g. Vaultwarden's `sso-client-secret` next to its `admin-token`), it's split into two Secret objects rather than trying to make one mechanism own both: the Tofu-sourced key moves to a new `ExternalSecret`-produced Secret, the rest stays in a shrunk ksops file. The *original* Secret name stays on whichever side keeps more keys, to minimize `secretKeyRef.name` edits in the Deployment.

**When the secret is nested inside a larger structured document** (Immich's `immich-config.yaml`, Paperless-ngx's `PAPERLESS_SOCIALACCOUNT_PROVIDERS` JSON blob), `spec.target.template` renders the whole document as a Go template, interpolating just the live field:

```yaml
target:
  name: immich-config
  template:
    engineVersion: v2
    data:
      immich-config.yaml: |
        oauth:
          issuerUrl: "https://__KEYCLOAK_HOSTNAME__/realms/homelab"
          clientSecret: "{{ .clientSecret }}"
data:
  - secretKey: clientSecret
    remoteRef:
      key: immich-oidc-client-secret
      property: client-secret
```

This has a nice side effect for Immich specifically: the old ksops file encrypted the *entire* config document even though only one field was ever sensitive — the template makes everything else plain, reviewable YAML.

**Verifying**: the repo-server `kustomize build` technique above only confirms the YAML is well-formed Kustomize input for an `ExternalSecret` — there's no decryption step to prove anymore, so it's a weaker check than it is for ksops. The real proof is live: `kubectl get externalsecret -n <app>` should show `STATUS: SecretSynced`, `READY: True`, and the resulting Secret's value should match `terragrunt output -raw <app>_oidc_client_secret` exactly (that Tofu output still exists for exactly this kind of break-glass check, even though nothing needs to hand-carry it anymore).

## Bootstrap ordering gotchas (#44)

A real, fully unattended `terragrunt run --all destroy` + `apply` cycle of dev (as opposed to the incremental applies this environment normally sees) surfaced three genuine ordering/lifecycle bugs, none caught by the original Terragrunt-refactor destroy/recreate proof (#21/#26) or the #42 ExternalSecrets verification, because neither happened to exercise these exact races.

**Namespaces a GitOps `Application` and a Tofu unit both touch must be Tofu-created, not `CreateNamespace=true`-created.** Two namespaces hit this: `cluster-addons` (its own `Application`'s RBAC/`ClusterSecretStore`/`ClusterIssuer`s) and `keycloak-secrets` (the 6 real apps' `ExternalSecret`s' `ClusterSecretStore` target). Both used to rely on ArgoCD's `CreateNamespace=true` sync option creating the namespace before any Tofu-managed NetworkPolicy or RBAC referencing it applied — true on every previously-live cluster (ArgoCD had long since synced by the time anyone looked), false on a genuine from-scratch apply, where `core-addons`'s own apply (which installs ArgoCD) can easily finish *before* ArgoCD has synced anything at all. `keycloak-secrets` had an added wrinkle: even once it was made Tofu-managed, it was created by `keycloak-realm` — the *last* of `core-addons`' four dependents to apply, often minutes after ArgoCD is already up and syncing `apps/cluster-addons/`'s RBAC against that same namespace name. Both namespaces are now created directly in `core-addons` (`kubernetes_namespace.cluster_addons`/`kubernetes_namespace.keycloak_secrets`, `tofu/modules/core-addons/main.tf`), applied early alongside ArgoCD itself — `keycloak-realm` still populates the real Secret *values* into `keycloak-secrets`, just referencing it by name via a new `core_addons` output (`keycloak_secrets_namespace`) rather than owning the namespace resource. `CreateNamespace=true` stays in the shared `ApplicationSet` template regardless — a harmless no-op once Tofu already owns the namespace, and removing it would mean special-casing one app out of the template every other app shares. As defense in depth, the template's per-`Application` `retry` policy was also raised well above ArgoCD's default (5 attempts, short backoff) — a future namespace/CRD/RBAC race of this same shape now self-heals instead of needing a manual forced sync.

**A Helm chart that bundles its own CRDs as regular templates (not the protected `crds/` folder) will delete them on `helm uninstall`, which can deadlock if any live CR instance's finalizer can only be cleared by the controller being uninstalled in the same operation.** `external-secrets` is exactly this shape: its CRDs live under `templates/crds/`, gated by its own `installCRDs` value, not Helm's special folder. A real full destroy hit this directly — deleting the `ExternalSecret` CRD blocks until every CR instance is gone, but the 6 GitOps-managed `ExternalSecret` objects each carry ESO's own cleanup finalizer, removable only by ESO's own controller, which was being torn down in the very same `helm uninstall`. Fixed by decoupling CRD lifecycle from the Helm release entirely: `helm_release.external_secrets` now sets `installCRDs = false`, and the CRDs are applied once via a plain `kubectl apply --server-side` that a create-only `null_resource.external_secrets_crds` local-exec provisioner runs (no destroy-time provisioner, so a `terraform destroy` just drops it from state without ever touching the live CRDs). The provisioner needs its own throwaway kubeconfig — a Terraform provisioner's shell can't reach the `kubernetes`/`helm` providers' own authenticated session — built inline from `var.kubernetes_client_configuration`, the same connection details those providers already receive via the Terragrunt-generated `provider.tf`. `files/external-secrets-crds.yaml` is a pinned `helm template` render of the chart's own `templates/crds/`, the same "committed static render" idiom `apps/immich/immich.yaml` already uses — regenerate it by hand whenever `chart_versions.external_secrets` bumps. The full render is ~33,000 lines (two of the CRD's own schemas — `SecretStore`/`ClusterSecretStore` — account for most of that; the rest is unused generator/pushsecret CRD types), kept as-is: it's a pinned upstream artifact, not hand-maintained, and the chart's own finer-grained `crds.createX` toggles turned out to be inconsistently wired (most generator-type CRDs are gated only by the blanket `installCRDs`, with no working per-type opt-out), so there's no clean way to trim it that stays a genuine, reproducible chart render.

  **Migrating an already-live cluster onto this fix is not zero-risk** (a genuinely fresh bootstrap never hits this): flipping `installCRDs` from its implicit `true` default to `false` on an *existing* Helm release causes that upgrade itself to prune the CRDs Helm was already tracking — the exact same finalizer-cascade deadlock class this fix exists to prevent, just triggered by `helm upgrade` instead of `helm uninstall`. Hit live while rolling this out to dev: the upgrade briefly deleted all 25 CRDs, cascading away every `ExternalSecret`/`ClusterSecretStore` instance and the Secrets ESO had generated from them. Recovered by immediately re-applying `files/external-secrets-crds.yaml` directly via `kubectl apply`, then forcing an ArgoCD resync (`kubectl patch application <name> -n argocd --type=merge -p '{"operation":{"sync":{"syncStrategy":{"hook":{}}}}}'`) and an ESO force-resync (`kubectl annotate externalsecret -n <ns> <name> force-sync=$(date +%s) --overwrite`) on each of the 6 `ExternalSecret`s — no data loss, since the canonical Secret *values* Tofu manages in `keycloak-secrets` were never touched, only their mirrored copies. A future from-scratch bootstrap never has an existing Helm-tracked CRD to prune in the first place, so it doesn't hit this transition cost at all.

**A fresh bootstrap can also show a transient `SecretSyncedError` on most `ExternalSecret`s that self-heals within minutes, with no manual intervention needed.** ArgoCD syncs every app's `ExternalSecret` early in the apply, but `keycloak-realm` — the last unit in the Terragrunt DAG — hasn't necessarily written the target Secret values into `keycloak-secrets` yet. Confirmed live on a real destroy/apply round-trip: 5 of 6 `ExternalSecret`s sat in `SecretSyncedError` for roughly 10 minutes post-apply, and one dependent pod (`immich-server`) sat in a stale `ContainerCreating`/`FailedMount` as a result — both resolved on their own, via ESO's own reconcile backoff and kubelet's normal mount-retry behavior respectively, well within issue #44's "no permanently-stuck resource" acceptance bar. Worth knowing about so it isn't mistaken for a real failure mid-bootstrap; a future tightening of ESO's own retry/reconcile flags could shorten this window, but it isn't currently tracked as a problem to fix.

**What ESO can actually reach**: its `ClusterSecretStore`'s RBAC scopes it to read-only on Secrets in the `keycloak-secrets` namespace and nowhere else — it has no access to `tofu/secrets.enc.yaml`, no access to any other namespace's Secrets, and no ability to write anything back into `keycloak-secrets`. See `CLAUDE.md`'s Secrets management section.
