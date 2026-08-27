# 10. Remote Tofu State

Tofu's state lives at `tofu/state/dev/terraform.tfstate` — a plain `local` backend (`tofu/terraform.tf`), deliberately **not** anything this Tofu config creates or manages. `tofu/state/` is gitignored; the directory is meant to be an SMB mount of a share on the NAS, set up out-of-band, outside of Tofu entirely.

This replaced an earlier MinIO-on-the-cluster-hosted S3 backend (see PR history) after weighing the options:

- **MinIO/S3 hosted on this same k8s cluster** — the first approach taken. Worked, including real locking, but a full teardown of the cluster destroys the very thing backing its own state (see the "destroying your own state backend" problem below) — a real, if unlikely, failure mode. It also meant a from-scratch rebuild needed a two-phase local-state-then-migrate dance before the backend was even usable.
- **Real cloud object storage** (S3, R2, B2, etc.) — would survive even a total homelab loss, but introduces a new external dependency and credential this repo has otherwise deliberately avoided (same reasoning that ruled out Vault/External Secrets Operator for GitOps secrets — see `CLAUDE.md`).
- **SMB on the NAS (chosen)** — the NAS is already the one non-disposable piece of this topology; every cluster already points at its own NFS export there, and it already has its own offsite Kopia backup. Mounting a share from WSL and pointing Tofu's `local` backend at a path inside it needs no new component (no MinIO, no cloud account, no new credential in `secrets.enc.yaml`) and, critically, decouples state storage from anything Tofu itself stands up or tears down — a cluster (dev, or a future prod) can be destroyed and rebuilt any number of times without ever touching where its own state lives.

## Setting up the SMB mount (out-of-band, not Tofu-managed)

`tofu/state/` is gitignored, so a fresh clone won't have it at all — create the mount point first, then mount the NAS share onto it before running any `tofu` command:

```bash
mkdir -p /home/hpugh/homelab/tofu/state
sudo mount -t cifs //truenas.thepugh.family/<share> /home/hpugh/homelab/tofu/state \
  -o credentials=/path/to/smb-creds,uid=$(id -u),gid=$(id -g),vers=3.0
```

(or the equivalent `/etc/fstab` entry for a persistent mount across WSL restarts). This is a per-machine setup step, not something `tofu apply` does — same category as installing `sops`/`age` or fetching the age key from KeePass.

**Check the mount is actually live before running `tofu`.** If the share isn't mounted, `tofu/state/` is just an empty local directory — `tofu init`/`plan`/`apply` won't error, they'll silently create (or use) a fresh, empty local state file at that path instead of finding the real one. `mountpoint /home/hpugh/homelab/tofu/state` (exit code `0` means mounted) is a quick sanity check before trusting any `tofu plan` output.

**Don't mount with the `nobrl` option.** Tofu's `local` backend locks state via `flock()`; Linux's CIFS client translates that into an SMB byte-range lock by default, which is what actually prevents two concurrent `tofu apply` runs from corrupting state — `nobrl` disables that translation and silently turns off locking.

## Why the backend can't be fully declarative

OpenTofu evaluates a `backend` block before any variables or resources are known, so it can't reference `var.cluster.name` or anything else from this config — the `path` in the `backend "local"` block in `tofu/terraform.tf` is a hardcoded literal. The `dev/` prefix in that path exists so a future prod cluster's state can live on the same share without colliding, once [#21](https://github.com/ZanyHunter/homelab/issues/21) gives it its own Tofu config to hardcode a `prod/` path into. A real multi-environment setup will need to confront the hand-edited-literal problem properly — tracked as part of [#26](https://github.com/ZanyHunter/homelab/issues/26) (Terragrunt), which manages per-environment backend config as a generated file rather than a hand-maintained literal.

## The "destroying your own state backend" problem this avoids

If Tofu's state lived inside a resource this same config creates (e.g. the earlier MinIO-on-cluster approach), a full `tofu destroy` would eventually delete that resource too — and the *next* state write (persisting "this resource is now gone") would fail, because the backend it's writing to no longer exists by that point. The real-world destroy usually completes fine; it's specifically the last state-persist call that errors out. Pointing state at NAS-backed storage that no cluster ever creates or destroys sidesteps this entirely: `tofu destroy` (or a from-scratch rebuild) never has to worry about state storage disappearing mid-run, for dev, a future prod, or any other cluster this config might stand up.
