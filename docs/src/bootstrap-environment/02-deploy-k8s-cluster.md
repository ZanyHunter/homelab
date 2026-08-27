# 3. Deploy Kubernetes Cluster

Now that the infrastructure is prepared, deploy the cluster.

1. Make sure the SMB share holding remote state is mounted at `tofu/state/` — see [Remote Tofu State](./09-remote-state.md). `mkdir -p tofu/state` first on a fresh clone.
1. `cd tofu/live/dev` (or `tofu/live/<environment>` for another environment — see [Terragrunt Units](./10-terragrunt-units.md))
1. Modify `env.hcl` if necessary
1. Run:
    ```bash
    terragrunt run --all --non-interactive -- apply -auto-approve
    ```

A from-scratch stand-up is one command — no manual `-target` steps, no multi-phase bootstrap. See [Terragrunt Units](./10-terragrunt-units.md) for why, and for the shape of what this actually runs (six independently-applied units in dependency order).

## Concepts

Across the six units, this Tofu configuration:

1. Creates a network for the Kubernetes cluster to reside
1. Downloads the appropriate Talos ISO onto each physical node where Kubernetes will be hosted
1. Provisions the Talos VMs and bootstraps the cluster
1. Installs the core cluster add-ons (MetalLB, ingress-nginx, cert-manager, ArgoCD, NFS storage)
1. Deploys backup (Velero/MinIO) and SSO (Keycloak)
