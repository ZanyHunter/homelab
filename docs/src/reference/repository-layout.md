# Repository Layout

## `tofu/`

```
tofu/
  modules/                 # plain Tofu root modules — the actual resources
    network/                 # unifi_network.this (the VLAN)
    talos-cluster/            # Proxmox VMs, Talos bootstrap, kubeconfig
    core-addons/              # MetalLB, ingress-nginx, cert-manager, ArgoCD, NFS/Ceph storage
    backup/                   # MinIO, Velero
    keycloak-infra/            # Postgres, Keycloak
    observability/             # kube-prometheus-stack, Loki, Grafana Alloy
    keycloak-realm/            # homelab realm/clients, oauth2-proxy + whoami demo
  live/
    root.hcl                 # shared: generates each unit's backend, secrets decrypt
    dev/
      env.hcl                  # this environment's real values (cluster, nodes, chart versions, ...)
      network/terragrunt.hcl
      talos-cluster/terragrunt.hcl
      core-addons/terragrunt.hcl
      backup/terragrunt.hcl
      keycloak-infra/terragrunt.hcl
      observability/terragrunt.hcl
      keycloak-realm/terragrunt.hcl
    prod/                     # same shape, placeholder env.hcl — scaffolding, never applied
      ...
  secrets.enc.yaml           # SOPS/age-encrypted provider credentials
  state/                      # gitignored; SMB mount point for Tofu state
```

Dependency graph: `network` → `talos-cluster` → `core-addons` → {`backup`, `keycloak-infra`, `observability`} → `keycloak-realm`. See [Terragrunt Units](../explanation/terragrunt-units.md) for why it's split this way.

## `apps/`

```
apps/
  cluster-addons/       # cluster-level GitOps config (MetalLB pool, ClusterIssuers, ESO RBAC/ClusterSecretStore)
  immich/
  actual/
  paperless/
  vaultwarden/
  inventory/            # Homebox
  changedetection/
  <app>/
    base/                # environment-agnostic manifests, placeholder tokens (__APP_HOSTNAME__, etc.)
      kustomization.yaml
    overlays/
      dev/
        env-values.yaml    # this environment's real values, as a ConfigMap
        kustomization.yaml # resources: [../../base, env-values.yaml] + replacements:
      prod/
        ...
```

Every directory here gets discovered by ArgoCD's `ApplicationSet` at `apps/*/overlays/<cluster_name>` — see [GitOps: App-of-Apps and Secrets](../explanation/gitops-app-of-apps.md).

## `docs/`

```
docs/
  book.toml          # mdBook config (title, preprocessors, output settings)
  src/
    SUMMARY.md          # table of contents
    introduction.md
    guides/              # task-oriented how-tos, including the from-scratch deployment guide
    tutorials/           # teach-by-doing lessons (currently a stub — see its index page)
    reference/            # dry factual lookups (this page included)
    explanation/          # architecture and design-decision writeups
  book/               # gitignored build output — `mdbook build docs` to generate locally
```
