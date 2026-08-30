# Ceph-Backed Storage for Databases

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

**CephX credentials** (Ceph's own internal auth, separate from Proxmox's PVE user management) can't be Tofu-managed — see the [Deploy From Scratch](../guides/deploy-from-scratch.md) guide's prerequisites for the required manual bootstrap step, and [Stand Up a New Environment](../guides/stand-up-a-new-environment.md) for repeating it on a new environment.

## Verification

```bash
kubectl get storageclass ceph-rbd-dev
kubectl get pods -n ceph-csi-rbd
```

A real bound PVC that a pod can actually write to and read back from (not just a `StorageClass` object existing, and not just "the PVC bound" — a fresh RBD volume can still reject writes on a `fsGroup` mismatch, see [Migrate Storage to Ceph](../guides/migrate-storage-to-ceph.md)) confirms the whole chain — Ceph pool, CephX auth, ceph-csi, NetworkPolicy egress to the monitors — actually works end-to-end.
