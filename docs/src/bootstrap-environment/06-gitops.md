# 7. GitOps: App-of-Apps and Encrypted Secrets

ArgoCD is bootstrapped by Tofu (part of the `core-addons` unit, `tofu/modules/core-addons/main.tf` — see [Terragrunt Units](./10-terragrunt-units.md)), but the applications it manages live in git, under this repo's `apps/` directory, not in Tofu. This page documents how that wiring works and how to add to it.

---

## App-of-apps

An ArgoCD `ApplicationSet` (`helm_release.argocd_apps` in `tofu/modules/core-addons/main.tf`, installed via argo-helm's `argocd-apps` chart) watches `apps/*` in this repo at the revision pinned by `var.gitops.revision` (`main` for the `dev` cluster). Its git directory generator turns each direct subdirectory of `apps/` into its own ArgoCD `Application`, named after the directory, synced automatically (`prune` + `selfHeal`) into a same-named namespace.

**To add a new app**: create a new directory under `apps/`, e.g. `apps/my-app/`, with a `kustomization.yaml` (and whatever manifests/generators it needs) at its root. Commit and push. No Tofu change, no `kubectl apply`, no `argocd app create` — the next time the ApplicationSet's generator runs (or immediately, since ArgoCD also reacts to webhook/poll events), a new `Application` named `my-app` appears and syncs on its own.

**Removing an app** works the same way in reverse, with one caveat: the ApplicationSet's `preserveResourcesOnDeletion` is set to `true`, specifically so a renamed directory or a transient git-generator hiccup can't cascade-delete live resources (the `Application` object gets pruned, but whatever it was managing — Deployments, the MetalLB pool, ClusterIssuers, etc. — is left running, orphaned, until a matching `Application` reappears and re-adopts it). If you're decommissioning an app for real, clean up its resources explicitly (e.g. `kubectl delete namespace <app>`) rather than assuming removing the directory will do it.

`apps/cluster-addons/` is the one directory that predates any "real" application — it holds cluster-level objects (the MetalLB `IPAddressPool`/`L2Advertisement`, the `letsencrypt-prod`/`letsencrypt-staging` `ClusterIssuer`s) that used to be applied by Tofu via `terraform_data` + `local-exec` provisioners shelling out to `kubectl`. Those provisioners are gone; this is where that configuration lives now.

## ksops: encrypted manifests under apps/

ArgoCD's repo-server has [ksops](https://github.com/viaduct-ai/kustomize-sops) installed (patched in via `helm_release.argocd`'s values in `tofu/modules/core-addons/main.tf`: an init container copies the `ksops`/`kustomize` binaries into the repo-server, overriding the built-in `kustomize`), and is handed the same age private key already used for `tofu/secrets.enc.yaml` (mounted from a `kubernetes_secret.sops_age_key`, itself sourced from `~/.config/sops/age/keys.txt` — see `CLAUDE.md`'s "Secrets management"). This means any `kustomization.yaml` under `apps/` can reference a `ksops` generator to decrypt SOPS-encrypted files at sync time, the same way `tofu/secrets.enc.yaml` gets decrypted at plan time.

**To add a new encrypted secret for an app**:

1. Write the plaintext manifest (a `Secret`, or any resource with a sensitive field) somewhere temporary, *not* under `apps/`.
2. Copy it into place under your app's directory with an `.enc.yaml` suffix, e.g. `apps/my-app/db-credentials.enc.yaml`.
3. Encrypt it in place: `sops -e -i apps/my-app/db-credentials.enc.yaml` (run from the repo root, so the path matches `.sops.yaml`'s `apps/.*\.enc\.yaml$` rule).
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

`.sops.yaml`'s rule for `apps/.*\.enc\.yaml$` only encrypts keys named `data`, `stringData`, or `email` — everything else in the manifest (the resource's `kind`, `metadata.name`, non-sensitive `spec` fields) stays plaintext and human-reviewable in git. `email` is there specifically for cert-manager's `ClusterIssuer`, which has no `secretRef` indirection for its ACME registration email — see `apps/cluster-addons/letsencrypt-prod-issuer.enc.yaml` for a worked example of a mostly-plaintext manifest with one encrypted leaf. If a new kind of genuinely sensitive field shows up in some other resource later, extend that regex rather than leaving it in plaintext.

### Verifying the pipeline end-to-end

There's no permanent canary secret sitting in the cluster for this — it was validated once, live, while wiring this up (a throwaway `Secret` under a temporary `apps/ksops-smoke-test/` directory, confirmed to sync healthy and decrypt correctly, then removed). To re-verify after an ArgoCD or ksops version bump, the fastest check is:

```bash
kubectl get applications -n argocd
kubectl get clusterissuers
```

Both `letsencrypt-prod` and `letsencrypt-staging` should show `READY: True` — an ACME `ClusterIssuer` only reaches `Ready` after successfully registering an account with the ACME server using the decrypted `email`, which is a strong end-to-end signal that ksops decryption is working, not just that the manifest applied.
