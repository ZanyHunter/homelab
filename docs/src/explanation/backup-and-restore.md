# Backup and Restore

Cluster backups are handled by [Velero](https://velero.io/), backed by [MinIO](https://min.io/) (being replaced, see below) as an S3-compatible gateway in front of the NFS share — Velero needs an S3 API and doesn't speak NFS natively. Both are installed via Tofu (`tofu/modules/backup/main.tf`), not GitOps, since their configuration (the `BackupStorageLocation`, the daily `Schedule`) is expressed entirely through their own Helm chart values rather than needing a separate hand-rolled object.

---

## What gets backed up

Velero backs up Kubernetes **object definitions** — Deployments, Services, ConfigMaps, Secrets, the PVC/PV objects themselves, ArgoCD `Application`s, etc. For NFS-backed volumes, that's sufficient on its own: the PV objects Velero restores point back at the same underlying NFS-backed volumes, so any data already there comes along for the ride without Velero needing to move it itself — the NFS share also has its own offsite backup outside this repo's concern (see `CLAUDE.md`), so backing up the same bytes a second time through Velero would be redundant there.

That reasoning doesn't hold for Ceph-backed volumes (`ceph-rbd-<cluster_name>`, [added for databases](./ceph-backed-storage.md), #28) — restoring the PV object alone doesn't restore *data* on a volume that isn't independently backed up elsewhere, and Ceph's own replication protects against disk failure, not accidental/logical data loss. **File System Backup** (Velero's kopia integration, `deployNodeAgent = true`) is enabled for exactly this: real volume data, not just object definitions. It's opt-in per-pod via the `backup.velero.io/backup-volumes: <volume-name>` annotation — **standing rule: every workload's Ceph-backed data volume gets this annotation, no exceptions.** NFS-backed volumes (MinIO's own data, Loki's chunks, Prometheus's TSDB) stay excluded deliberately, since they're covered by the NFS share's own offsite backup already (per the reasoning above) and a second copy through Velero would be redundant there — but that exclusion is specifically for NFS-backed volumes, not a general "opt-in only where it seems worth it" judgment call. A real audit (2026-08) found 4 of 7 self-hosted apps (`apps/actual`, `apps/vaultwarden`, `apps/inventory`, `apps/changedetection`) holding real data on a Ceph-backed PVC without this annotation — meaning that data had no backup coverage at all, anywhere. Fixed; check for this on any new Ceph-backed workload going forward rather than assuming it's covered. CSI volume snapshots (`snapshotsEnabled`) stay disabled — File System Backup already covers both StorageClasses with one mechanism, so a second Ceph-only mechanism wouldn't add anything.

## Schedule and retention

A daily `Schedule` (`var.backup.schedule`, `0 3 * * *` for `dev`) backs up the whole cluster with a 30-day retention (`var.backup.ttl`, `720h`). Both are environment-specific values — see `var.backup` in `tofu/modules/backup/variables.tf`, set per environment in `tofu/live/<env>/env.hcl` — so `dev`/`prod` can tune them independently.

## Verifying backups are actually happening

```bash
velero backup get
velero schedule get
```

A healthy `Schedule` shows `STATUS: Enabled` and, after its first scheduled run, a `LASTBACKUP` timestamp. `velero backup describe <name>` shows per-resource detail; `velero backup logs <name>` shows the full log if something didn't back up as expected.

The [`velero` CLI](https://velero.io/docs/main/basic-install/#install-the-cli) isn't installed as part of cluster bootstrap — download the release matching the server's `appVersion` (currently `v1.18.1`, from `tofu/modules/backup/main.tf`'s `chart_versions.velero` pin) from the [velero releases page](https://github.com/vmware-tanzu/velero/releases), and point `kubectl`/`velero` at a current kubeconfig (`terragrunt output -raw kube_config` from `tofu/live/dev/talos-cluster/`, per `CLAUDE.md`).

## A real gotcha found live enabling File System Backup

The first real backup attempt after flipping `deployNodeAgent = true` failed with `mkdir /udmrepo: permission denied`. Velero's kopia repository writes its config under `$HOME/udmrepo` — with the main Velero container's `runAsUser: 1000` and no matching `/etc/passwd` entry in the image, `$HOME` is unset, so kopia resolves that to the filesystem root, which a non-root UID can't write to. Fixed with an explicit `HOME=/tmp` env var (`configuration.extraEnvVars` in `tofu/modules/backup/main.tf`) — `/tmp` is writable regardless of the container's non-root securityContext. Also required moving the `velero` namespace's PSA level from `baseline` to `privileged`: `deployNodeAgent`'s DaemonSet needs real host-level access to every pod's volume mount path, same category of need as the other node-level DaemonSets in this cluster (MetalLB, csi-driver-nfs, node-exporter, ceph-csi-rbd).

## Replacing MinIO with Garage (#108)

MinIO's community container images were removed from Docker Hub and put behind authentication on quay.io (September 2026), and the project is archived, so it can't be deployed from scratch anymore. Its replacement is [Garage](https://garagehq.deuxfleurs.fr/) (`tofu/modules/backup/garage.tf`, `var.garage`, pinned by digest in `env.hcl`), chosen over SeaweedFS/RustFS/Ceph RGW for its tiny footprint and because it needs no bootstrap step: `garage server --single-node --default-bucket` creates its own single-node layout, the `velero` bucket, and the access key straight from env vars (`GARAGE_DEFAULT_*`, fed from a Tofu-generated Secret), so there's no post-install Job the way MinIO's chart had.

**Migration is staged, and MinIO is still the default backup location on any environment that hasn't been cut over.** Garage is added *alongside* it as a second, non-default `BackupStorageLocation` (`garage`). Cutting over means copying the old bucket's contents through the S3 API (MinIO's on-disk format can't be read by anything else), then repointing the default location and retiring MinIO — see issue #108 for the full runbook. Dev's backups are disposable, so dev skips the copy.

**Storage split.** Garage's object *data* lives on the NFS-backed StorageClass (like MinIO's did, so it inherits the NAS's offsite backup); its *metadata* is a SQLite file that can't safely live on NFS, so it sits on a small Ceph-backed volume (`var.garage.meta_size`), with a metadata snapshot written back to the NFS volume every 6 hours (`metadata_auto_snapshot_interval`). The one real tradeoff: metadata shares a failure domain with the Ceph-backed data Velero backs up — a lost Ceph volume costs at most the last snapshot interval, not the store.

Verified live on dev: a File System Backup of a Ceph-backed volume (a 40MB random file plus 300 small ones) to the `garage` location, namespace deleted, restored, checksum matching the original; backup deletion also cleans up. Two test-writing gotchas worth remembering: the `backup.velero.io/backup-volumes` annotation takes the pod's *volume name*, not the PVC name (a wrong value makes Velero silently skip the volume, reported only as "opted out due to annotation"); and a restored pod re-runs its own startup command, so verify against a checksum recorded *before* the backup, not one the restored pod regenerates. Also: the Tofu `kubernetes` provider serializes an unset container-level `run_as_non_root` as an explicit `false`, which `restricted` PSA rejects even when the pod-level value is `true` — set it on the container too.

## Restoring into a fresh cluster

Since Velero's own `BackupStorageLocation` points at the MinIO bucket on the NAS, a from-scratch cluster rebuild (`terragrunt run --all apply` after `terragrunt run --all destroy`, or onto new hardware) that reconnects to the *same* NFS export will have a working, populated `BackupStorageLocation` again as soon as `helm_release.velero` applies — Velero syncs existing backups from the bucket automatically, no restore-specific setup needed beyond a normal apply.

For the actual restore commands (and the real backup → delete → restore round-trip this was verified against), see the [Restore From a Backup](../guides/restore-from-a-backup.md) guide.
