# 8. Backup and Restore

Cluster backups are handled by [Velero](https://velero.io/), backed by [MinIO](https://min.io/) as an S3-compatible gateway in front of the NFS share — Velero needs an S3 API and doesn't speak NFS natively. Both are installed via Tofu (`tofu/backup.tf`), not GitOps, since their configuration (the `BackupStorageLocation`, the daily `Schedule`) is expressed entirely through their own Helm chart values rather than needing a separate hand-rolled object.

---

## What gets backed up

Velero backs up Kubernetes **object definitions** — Deployments, Services, ConfigMaps, Secrets, the PVC/PV objects themselves, ArgoCD `Application`s, etc. — not raw file-level volume data. File-system backup (Velero's restic/kopia integration, `deployNodeAgent`) and CSI volume snapshots are both deliberately left disabled (`snapshotsEnabled = false`, `deployNodeAgent = false` in `tofu/backup.tf`).

That's a deliberate scope decision, not an oversight: today, every workload's persistent data already lives on the NFS-backed `StorageClass` from the [storage](./05-nfs-storage-access.md) issue, and that NFS share has its own offsite backup outside this repo's concern (see `CLAUDE.md`). Backing up the same bytes a second time through Velero would be redundant. Revisit if a workload ever needs a non-NFS-backed volume.

A restore, then, recreates namespaces, workloads, and their config/secrets — and since the PV objects Velero restores point back at the same underlying NFS-backed volumes, any data already on those volumes comes along for the ride without Velero needing to move it itself.

## Schedule and retention

A daily `Schedule` (`var.backup.schedule`, `0 3 * * *` for `dev`) backs up the whole cluster with a 30-day retention (`var.backup.ttl`, `720h`). Both are environment-specific `tofu/variables.tf` values — see `var.backup` — so `dev`/`prod` can tune them independently.

## Verifying backups are actually happening

```bash
velero backup get
velero schedule get
```

A healthy `Schedule` shows `STATUS: Enabled` and, after its first scheduled run, a `LASTBACKUP` timestamp. `velero backup describe <name>` shows per-resource detail; `velero backup logs <name>` shows the full log if something didn't back up as expected.

The [`velero` CLI](https://velero.io/docs/main/basic-install/#install-the-cli) isn't installed as part of cluster bootstrap — download the release matching the server's `appVersion` (currently `v1.18.1`, from `tofu/backup.tf`'s `chart_versions.velero` pin) from the [velero releases page](https://github.com/vmware-tanzu/velero/releases), and point `kubectl`/`velero` at a current kubeconfig (`tofu output -raw kube_config`, per `CLAUDE.md`).

## Restore procedure

This repo's whole premise is disaster recovery, so a backup nobody has tested restoring from isn't a real backup. To restore a namespace (or the whole cluster) from a backup:

```bash
# See what's available
velero backup get

# Restore everything in a backup
velero restore create --from-backup <backup-name> --wait

# Or restore just one namespace
velero restore create --from-backup <backup-name> --include-namespaces <namespace> --wait

# Confirm it worked
velero restore describe <restore-name>
kubectl get all -n <namespace>
```

This was verified end-to-end while standing up Velero: a namespace with a test `ConfigMap` was backed up, the namespace was deleted outright, and `velero restore create --from-backup ... --wait` brought the namespace and the `ConfigMap`'s data back correctly.

### Restoring into a fresh cluster

Since Velero's own `BackupStorageLocation` points at the MinIO bucket on the NAS, a from-scratch cluster rebuild (`tofu apply` after `tofu destroy`, or onto new hardware) that reconnects to the *same* NFS export will have a working, populated `BackupStorageLocation` again as soon as `helm_release.velero` applies — Velero syncs existing backups from the bucket automatically, no restore-specific setup needed beyond a normal `tofu apply`.
