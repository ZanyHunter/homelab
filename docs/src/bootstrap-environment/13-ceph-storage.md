# 14. Ceph-Backed Storage for Databases

Kubernetes has two StorageClasses: `nfs-<cluster_name>` (the default — general file storage, backed by the NFS NAS) and `ceph-rbd-<cluster_name>` (opt-in — database and other block-semantics-sensitive workloads, backed by the existing Proxmox Ceph cluster). This page covers the Ceph one.

---

## Why a second StorageClass

NFS's fsync/locking semantics are a real, documented risk for databases — not a theoretical concern (potential data corruption on unclean shutdowns, among other issues). Keycloak's hand-rolled Postgres `StatefulSet` accepted this tradeoff early on rather than block on solving it; this closes that gap (#28).

The rule of thumb: **bulk files** (photo/video libraries, documents) are fine on NFS — sequential reads, no locking-sensitivity, and it's what the NAS's disks are for. **Databases** (Postgres, and especially SQLite — SQLite is explicit that it doesn't recommend its database file live on a network filesystem at all) want the new Ceph-backed class instead. A single app can use both: e.g. Immich's Postgres on `ceph-rbd-<cluster_name>`, its photo library on `nfs-<cluster_name>`.

## What "Ceph pool" means here

No new hardware, no new Ceph cluster. The 3 Proxmox nodes already run Ceph (the `ceph-1` datastore) as hyperconverged storage for Talos VM disks — a Ceph **pool** is a logical namespace *within* that existing cluster, not a physical thing, so this is the same disks and same cluster, just a second logical bucket alongside the one VM disks already live in. An empty pool costs nothing until real data is written to it.

The pool is dedicated (`k8s-<cluster_name>-rbd`), not shared with the pool VM disks use, specifically so Kubernetes' Ceph credential can be scoped to touch *only* this pool — a bug or compromise on the Kubernetes storage side then structurally can't reach VM disk storage, even in the worst case.

## How it's wired

- **The pool itself is Tofu-managed**: `proxmox_ceph_pool.k8s_rbd` in the `talos-cluster` unit (`tofu/modules/talos-cluster/main.tf`) — `application = "rbd"`, `size = 3`/`min_size = 2` (standard 3-way replication), `add_storages = false` (not also registered as a generic Proxmox VM-disk storage target).
- **ceph-csi (RBD), external-cluster mode** — connects directly to the existing Ceph cluster; no Ceph daemons run inside Kubernetes. Deployed in `core-addons` (`tofu/modules/core-addons/main.tf`, `helm_release.ceph_csi_rbd`), parallel to `csi-driver-nfs`. Not the default StorageClass — NFS stays default, apps opt into `ceph-rbd-<cluster_name>` per-PVC.
- **`env.hcl`'s `ceph` block** (`pool_name`, `cluster_id`, `monitors`) holds the facts about the shared physical cluster — the fsid/monitor addresses are the same regardless of environment (same 3 physical nodes), only the pool name is environment-scoped so dev/prod don't collide on the same physical cluster.

## ⚠️ Required manual step: CephX credentials

Ceph's own internal authentication (CephX) is a separate system from Proxmox's PVE user/token management — the `bpg/proxmox` Tofu provider manages the pool itself but has no resource for CephX, so this **cannot be applied by Tofu alone**. On a from-scratch stand-up (or standing up prod for the first time), `core-addons` will fail to apply until this is done:

1. Apply the `talos-cluster` unit first (or at least far enough that `proxmox_ceph_pool.k8s_rbd` exists) — the pool has to exist before a CephX client can be scoped to it.
2. On any Proxmox node, create the client scoped to *only* that pool (not broad cluster access, since this is the same physical cluster backing every VM disk):

   ```bash
   ceph auth get-or-create client.k8s-<cluster_name>-rbd \
     mon 'profile rbd' \
     osd 'profile rbd pool=k8s-<cluster_name>-rbd'
   ```

3. This prints a keyring block; put the `key = ...` value into `tofu/secrets.enc.yaml` as `ceph_rbd_client_key`:

   ```bash
   sops set tofu/secrets.enc.yaml '["ceph_rbd_client_key"]' '"<the key value>"'
   ```

   (or `sops tofu/secrets.enc.yaml` for the interactive editor) — same as every other provider credential in this repo.
4. Only then does `core-addons` (which reads that secret to configure ceph-csi) apply successfully.

This has to be repeated for each environment (`k8s-dev-rbd` today; `k8s-prod-rbd` whenever prod is actually stood up) — the pool name, and therefore the CephX client, is environment-scoped even though it's the same physical Ceph cluster.

## Migrating an existing StatefulSet's PVC onto this StorageClass

Kubernetes doesn't support changing a bound PVC's `storageClassName`, and — the gotcha found live migrating Keycloak's Postgres — simply changing a StatefulSet's `volumeClaimTemplate` and letting Tofu replace the StatefulSet **does not** create a new PVC if one with the expected name (`<template-name>-<statefulset-name>-<ordinal>`) already exists: Kubernetes reuses it by name regardless of what StorageClass the new template specifies. The real procedure:

1. Take a fresh backup first (a real Velero backup, not just the steps below — see `docs/src/bootstrap-environment/07-backup-restore.md`).
2. Scale the StatefulSet to 0 replicas and `pg_dump`/`pg_dumpall` from the still-running pod before it terminates (or right after scale-down if the pod lingers).
3. Apply the `storageClassName` change in Tofu, then **explicitly delete the old PVC** — this is the step that's easy to skip, since the apply "succeeds" either way. Watch out for the StatefulSet's declared `replicas` (Tofu's normal desired state) silently scaling a fresh pod back up and re-binding to the *old* PVC before you get to delete it — scale to 0 again if that happens; the delete won't complete while any pod still references the PVC (`kubernetes.io/pvc-protection` finalizer).
4. Scale back to 1 — only now, with no same-named PVC in the way, does the StatefulSet actually provision a fresh volume on the new StorageClass.
5. A freshly-formatted Ceph RBD volume is root-owned by default. If the workload runs as a non-root UID (Postgres here runs as uid 70 — see the comment on `run_as_user` in `tofu/modules/keycloak-infra/main.tf`) and its pod spec doesn't already set `security_context.fs_group`, `initdb`/first-write fails with a real `Permission denied` — set `fs_group` to the same UID. NFS never needed this (root-squash was disabled on that export instead), so it's easy to miss when a workload's securityContext was only ever tuned against NFS.
6. `pg_restore` the dump into the fresh instance, verify a real login, only then delete anything.

## Verification

```bash
kubectl get storageclass ceph-rbd-dev
kubectl get pods -n ceph-csi-rbd
```

A real bound PVC that a pod can actually write to and read back from (not just a `StorageClass` object existing, and not just "the PVC bound" — a fresh RBD volume can still reject writes on a `fsGroup` mismatch, see above) confirms the whole chain — Ceph pool, CephX auth, ceph-csi, NetworkPolicy egress to the monitors — actually works end-to-end.
