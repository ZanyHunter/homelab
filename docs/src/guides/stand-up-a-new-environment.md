# Stand Up a New Environment

`tofu/live/prod/` already has the full seven-unit shape with placeholder values in `env.hcl` — nobody has run `terragrunt apply` there yet. This guide covers what's needed to make a new environment (prod, or any environment beyond `dev`) real. See [Terragrunt Units](../explanation/terragrunt-units.md) for why each environment is just another directory of the same units.

---

## 1. Infrastructure decisions

- Pick a real, unallocated Unifi VLAN ID and subnet — one VLAN per cluster, tied to that cluster's own lifecycle (see `CLAUDE.md`'s standing Unifi guardrail; this needs sign-off since it's a genuine new Unifi resource, not just standing the VLAN up/down as part of that cluster's own destroy/recreate cycle).
- Pick unallocated `vm_id`/IP ranges that don't collide with any existing environment's.
- Provision a dedicated NFS export on the NAS — dev/prod deliberately don't share infrastructure. See [NFS Export Settings](../reference/nfs-export-settings.md) for the shape to replicate.
- Pick a real `ingress_ip` reserved in this environment's own MetalLB pool range. The ingress hostname scheme itself needs no decision — `domain_name` already drives every hostname across every unit (#10).

Fill all of this into the new environment's `env.hcl`.

## 2. Apply the Tofu side

From the new environment's directory (e.g. `tofu/live/prod/`), follow the [Deploy From Scratch](./deploy-from-scratch.md) guide's steps — they're identical regardless of which environment directory you're in, including the CephX credential bootstrap (repeated per environment: the pool name, and therefore the CephX client, is environment-scoped even on the same physical Ceph cluster — `k8s-prod-rbd` rather than `k8s-dev-rbd`).

## 3. Add overlays for every app

This is the one place the `base/`/`overlays/` split (see [GitOps: App-of-Apps and Secrets](../explanation/gitops-app-of-apps.md)) creates real fan-out: add an `overlays/<new-env>/` to **every** directory under `apps/`, not just a single config file. There's no automation catching a missed one — a forgotten `overlays/<new-env>/` just means that one app's `Application` never appears on the new cluster.

```bash
ls apps/*/overlays/
```

Cross-check the output against the full app list (`cluster-addons`, `actual`, `paperless`, `vaultwarden`, `inventory`, `changedetection`, `immich` — seven today) rather than relying on memory. Each new `overlays/<new-env>/` follows the same shape as `dev`'s: an `env-values.yaml` with this environment's real values, and a `kustomization.yaml` with the matching `replacements:` block.

## 4. Verify

- `terragrunt run --all plan` (from the new environment's `tofu/live/<env>/` directory) shows the expected create-everything plan, then `apply` — see [Deploy From Scratch](./deploy-from-scratch.md).
- `kubectl get applications -n argocd` (against the *new* cluster's kubeconfig) shows all seven `Application`s `Synced`/`Healthy` — confirming the ApplicationSet's `apps/*/overlays/<cluster_name>` generator found every overlay.
- Real logins against the new environment's own hostnames, same bar as [Deploy From Scratch](./deploy-from-scratch.md#verification).
- The *original* environment (e.g. `dev`) is completely unaffected throughout — different VLAN, different NFS export, different state tree, nothing shared.
