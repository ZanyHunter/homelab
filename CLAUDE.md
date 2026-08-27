# CLAUDE.md

Guidance for Claude Code working in this repository. Read this before making changes, and keep it updated as the infrastructure and our working agreements evolve.

## What this repo is

Infrastructure-as-Code for zanyhunter's homelab. The goal is disaster recovery: everything needed to stand up equivalent infrastructure on fresh hardware should be reconstructable from this repo plus the age private key (kept in KeePass, see Secrets below). Nothing here currently hosts real user data — the Kubernetes cluster is dev-only — but the Cloudflare DNS token controls a real, internet-facing domain, so treat that boundary seriously even though the cluster itself is disposable.

The Tofu config is also meant to be **reusable across multiple cluster environments (dev today, a future prod) for years to come** — and dev/prod will not share infrastructure (each gets its own NFS backend, for instance). Environment-specific values (Helm chart versions, the NFS storage server/share, etc.) belong in object-typed variables in `tofu/variables.tf` (see `cluster`, `chart_versions`, `nfs_storage`) with real values in `tofu/nodes.auto.tfvars`, not hardcoded in resource blocks — when adding a new add-on or resource with a version string or environment-specific setting, variablize it the same way rather than hardcoding it "for now."

## Physical & network topology

- **Compute**: 3 physical Proxmox nodes (`pve-node-0/1/2`) in a hyperconverged cluster (`homelab`) using Ceph for storage (`ceph-1` datastore).
- **Storage**: 1 NFS NAS for service data (Immich, etc.). Not yet under IaC management — provisioned/configured manually today. Revisit if it should be brought into Tofu or get its own IaC story.
- **Network**: Unifi-managed. The K8s cluster lives on VLAN 1601, subnet `192.168.160.0/27` (expanded from a `/28` once that filled up — see issue #3), gateway `192.168.160.1`, domain `k8s.thepugh.family` (see `tofu/main.tf`). Local DNS resolution for that domain is a wildcard record in the Unifi controller pointing at the MetalLB ingress IP — documented in `docs/src/bootstrap-environment/04-dns-configuration.md`.
- **Real external domain**: `thepugh.family`, managed in Cloudflare. cert-manager uses a Cloudflare API token (DNS Zone Edit scope) for ACME DNS-01 challenges — this is the one credential in this repo with blast radius outside the homelab.

## Kubernetes cluster

- Talos Linux, provisioned as Proxmox VMs via the `siderolabs/talos` and `bpg/proxmox` Tofu providers.
- 6 nodes today: `k8s-ctrl-00/01/02` (control plane) + `k8s-node-00/01/02` (worker), one of each role per Proxmox node — see `tofu/nodes.auto.tfvars`.
- Cluster name `dev`, endpoint `192.168.160.16` — a Talos-managed floating VIP shared across the 3 control planes (not any single node's address), so the control plane stays reachable if one control-plane node is down.
- Bootstrap add-ons installed via Helm from Tofu: MetalLB, ingress-nginx, cert-manager, ArgoCD (HA, exposed at `argocd.k8s.thepugh.family`). Cluster-level *config* objects that used to be applied by Tofu `terraform_data`/`local-exec` provisioners — the MetalLB `IPAddressPool`/`L2Advertisement` (LB pool `192.168.160.5-8`, `192.168.160.12-14`) and the `letsencrypt-prod`/`letsencrypt-staging` cert-manager `ClusterIssuer`s — are GitOps-managed now instead; see the app-of-apps entry below.
- **App-of-apps**: an ArgoCD `ApplicationSet` (`tofu/gitops.tf`, `var.gitops` for repo/revision) auto-discovers one `Application` per directory under this repo's `apps/`, so adding a new app is "add a directory under `apps/`, push" — no Tofu change, no manual `kubectl`/`argocd` command. `apps/cluster-addons/` is the cluster-level-config directory mentioned above; real workloads (Immich, etc.) will each get their own `apps/<app>/` directory when they land. Detailed docs: `docs/src/bootstrap-environment/06-gitops.md`.

## Toolchain

- **OpenTofu** (not Terraform) — `tofu` CLI, config lives in `tofu/`.
- **sops** + **age** — secrets encryption, see below. Both installed locally.
- **gh CLI** — installed and authenticated as ZanyHunter over HTTPS. Used for the branch/PR workflow (see Git workflow below).
- **mdBook** — installed (`~/.cargo/bin/mdbook`). Docs source is `docs/src/`; the built site `docs/book/` is gitignored (not committed) — run `mdbook build docs` locally to preview, no need to commit output.
- **kubectl** — this session's Bash environment has confirmed LAN reachability to `192.168.160.0/27` (verified via `ping` to a control-plane node and the gateway, 2026-08-27) — don't assume otherwise. If `ping`/`kubectl` fail, check first rather than declaring an environment limitation: the cluster's CA/certs regenerate on every from-scratch rebuild, so a cached `~/.kube/config` from before a rebuild will fail TLS verification even though the network path is fine — fetch a current one with `tofu output -raw kube_config` (from `tofu/`) rather than assuming a stale kubeconfig is still valid.

## Secrets management

Provider credentials (Proxmox, Unifi, Cloudflare) live encrypted at `tofu/secrets.enc.yaml`, committed to git. Encrypted with SOPS, recipient is a single age keypair.

- **Decryption**: Terraform reads the file automatically via the `carlpett/sops` provider (`tofu/secrets.tf`) at plan/apply time — no manual decrypt step needed for normal Tofu usage.
- **Manual edit**: `sops tofu/secrets.enc.yaml` (opens decrypted in `$EDITOR`, re-encrypts on save).
- **The age private key** lives at `~/.config/sops/age/keys.txt` on this machine (mode 600) — that's the default lookup path for both `sops` and the Terraform provider. It is **not** in git and never should be.
- **Disaster recovery for the key itself**: the private key is backed up in the user's KeePass file, which is itself stored offsite separately from this repo. If this machine is lost, recover the key from KeePass and place it back at `~/.config/sops/age/keys.txt` before running `tofu` commands.
- **Design note**: this is a single age key covering all secrets (Proxmox, Unifi, Cloudflare) — an honor-system boundary, not a technical one. We considered splitting Unifi/Cloudflare into a separately-keyed file so Claude could be structurally prevented from touching them, and decided against it: the user has a fresh full Unifi backup, so the blast radius of an honor-system violation is a few minutes of restore time. Revisit this if that risk tolerance changes.
- **GitOps secrets (ksops)**: ArgoCD's repo-server also has this same age key, mounted as a `kubernetes_secret` in the `argocd` namespace (`tofu/gitops.tf`), so it can decrypt SOPS-encrypted manifests under `apps/` at sync time via [ksops](https://github.com/viaduct-ai/kustomize-sops). This means the raw private key now lives in one additional place beyond this machine + KeePass: as a live Kubernetes Secret in-cluster. Accepted for the same reason as the single-key design above (dev cluster, single operator); revisit alongside that note if the risk tolerance changes. See `docs/src/bootstrap-environment/06-gitops.md` for how to add a new encrypted secret this way.

## Standing permissions & guardrails

- **Proxmox and Kubernetes (dev cluster)**: full autonomy. Run `tofu plan`/`apply`/`destroy`, `kubectl`, `helm` freely against this stack without asking first — it's dev-only and disposable.
- **Unifi**: do **not** author or apply changes to Unifi-managed Tofu resources (currently `unifi_network.this` and the `unifi` provider block) without asking the user first. This means changes with real effect — adding, modifying, or removing Unifi resources/config, or running `tofu apply`/`destroy` that touches them. It does **not** mean avoiding the files entirely: read-only operations (`tofu plan`) and mechanical formatting (`tofu fmt` and similar tools) are fine even if they happen to touch a line inside a Unifi resource block, since those don't change intent or behavior.
- **Cloudflare/DNS**: same ask-first treatment as Unifi. The token controls a real domain; cert-manager's existing use of it (DNS-01 challenges) is already approved and needs no further confirmation, but any new Cloudflare-related Tofu resource or config change should be proposed and confirmed before applying.
- **Everything else** (docs, non-secret Tofu resources, CI config, etc.): normal judgment — no special standing restriction beyond the git workflow below.

## Git workflow

- **Commit messages**: Conventional Commits, always (`feat:`, `fix:`, `docs:`, `chore:`, etc., with a scope where it adds clarity, e.g. `feat(tofu): ...`). Split unrelated concerns into separate, self-consistent commits rather than one large commit — each commit should leave the repo in a valid state.
- **Branching**: do not push directly to `main`. Create a feature branch, commit there, push it, and open a PR with `gh pr create`. Wait for the user to review and merge — do not merge PRs unilaterally.
- **Branch naming**: `type/short-description` (e.g. `feat/argocd-app-of-apps`, `docs/dns-guide`), mirroring the commit type.

## Tasking workflow

How the user hands off work, especially for larger refactors/features tracked over multiple sessions:

- **GitHub Issues are the backlog.** One issue per larger refactor or feature, with a checklist of subtasks in the body. Claude Code does not retain memory across sessions by default, so an issue is durable state a future session can re-read cold — treat it as more reliable than chat history for "what are we doing and why."
- **No passive awareness.** Claude does not see new GitHub comments, issues, or PR activity as they happen — only when a session actively runs a `gh` command. Nothing happens automatically just because something was posted on GitHub.
- **To task Claude**: point it at the issue number in a live session (e.g. "pick up #4"). It should pull the issue via `gh issue view`, do the work with full local access (secrets, LAN, everything this environment has), open a PR per the Git workflow above, and comment back on the issue linking the PR (or close it once merged).
- **The `@claude` GitHub App/Action integration** (triggers an automated run when `@claude` is mentioned in an issue/PR, no local session needed) was considered and deliberately skipped for now: that integration runs on an isolated GitHub Actions runner with access only to the git repo and configured Actions secrets — no local machine access, meaning no age key and no LAN reachability. Since nearly everything in this repo eventually touches secrets or needs LAN access, it would only cover a narrow slice of work (pure code review/refactor suggestions). Revisit if the balance of work shifts toward tasks that don't need local access.
- **GitHub Projects** (kanban board over issues) is worth adding once more than 3-4 larger initiatives are in flight concurrently; not needed yet.

## Documentation

Keep `docs/src/` in sync with infrastructure changes as part of the same change/PR — when a Tofu change alters bootstrap steps, add-ons, or operational procedure, update the relevant mdBook page(s) alongside it rather than letting docs drift.

## Known gaps / roadmap

Worth revisiting as this matures beyond "dev, half-baked":

- **No remote Tofu state backend** — state is local-only (`tofu/terraform.tfstate`, gitignored). Fine for now with one operator; revisit before this becomes multi-operator or holds real workloads.
- **No CI** — no automated `tofu plan`/`validate` on PRs yet. Worth adding once the branch/PR workflow is in regular use.
- **App-of-apps has no real workloads yet** — the ApplicationSet (see Kubernetes cluster section above) currently only manages `apps/cluster-addons/`. No app directory exists yet for Immich/Paperless-ngx/etc.
- **NAS is not IaC-managed** — manual today.
- **Single age key covers all secrets** — see Secrets management design note above.
- **No actual mechanism for running two environments from this config yet** — environment-specific values are variablized (see "What this repo is" above), but there's still one flat root module and one local state file. Nothing today lets `tofu apply` stand up a second, independent cluster (e.g. prod) from the same config without clobbering dev's state. Needs a decision (Tofu workspaces vs. per-environment tfvars+state directories) before a prod cluster actually gets built.

## History / key decisions

- Chose SOPS + age over a NAS-hosted secrets store (e.g. Vault/MinIO) specifically because the user wanted secrets to survive a NAS-down disaster; encrypted secrets committed to git satisfy that, since any clone of the repo has the ciphertext, and only the age key (KeePass-backed, offsite) is the recovery-critical piece.
- Migrated `tofu/secrets.auto.tfvars` (plaintext, gitignored, single point of failure) to `tofu/secrets.enc.yaml` + `carlpett/sops` provider — see commit `1625bc3`.
- Decided against the `@claude` GitHub App/Action integration for now, in favor of GitHub Issues as backlog + live-session tasking — see Tasking workflow above for the reasoning (local secrets/LAN access it can't replicate).
- Bootstrapped the ArgoCD app-of-apps ApplicationSet and wired ksops into the repo-server for GitOps-managed secrets, migrating the MetalLB pool and cert-manager `ClusterIssuer`s off Tofu `terraform_data`/`local-exec` in the process — see PR #22 (closed issues #6, #7). ksops/SOPS-in-ArgoCD was chosen over External Secrets Operator/Vault specifically to avoid running and securing a new component, extending the same age-key pattern already used for `tofu/secrets.enc.yaml`.
