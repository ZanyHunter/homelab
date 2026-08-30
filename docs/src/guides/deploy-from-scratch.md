# Deploy From Scratch

Everything needed to stand up this repo's infrastructure on fresh hardware, or recover it after a disaster — see `CLAUDE.md`'s "What this repo is" for why that's the actual design goal, not just a nice-to-have. This page stays tight and imperative; follow the links for the "why" behind any given step.

---

## Prerequisites

### Infrastructure

- A Proxmox cluster. Ideally 3+ physical nodes using Ceph for hyperconverged storage — this repo's [Ceph-Backed Storage](../explanation/ceph-backed-storage.md) add-on depends on an existing Ceph datastore, and 3 nodes is what keeps etcd quorum safe if one control-plane node goes down.
- Networking configured to allow VLAN trunking to those Proxmox nodes — Talos VMs get their own dedicated VLAN (see [DNS and Ingress Hostnames](../explanation/dns-and-hostnames.md) for how that VLAN's `domain_name` drives every hostname).
- A Unifi-managed network with the Network application running.
- An NFS NAS reachable from where the cluster's VLAN will live, for bulk application storage (media libraries, documents). See [NFS Export Settings](../reference/nfs-export-settings.md) for the exact export this repo expects — create it now, before the first apply, so `core-addons`' NFS StorageClass has somewhere to provision against.

### Tooling (on the bootstrap machine)

- Ubuntu (or similar Linux)
- [mise](https://mise.jdx.dev/) — installs everything else. After [installing mise itself](https://mise.jdx.dev/installing-mise.html), from the repo root:
  ```bash
  mise trust
  mise install
  ```
  This pins and installs OpenTofu, Terragrunt, sops, age, the `gh` CLI, `kubectl`, mdBook + `mdbook-tabs` (docs), and the `velero` CLI (backup/restore) at the exact versions in `mise.toml` — no separate per-tool install step. `mise activate` in your shell rc puts them on `PATH`; see `CLAUDE.md`'s Toolchain section for the per-tool notes (in particular: `kubectl` is a hard dependency of `core-addons`'s apply, not just an interactive convenience) and how to bump a pin.
- `gh auth login` — mise only installs the `gh` binary, not an authenticated session.

See `CLAUDE.md`'s Toolchain section for exact version notes and gotchas.

### Credentials

All of the following live encrypted in `tofu/secrets.enc.yaml` — edit it with `sops tofu/secrets.enc.yaml` (opens decrypted in `$EDITOR`, re-encrypts on save). See `CLAUDE.md`'s Secrets management section for the full design.

1. **The age private key.** Recover it from KeePass (the disaster-recovery path this repo is designed around) and place it at `~/.config/sops/age/keys.txt`, mode `600` — this is the default lookup path for both `sops` and the `carlpett/sops` Terraform provider. If this is genuinely a brand-new deployment with no prior key, generate one with `age-keygen` instead and update `.sops.yaml`'s recipient to match — out of scope for a normal rebuild of *this* repo's own environments.
2. **A Proxmox API user for Tofu.** On any Proxmox node:
   ```bash
   pveum role add TerraformProv -privs "Datastore.Allocate Datastore.AllocateSpace Datastore.AllocateTemplate Datastore.Audit Pool.Allocate Sys.Audit Sys.Console Sys.Modify VM.Allocate VM.Audit VM.Clone VM.Config.CDROM VM.Config.Cloudinit VM.Config.CPU VM.Config.HWType VM.Config.Memory VM.Config.Network VM.Config.Options VM.GuestAgent.Audit VM.GuestAgent.Unrestricted VM.Migrate VM.PowerMgmt SDN.Use"
   pveum user add terraform-prov@pve --password <password>
   pveum aclmod / -user terraform-prov@pve -role TerraformProv
   ```
   Add the resulting credentials to `tofu/secrets.enc.yaml`.
3. **Unifi controller credentials** — a user the `unifi` Terraform provider can authenticate as.
4. **A Cloudflare API token** with Zone DNS Edit scope on the real domain (used by cert-manager for DNS-01 challenges). Only add Account: Cloudflare Tunnel Edit if this environment will run [Public Ingress](../explanation/public-ingress.md) (`public_ingress_enabled = true`) — dev doesn't need it.
5. **(Optional) a Discord webhook URL** (`discord_alert_webhook`) if you want Alertmanager to deliver alerts — see [Observability](../explanation/observability.md).

The **CephX credential** for Ceph-backed storage can't be created yet at this point — it depends on a Tofu-managed Ceph pool that doesn't exist until partway through the steps below. See step 5.

---

## Steps

1. **Mount Tofu's remote state share.** `mkdir -p tofu/state`, then mount the NAS share that backs it, e.g.:
   ```bash
   sudo mount -t cifs //truenas.thepugh.family/<share> /home/hpugh/homelab/tofu/state \
     -o credentials=/path/to/smb-creds,uid=$(id -u),gid=$(id -g),vers=3.0
   ```
   (or the equivalent `/etc/fstab` entry for a persistent mount). Confirm it's actually mounted with `mountpoint tofu/state` before continuing — an unmounted `tofu/state/` silently accepts fresh, empty state files instead of erroring. See [Remote Tofu State](../explanation/remote-state.md) for why this is deliberately not Tofu-managed, and why `nobrl` must never be used when mounting.
2. `cd tofu/live/dev` (or `tofu/live/<environment>` — see [Stand Up a New Environment](./stand-up-a-new-environment.md) if this isn't `dev`).
3. Review `env.hcl` and adjust anything environment-specific (node counts/sizing, chart versions, `domain_name`, `ingress_ip`, etc.).
4. Apply everything, in dependency order, in one command:
   ```bash
   terragrunt run --all --non-interactive -- apply -auto-approve
   ```
5. **On a genuine from-scratch apply, this will pause partway through with `core-addons` failing** — its `ceph-csi` deployment needs a CephX credential that doesn't exist yet, and that credential can't be created until the Ceph pool this same apply just created (`talos-cluster`'s `proxmox_ceph_pool.k8s_rbd`) actually exists. When that happens:
   1. On any Proxmox node, scoped to only the new pool:
      ```bash
      ceph auth get-or-create client.k8s-dev-rbd \
        mon 'profile rbd' \
        osd 'profile rbd pool=k8s-dev-rbd'
      ```
   2. Add the printed `key = ...` value to `tofu/secrets.enc.yaml` as `ceph_rbd_client_key`:
      ```bash
      sops set tofu/secrets.enc.yaml '["ceph_rbd_client_key"]' '"<the key value>"'
      ```
   3. Re-run the command from step 4 — it picks up exactly where it left off. See [Ceph-Backed Storage](../explanation/ceph-backed-storage.md) for why this can't be automated.
6. Fetch cluster config to the default locations (from `tofu/live/dev/talos-cluster/`):
   ```bash
   terragrunt output -raw talosctl_config > ~/.talos/config
   terragrunt output -raw kube_config > ~/.kube/config
   ```

That's the whole stand-up — no other manual steps, no other `-target` incantations. See [Terragrunt Units](../explanation/terragrunt-units.md) for what these seven units actually create (a network, Talos VMs, core cluster add-ons, then backup/SSO/observability), and for real gotchas found testing this live.

## Verification

- `kubectl get nodes` — all 6 (3 control-plane, 3 worker) `Ready`.
- `kubectl get applications -n argocd` — every `Application` `Synced`/`Healthy`.
- DNS resolves — see [DNS and Ingress Hostnames](../explanation/dns-and-hostnames.md)'s verification section.
- Keycloak, Grafana, and ArgoCD are all reachable at their hostnames and redirect through Keycloak login — see [Deployed Apps](../reference/deployed-apps.md) for the full hostname list, and [SSO and Keycloak](../explanation/sso-and-keycloak.md) for retrieving the initial admin credentials.
- `terragrunt run --all plan` (from `tofu/live/dev/`) shows zero drift across all 7 units.
