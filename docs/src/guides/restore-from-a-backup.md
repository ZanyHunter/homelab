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

## Restoring an ArgoCD-managed app next to the live one (testing)

Restoring into the *original* namespace after a disaster needs nothing special. Restoring a backed-up app into a **different** namespace on the cluster it's still running on (to test a restore without touching the live app) hits two traps, both found live while verifying the MinIO-to-Garage migration (#108) on prod:

- **ArgoCD prunes the restored copy.** Velero recreates objects exactly as backed up, including the `argocd.argoproj.io/instance: <app>` label that marks them as owned by that app. The app's auto-sync (`prune: true`) sees them as orphans not in git and deletes them within seconds, including the namespace. Velero also creates the target namespace *itself* from the backed-up namespace's labels (the label included) unless `namespaces` is in `--include-resources`, so rules that strip the label from restored objects never reach it. Fix: create the scratch namespace yourself first (without the label), and strip the label from everything restored with a [resource modifier](https://velero.io/docs/main/restore-resource-modifiers/) ConfigMap passed via `--resource-modifier-configmap` (one `mergePatches` rule per kind, `{"metadata":{"labels":{"argocd.argoproj.io/instance":null}}}`).
- **A PVC keeps pointing at the live PV.** While the original PV still exists, the restored PVC comes back with `spec.volumeName` set to it. That PV is already bound to the live claim, so the restored PVC sits `Pending`, no new volume is ever provisioned, and no data restore runs; Velero waits its 10-minute timeout and the restore ends `PartiallyFailed`. The live PV is unaffected. Fix: clear `spec.volumeName` and the `pv.kubernetes.io/bind-completed`, `pv.kubernetes.io/bound-by-controller` and `volume.kubernetes.io/selected-node` annotations in that PVC's modifier rule.

A far lighter way to confirm a migrated or rebuilt backup store works is to skip restoring a real app: check that every existing backup is listed, that `kopia-maintain` Jobs complete (they open each repository), and that a fresh backup completes through the existing repository. For a true restore test, use a small throwaway namespace instead of a live app.

## Restoring into a fresh cluster

Since Velero's own `BackupStorageLocation` points at the Garage bucket on the NAS, a from-scratch cluster rebuild ([Deploy From Scratch](./deploy-from-scratch.md) after a full destroy, or onto new hardware) that reconnects to the *same* NFS export will have a working, populated `BackupStorageLocation` again as soon as `helm_release.velero` applies — Velero syncs existing backups from the bucket automatically, no restore-specific setup needed beyond a normal apply. The commands above then work exactly the same against the freshly-rebuilt cluster.
