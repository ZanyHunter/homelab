# CLAUDE.md

Guidance for Claude Code working in this repository. Read this before making changes, and keep it updated as the infrastructure and our working agreements evolve.

## What this repo is

Infrastructure-as-Code for zanyhunter's homelab. The goal is disaster recovery: everything needed to stand up equivalent infrastructure on fresh hardware should be reconstructable from this repo plus the age private key (kept in KeePass, see Secrets below). Nothing here currently hosts real user data — the Kubernetes cluster is dev-only — but the Cloudflare DNS token controls a real, internet-facing domain, so treat that boundary seriously even though the cluster itself is disposable.

## Physical & network topology

- **Compute**: 3 physical Proxmox nodes (`pve-node-0/1/2`) in a hyperconverged cluster (`homelab`) using Ceph for storage (`ceph-1` datastore).
- **Storage**: 1 NFS NAS for service data (Immich, etc.). Not yet under IaC management — provisioned/configured manually today. Revisit if it should be brought into Tofu or get its own IaC story.
- **Network**: Unifi-managed. The K8s cluster lives on VLAN 1601, subnet `192.168.160.0/27` (expanded from a `/28` once that filled up — see issue #3), gateway `192.168.160.1`, domain `k8s.thepugh.family` (see `tofu/main.tf`). Local DNS resolution for that domain is a wildcard record in the Unifi controller pointing at the MetalLB ingress IP — documented in `docs/src/bootstrap-environment/04-dns-configuration.md`.
- **Real external domain**: `thepugh.family`, managed in Cloudflare. cert-manager uses a Cloudflare API token (DNS Zone Edit scope) for ACME DNS-01 challenges — this is the one credential in this repo with blast radius outside the homelab.

## Kubernetes cluster

- Talos Linux, provisioned as Proxmox VMs via the `siderolabs/talos` and `bpg/proxmox` Tofu providers.
- 6 nodes today: `k8s-ctrl-00/01/02` (control plane) + `k8s-node-00/01/02` (worker), one of each role per Proxmox node — see `tofu/nodes.auto.tfvars`.
- Cluster name `dev`, endpoint `192.168.160.16` — a Talos-managed floating VIP shared across the 3 control planes (not any single node's address), so the control plane stays reachable if one control-plane node is down.
- Bootstrap add-ons installed via Helm from Tofu (not yet handed off to ArgoCD as an app-of-apps): MetalLB (LB pool `192.168.160.5-8`, `192.168.160.12-14`), ingress-nginx, cert-manager (+ `letsencrypt-prod` ClusterIssuer via Cloudflare DNS-01), ArgoCD (HA, exposed at `argocd.k8s.thepugh.family`).
- **Gap**: ArgoCD is running but nothing points it at application manifests yet. When we start deploying real workloads (Immich, etc.), decide on an app-of-apps repo structure.

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
- **ArgoCD has no app-of-apps wired up** — see Kubernetes cluster section above.
- **NAS is not IaC-managed** — manual today.
- **Single age key covers all secrets** — see Secrets management design note above.

## History / key decisions

- Chose SOPS + age over a NAS-hosted secrets store (e.g. Vault/MinIO) specifically because the user wanted secrets to survive a NAS-down disaster; encrypted secrets committed to git satisfy that, since any clone of the repo has the ciphertext, and only the age key (KeePass-backed, offsite) is the recovery-critical piece.
- Migrated `tofu/secrets.auto.tfvars` (plaintext, gitignored, single point of failure) to `tofu/secrets.enc.yaml` + `carlpett/sops` provider — see commit `1625bc3`.
- Decided against the `@claude` GitHub App/Action integration for now, in favor of GitHub Issues as backlog + live-session tasking — see Tasking workflow above for the reasoning (local secrets/LAN access it can't replicate).
