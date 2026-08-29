# 8. Backup and Restore

Cluster backups are handled by [Velero](https://velero.io/), backed by [MinIO](https://min.io/) as an S3-compatible gateway in front of the NFS share — Velero needs an S3 API and doesn't speak NFS natively. Both are installed via Tofu (`tofu/modules/backup/main.tf`), not GitOps, since their configuration (the `BackupStorageLocation`, the daily `Schedule`) is expressed entirely through their own Helm chart values rather than needing a separate hand-rolled object.

---

## What gets backed up

Velero backs up Kubernetes **object definitions** — Deployments, Services, ConfigMaps, Secrets, the PVC/PV objects themselves, ArgoCD `Application`s, etc. For NFS-backed volumes, that's sufficient on its own: the PV objects Velero restores point back at the same underlying NFS-backed volumes, so any data already there comes along for the ride without Velero needing to move it itself — the NFS share also has its own offsite backup outside this repo's concern (see `CLAUDE.md`), so backing up the same bytes a second time through Velero would be redundant there.

That reasoning doesn't hold for Ceph-backed volumes (`ceph-rbd-<cluster_name>`, [added for databases](./13-ceph-storage.md), #28) — restoring the PV object alone doesn't restore *data* on a volume that isn't independently backed up elsewhere, and Ceph's own replication protects against disk failure, not accidental/logical data loss. **File System Backup** (Velero's kopia integration, `deployNodeAgent = true`) is enabled for exactly this: real volume data, not just object definitions. It's opt-in per-pod via the `backup.velero.io/backup-volumes: <volume-name>` annotation (see `keycloak-infra`'s Postgres `StatefulSet`) rather than backed up by default for every volume in the cluster — deliberately conservative, since MinIO's own data, Loki's chunks, Prometheus's TSDB, etc. don't need this. CSI volume snapshots (`snapshotsEnabled`) stay disabled — File System Backup already covers both StorageClasses with one mechanism, so a second Ceph-only mechanism wouldn't add anything.

## Schedule and retention

A daily `Schedule` (`var.backup.schedule`, `0 3 * * *` for `dev`) backs up the whole cluster with a 30-day retention (`var.backup.ttl`, `720h`). Both are environment-specific values — see `var.backup` in `tofu/modules/backup/variables.tf`, set per environment in `tofu/live/<env>/env.hcl` — so `dev`/`prod` can tune them independently.

## Verifying backups are actually happening

```bash
velero backup get
velero schedule get
```

A healthy `Schedule` shows `STATUS: Enabled` and, after its first scheduled run, a `LASTBACKUP` timestamp. `velero backup describe <name>` shows per-resource detail; `velero backup logs <name>` shows the full log if something didn't back up as expected.

The [`velero` CLI](https://velero.io/docs/main/basic-install/#install-the-cli) isn't installed as part of cluster bootstrap — download the release matching the server's `appVersion` (currently `v1.18.1`, from `tofu/modules/backup/main.tf`'s `chart_versions.velero` pin) from the [velero releases page](https://github.com/vmware-tanzu/velero/releases), and point `kubectl`/`velero` at a current kubeconfig (`terragrunt output -raw kube_config` from `tofu/live/dev/talos-cluster/`, per `CLAUDE.md`).

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

This was verified end-to-end while standing up Velero: a namespace with a test `ConfigMap` was backed up, the namespace was deleted outright, and `velero restore create --from-backup ... --wait` brought the namespace and the `ConfigMap`'s data back correctly. Re-verified the same way after adding File System Backup (#28): a throwaway pod with real file data on a `ceph-rbd-dev` PVC, backed up, its whole namespace deleted outright, restored — the actual file content came back, not just the PVC object.

### A real gotcha found live enabling File System Backup

The first real backup attempt after flipping `deployNodeAgent = true` failed with `mkdir /udmrepo: permission denied`. Velero's kopia repository writes its config under `$HOME/udmrepo` — with the main Velero container's `runAsUser: 1000` and no matching `/etc/passwd` entry in the image, `$HOME` is unset, so kopia resolves that to the filesystem root, which a non-root UID can't write to. Fixed with an explicit `HOME=/tmp` env var (`configuration.extraEnvVars` in `tofu/modules/backup/main.tf`) — `/tmp` is writable regardless of the container's non-root securityContext. Also required moving the `velero` namespace's PSA level from `baseline` to `privileged`: `deployNodeAgent`'s DaemonSet needs real host-level access to every pod's volume mount path, same category of need as the other node-level DaemonSets in this cluster (MetalLB, csi-driver-nfs, node-exporter, ceph-csi-rbd).

### Restoring into a fresh cluster

Since Velero's own `BackupStorageLocation` points at the MinIO bucket on the NAS, a from-scratch cluster rebuild (`terragrunt run --all apply` after `terragrunt run --all destroy`, or onto new hardware) that reconnects to the *same* NFS export will have a working, populated `BackupStorageLocation` again as soon as `helm_release.velero` applies — Velero syncs existing backups from the bucket automatically, no restore-specific setup needed beyond a normal apply.
