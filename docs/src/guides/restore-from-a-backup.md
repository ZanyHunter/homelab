# Restore From a Backup

This repo's whole premise is disaster recovery, so a backup nobody has tested restoring from isn't a real backup. See [Backup and Restore](../explanation/backup-and-restore.md) for what's actually captured (object definitions always; volume *data* only for pods opted in via the `backup.velero.io/backup-volumes` annotation) before relying on this.

The [`velero` CLI](https://velero.io/docs/main/basic-install/#install-the-cli) isn't installed as part of cluster bootstrap — see [Backup and Restore](../explanation/backup-and-restore.md#verifying-backups-are-actually-happening) for how to get the right version and point it at the cluster.

---

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

## Restoring into a fresh cluster

Since Velero's own `BackupStorageLocation` points at the MinIO bucket on the NAS, a from-scratch cluster rebuild ([Deploy From Scratch](./deploy-from-scratch.md) after a full destroy, or onto new hardware) that reconnects to the *same* NFS export will have a working, populated `BackupStorageLocation` again as soon as `helm_release.velero` applies — Velero syncs existing backups from the bucket automatically, no restore-specific setup needed beyond a normal apply. The commands above then work exactly the same against the freshly-rebuilt cluster.
