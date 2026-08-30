# Migrate Storage to Ceph

How to move an existing StatefulSet's PVC from the NFS-backed StorageClass onto the Ceph-backed one — e.g. because it's a database that needs real block-storage locking semantics. See [Ceph-Backed Storage](../explanation/ceph-backed-storage.md) for why that distinction matters.

Kubernetes doesn't support changing a bound PVC's `storageClassName`, and simply changing a StatefulSet's `volumeClaimTemplate` and letting Tofu replace the StatefulSet **does not** create a new PVC if one with the expected name (`<template-name>-<statefulset-name>-<ordinal>`) already exists — Kubernetes reuses it by name regardless of what StorageClass the new template specifies. This is a real gotcha found live migrating Keycloak's Postgres; the procedure below accounts for it.

---

1. Take a fresh backup first (a real Velero backup, not just the steps below — see [Restore From a Backup](./restore-from-a-backup.md)).
2. Scale the StatefulSet to 0 replicas and `pg_dump`/`pg_dumpall` from the still-running pod before it terminates (or right after scale-down if the pod lingers).
3. Apply the `storageClassName` change in Tofu, then **explicitly delete the old PVC** — this is the step that's easy to skip, since the apply "succeeds" either way. Watch out for the StatefulSet's declared `replicas` (Tofu's normal desired state) silently scaling a fresh pod back up and re-binding to the *old* PVC before you get to delete it — scale to 0 again if that happens; the delete won't complete while any pod still references the PVC (`kubernetes.io/pvc-protection` finalizer).
4. Scale back to 1 — only now, with no same-named PVC in the way, does the StatefulSet actually provision a fresh volume on the new StorageClass.
5. A freshly-formatted Ceph RBD volume is root-owned by default. If the workload runs as a non-root UID and its pod spec doesn't already set `security_context.fs_group`, `initdb`/first-write fails with a real `Permission denied` — set `fs_group` to that UID. NFS never needed this (root-squash was disabled on that export instead), so it's easy to miss when a workload's securityContext was only ever tuned against NFS.
6. `pg_restore` the dump into the fresh instance, verify a real login, only then delete anything.

## Verification

```bash
kubectl get storageclass ceph-rbd-dev
kubectl get pods -n ceph-csi-rbd
```

A real bound PVC that a pod can actually write to and read back from (not just a `StorageClass` object existing, and not just "the PVC bound" — a fresh RBD volume can still reject writes on a `fsGroup` mismatch, see step 5 above) confirms the whole chain — Ceph pool, CephX auth, ceph-csi, NetworkPolicy egress to the monitors — actually works end-to-end.
