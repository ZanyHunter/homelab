# Onboard a New App

Adding a new self-hosted app under `apps/` end-to-end: Keycloak login, the app's manifests, its secrets, and getting it synced by ArgoCD. Immich and the five apps in [Self-Hosted Apps](../explanation/self-hosted-apps.md) are the real worked examples referenced throughout — copy their shape for the next app rather than starting from a blank file. See [GitOps: App-of-Apps and Secrets](../explanation/gitops-app-of-apps.md) for why any of this works the way it does.

---

## 1. Decide: native OIDC, or forward-auth?

Most apps have their own OIDC support — configure them directly against the Keycloak realm, no proxy needed. If the app has no OIDC/SSO support at all (changedetection.io is the only example today), it needs the `oauth2-proxy` forward-auth pattern instead. Check the app's own docs first; don't assume forward-auth is needed without confirming there's genuinely no native option.

## 2. Create the Keycloak client

**Native OIDC apps**: add a new `keycloak_openid_client` resource in `tofu/modules/keycloak-realm/main.tf` — copy `keycloak_openid_client.immich` as a starting point (`access_type = "CONFIDENTIAL"`, `standard_flow_enabled = true`, and the app's actual callback URL(s) in `valid_redirect_uris`). Issuer URL the app needs to be configured with:

{{#tabs global="domain" }}
{{#tab name="Production" }}
`https://keycloak.thepugh.family/realms/homelab`
{{#endtab }}
{{#tab name="Development" }}
`https://keycloak.dev.thepugh.family/realms/homelab`
{{#endtab }}
{{#endtabs }}

If the app needs to know who's a platform admin (e.g. to grant a superuser role, the way Paperless-ngx does), attach the reusable `groups` optional client scope (`keycloak_openid_client_optional_scopes`) the same way ArgoCD/Grafana/Paperless do, and have the app request it.

**Forward-auth apps**: copy the `oauth2-proxy` + Ingress `auth-url`/`auth-signin` pattern from `tofu/modules/keycloak-realm/main.tf`'s `helm_release.oauth2_proxy` and `kubernetes_ingress_v1.whoami` (the `sso-demo` reference deployment) — `apps/changedetection/base/oauth2-proxy.yaml` is the real worked example, copied as plain Kustomize manifests rather than a second Tofu-managed Helm release (that stays specific to the demo). Still needs its own `keycloak_openid_client` with an explicit `client_secret = random_password....result`, same as a native-OIDC app. Two things to get right:

- One oauth2-proxy per protected app (or a shared one, only if several apps can tolerate a shared session cookie domain).
- The Ingress needs `nginx.ingress.kubernetes.io/proxy-buffer-size: "16k"` — oauth2-proxy's session cookie bundles Keycloak's access/ID/refresh tokens, which routinely exceeds ingress-nginx's default proxy buffer and 502s on `/oauth2/callback` otherwise.

## 3. Get the client secret into the app's namespace

No manual `terragrunt output -raw` + hand-carry step (#42) — the secret reaches the app automatically via ExternalSecrets Operator:

1. In `tofu/modules/keycloak-realm/main.tf`, add one `kubernetes_secret` in the `keycloak-secrets` namespace holding the new client's secret — copy one of the six existing examples (e.g. `kubernetes_secret.actual_oidc_client_secret`).
2. Under `apps/<app>/base/`, add an `ExternalSecret` pulling that value into the app's own namespace. The exact shape depends on where the secret needs to land:
   - **A standalone key** (most apps): see [GitOps: App-of-Apps and Secrets](../explanation/gitops-app-of-apps.md#externalsecrets-for-values-tofu-also-generates-42) for the plain `ExternalSecret` shape.
   - **Nested inside a larger config document** (Immich's `immich-config.yaml`, Paperless's `PAPERLESS_SOCIALACCOUNT_PROVIDERS` JSON): use `spec.target.template` to render the whole document, interpolating just the secret field — same link above has the worked example.
   - **Co-located with a secret that has no Tofu counterpart** (an admin token, a cookie secret): split into two Secret objects — the Tofu-sourced key into a new `ExternalSecret`-produced Secret, the rest into a shrunk ksops file (see step 5). Keep the *original* Secret name on whichever side keeps more keys, to minimize `secretKeyRef.name` edits in the app's Deployment.
3. A sensitive Tofu output for the client secret is still worth adding to `tofu/modules/keycloak-realm/outputs.tf` (following `immich_oidc_client_secret`'s pattern) — kept for break-glass/debugging only, nothing needs to read it during normal operation.

## 4. Scaffold the app's manifests

Create `apps/my-app/base/` with a `kustomization.yaml` and whatever manifests the app needs. Anywhere a value differs by environment (hostname, StorageClass name), use a placeholder token instead of a real value (`__APP_HOSTNAME__`, `__KEYCLOAK_HOSTNAME__`, `__STORAGE_CLASS_CEPH__`, `__STORAGE_CLASS_NFS__`).

Then create `apps/my-app/overlays/<env>/` **for every environment that currently exists** (today: `dev` and `prod`, even though prod is unapplied scaffolding) — each just `env-values.yaml` (a `ConfigMap` of that environment's real values) and `kustomization.yaml` (`resources: [../../base, env-values.yaml]` plus a `replacements:` block wiring each value to its placeholder token). See [GitOps: App-of-Apps and Secrets](../explanation/gitops-app-of-apps.md#environment-specific-values) for exactly how `replacements:` works.

Set `enableServiceLinks: false` on every pod spec — Kubernetes auto-injects Docker-links-style `<SVCNAME>_PORT` env vars per Service in the namespace, which has genuinely collided with an app's own same-named config key before (see [Self-Hosted Apps](../explanation/self-hosted-apps.md)'s Actual Budget gotcha).

Commit and push. No Tofu change, no `kubectl apply`, no `argocd app create` — the next time each cluster's ApplicationSet generator runs, a new `Application` named `my-app` appears and syncs on its own.

## 5. Add any other encrypted secrets

For anything with no Tofu counterpart (a database password, an admin token, a cookie secret), use ksops instead of ExternalSecrets:

1. Write the plaintext manifest (a `Secret`, or any resource with a sensitive field) somewhere temporary, *not* under `apps/`. Use a placeholder token for anything environment-specific — encryption doesn't change how `replacements:` reaches this file.
2. Copy it into place under the app's `base/` directory with an `.enc.yaml` suffix, e.g. `apps/my-app/base/db-credentials.enc.yaml`.
3. Encrypt it in place, run from the repo root so the path matches `.sops.yaml`'s `apps/.*\.enc\.yaml$` rule:
   ```bash
   sops -e -i apps/my-app/base/db-credentials.enc.yaml
   ```
4. Reference it from a `ksops` generator in the same directory:
   ```yaml
   # apps/my-app/base/ksops-generator.yaml
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
5. Add the generator to the directory's `kustomization.yaml`:
   ```yaml
   generators:
     - ksops-generator.yaml
   ```

Only keys named `data`, `stringData`, or `email` actually get encrypted by `.sops.yaml`'s rule — everything else in the manifest stays plaintext and reviewable in git.

## 6. Verify the build before pushing

Local Bash sessions don't have `kustomize`/`ksops` installed — only ArgoCD's repo-server does. Check a build (including that ksops can still decrypt through it) using the exact same binaries ArgoCD itself uses at sync time:

```bash
POD=$(kubectl get pods -n argocd -l app.kubernetes.io/name=argocd-repo-server -o jsonpath='{.items[0].metadata.name}')
kubectl cp apps/ argocd/"$POD":/tmp/test-build -c repo-server
kubectl exec -n argocd "$POD" -c repo-server -- \
  kustomize build --enable-alpha-plugins --enable-exec /tmp/test-build/apps/my-app/overlays/dev
kubectl exec -n argocd "$POD" -c repo-server -- rm -rf /tmp/test-build
```

## 7. Verify after pushing

```bash
kubectl get applications -n argocd
kubectl get externalsecret -n my-app
kubectl get pvc -n my-app
kubectl get pods -n my-app
```

The new `Application` should reach `Synced`/`Healthy`; any `ExternalSecret` should show `STATUS: SecretSynced`, `READY: True` (its value should match `terragrunt output -raw my_app_oidc_client_secret` exactly); every PVC should be bound on its intended StorageClass. The real bar, though, is a live login: visiting the app's hostname should redirect through Keycloak (or oauth2-proxy's own login page, for a forward-auth app) and land back in the app authenticated — not just "the login button appears."
