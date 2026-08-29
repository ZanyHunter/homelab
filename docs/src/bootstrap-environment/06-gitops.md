# 7. GitOps: App-of-Apps and Encrypted Secrets

ArgoCD is bootstrapped by Tofu (part of the `core-addons` unit, `tofu/modules/core-addons/main.tf` — see [Terragrunt Units](./10-terragrunt-units.md)), but the applications it manages live in git, under this repo's `apps/` directory, not in Tofu. This page documents how that wiring works and how to add to it.

---

## App-of-apps

An ArgoCD `ApplicationSet` (`helm_release.argocd_apps` in `tofu/modules/core-addons/main.tf`, installed via argo-helm's `argocd-apps` chart) watches `apps/*/overlays/<cluster_name>` in this repo at the revision pinned by `var.gitops.revision` (`main` for both clusters today) — `<cluster_name>` is `var.cluster_name` (`"dev"`/`"prod"`), so each environment's own ArgoCD only ever discovers its own overlay, never the other's, even though both read from the same git path. Its git directory generator turns each matching directory into its own ArgoCD `Application`. The generated name/namespace use `{{path[1]}}` (the app-name path segment, e.g. `actual` out of `apps/actual/overlays/dev`) rather than `{{path.basename}}` (which would resolve to `dev`/`prod` here), synced automatically (`prune` + `selfHeal`).

### The `base/` + `overlays/<env>/` structure

Every directory under `apps/` (including `apps/cluster-addons/`) is split into:

- `base/` — the actual manifests, environment-agnostic. Anywhere a value differs by environment (a hostname, a StorageClass name, a MetalLB IP range), the base file has an obviously-fake placeholder token instead (`__APP_HOSTNAME__`, `__KEYCLOAK_HOSTNAME__`, `__STORAGE_CLASS_CEPH__`, `__STORAGE_CLASS_NFS__`) rather than a real value.
- `overlays/<env>/` — one per environment (`dev`, `prod` today), each just two small files: `env-values.yaml` (a plain `ConfigMap` holding that environment's real values — the *only* place the real value is written down for that app) and `kustomization.yaml` (`resources: [../../base, env-values.yaml]` plus a `replacements:` block wiring each `ConfigMap` key to the base files' placeholder tokens).

This exists specifically to avoid duplicating whole manifests per environment — `overlays/<env>/` is a handful of lines, not a second copy of the app. See "Environment-specific values" below for exactly how the substitution works and why `replacements:` (not raw `patches:`) is the mechanism.

**To add a new app**: create `apps/my-app/base/` with a `kustomization.yaml` (and whatever manifests/generators it needs, using placeholder tokens for anything environment-specific) plus one `apps/my-app/overlays/<env>/` **per existing environment** (today: `dev` and `prod`, even though prod is unapplied scaffolding — see [Terragrunt Units](./10-terragrunt-units.md)). Commit and push. No Tofu change, no `kubectl apply`, no `argocd app create` — the next time each cluster's ApplicationSet generator runs, a new `Application` named `my-app` appears there and syncs on its own.

**To add a new environment** (e.g. a real prod, or a third environment down the line): this is the one place the base/overlays split creates real fan-out — add an `overlays/<new-env>/` to **every** directory under `apps/` (seven today: `cluster-addons`, `actual`, `paperless`, `vaultwarden`, `inventory`, `changedetection`, `immich`), not just a single config file. There's no automation catching a missed one — a forgotten `overlays/<new-env>/` just means that one app's `Application` never appears on the new cluster. Cross-check against `apps/*/overlays/` (a directory listing) when standing up a new environment, not memory.

**Removing an app** works the same way in reverse, with one caveat: the ApplicationSet's `preserveResourcesOnDeletion` is set to `true`, specifically so a renamed directory or a transient git-generator hiccup can't cascade-delete live resources (the `Application` object gets pruned, but whatever it was managing — Deployments, the MetalLB pool, ClusterIssuers, etc. — is left running, orphaned, until a matching `Application` reappears and re-adopts it). If you're decommissioning an app for real, clean up its resources explicitly (e.g. `kubectl delete namespace <app>`) rather than assuming removing the directory will do it.

`apps/cluster-addons/` is the one directory that predates any "real" application — it holds cluster-level objects (the MetalLB `IPAddressPool`/`L2Advertisement`, the `letsencrypt-prod`/`letsencrypt-staging` `ClusterIssuer`s) that used to be applied by Tofu via `terraform_data` + `local-exec` provisioners shelling out to `kubectl`. Those provisioners are gone; this is where that configuration lives now — and it gets the same `base/`/`overlays/<env>/` split as every real app, since its MetalLB `IPAddressPool` range is itself environment-specific.

## Environment-specific values

Every app has at least one value that legitimately differs per environment — its own external hostname, at minimum, plus (for most apps) a Ceph and/or NFS StorageClass name suffixed by cluster (`ceph-rbd-dev` vs `ceph-rbd-prod`, per [Ceph-Backed Storage](./13-ceph-storage.md)'s naming convention). Kustomize deliberately has no general templating/string-concatenation language (that's Helm's job, not Kustomize's) — the two real levers it gives you are `patches:` (verbose: one explicit op per field, repeating the literal value every time) and `replacements:` (used here: the real value is written down exactly once per environment, in that environment's `env-values.yaml`, and copied into every field that needs it).

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

This same mechanism reaches values embedded inside a ksops-encrypted `Secret` — `replacements:` operates on the fully-built (decrypted) resource list, after the `ksops` generator has already produced the real `Secret` object, so it doesn't matter whether the target field came from a plain YAML file or a generator. Immich's `issuerUrl` and Paperless-ngx's `PAPERLESS_SOCIALACCOUNT_PROVIDERS` JSON blob (a value nested inside a single string field) both get their embedded Keycloak hostname swapped this same way — for the JSON case, the *entire* JSON string is still just one `/`-delimited value as far as `replacements:` is concerned, so the same delimiter/index approach works even though the surrounding text is JSON, not a bare URL.

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

**To add a new encrypted secret for an app**:

1. Write the plaintext manifest (a `Secret`, or any resource with a sensitive field) somewhere temporary, *not* under `apps/`. If any field is environment-specific (a Keycloak issuer URL, say), use a placeholder token as described above — encryption doesn't change how `replacements:` reaches this file.
2. Copy it into place under your app's `base/` directory with an `.enc.yaml` suffix, e.g. `apps/my-app/base/db-credentials.enc.yaml`.
3. Encrypt it in place: `sops -e -i apps/my-app/base/db-credentials.enc.yaml` (run from the repo root, so the path matches `.sops.yaml`'s `apps/.*\.enc\.yaml$` rule).
4. Reference it from a `ksops` generator in the same directory:

   ```yaml
   apiVersion: viaduct.ai/v1
   kind: ksops
   metadata:
     name: my-app-secrets
     annotations:
       config.kubernetes.io/function: |
         exec:
           path: ksops
   files:
     - ./db-credentials.enc.yaml
   ```

5. Add that generator to the directory's `kustomization.yaml`:

   ```yaml
   generators:
     - ksops-generator.yaml
   ```

`.sops.yaml`'s rule for `apps/.*\.enc\.yaml$` only encrypts keys named `data`, `stringData`, or `email` — everything else in the manifest (the resource's `kind`, `metadata.name`, non-sensitive `spec` fields) stays plaintext and human-reviewable in git. `email` is there specifically for cert-manager's `ClusterIssuer`, which has no `secretRef` indirection for its ACME registration email — see `apps/cluster-addons/base/letsencrypt-prod-issuer.enc.yaml` for a worked example of a mostly-plaintext manifest with one encrypted leaf. If a new kind of genuinely sensitive field shows up in some other resource later, extend that regex rather than leaving it in plaintext.

### Verifying the pipeline end-to-end

There's no permanent canary secret sitting in the cluster for this — it was validated once, live, while wiring this up (a throwaway `Secret` under a temporary `apps/ksops-smoke-test/` directory, confirmed to sync healthy and decrypt correctly, then removed). To re-verify after an ArgoCD or ksops version bump, the fastest check is:

```bash
kubectl get applications -n argocd
kubectl get clusterissuers
```

Both `letsencrypt-prod` and `letsencrypt-staging` should show `READY: True` — an ACME `ClusterIssuer` only reaches `Ready` after successfully registering an account with the ACME server using the decrypted `email`, which is a strong end-to-end signal that ksops decryption is working, not just that the manifest applied.
