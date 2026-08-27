# 6. NFS Storage Access

The Kubernetes cluster's persistent storage (Immich, Paperless-ngx, and other stateful workloads planned for the future) is backed by the homelab's NFS NAS (TrueNAS), reached over the network rather than managed by Tofu — see the "Known gaps" section of `CLAUDE.md` for why the NAS itself isn't under IaC management yet.

This page documents how the k8s VLAN reaches the NAS and how the NFS export backing Kubernetes storage is configured, since neither is visible from the Tofu config alone.

---

## Network path

The NAS lives on VLAN 1 (`192.168.0.11`), while the k8s cluster lives on VLAN 1601 (`192.168.160.0/27`). No additional Unifi firewall/routing rule was needed — inter-VLAN reachability to the NAS on the NFS port (2049) already worked when tested from a pod on the cluster.

The NAS is also reachable via `truenas.thepugh.family` — prefer the hostname over the raw IP in any k8s-side configuration (StorageClass, PV definitions, etc.), since the NAS may move to a different VLAN/IP in the future and the hostname would keep working without a k8s-side config change.

## NFS export

A dedicated NFS export exists for Kubernetes, separate from the NAS's other exports (which serve the existing Docker Compose Immich instance and Proxmox itself, and are IP-restricted to those specific hosts):

* **Path**: `/mnt/Main/k8s-dev`
* **Authorized network**: `192.168.160.0/27` (the k8s VLAN, network-restricted rather than open to the whole LAN)
* **Maproot user/group**: `root`/`wheel` (root squash disabled)

Root squash is disabled specifically because a dynamic NFS provisioner (planned for the storage/CSI issue) creates a new subdirectory per PersistentVolumeClaim and needs root to do so — the network-level restriction above is what keeps this export from being broadly accessible, not root-squash.

### NFSv4 is required

TrueNAS's NFS *service* (Services → NFS, separate from the per-share config above) must have NFSv4 enabled. Dynamic provisioning mounts a per-PVC subdirectory under this export rather than the export root, and that only works over NFSv4 — NFSv4's unified pseudo-filesystem lets a client mount any subdirectory of an export, while NFSv3's `mountd` protocol only accepts paths that are themselves an exact export.

This was found the hard way while standing up `csi-driver-nfs` (see the storage/CSI issue): with NFSv4 disabled, unspecified version negotiation fell back to NFSv3, the export root mounted fine, but every subdirectory mount failed with `mount.nfs: Protocol not supported`. Enabling NFSv4 service-wide fixed it — no client-side `vers=` needs to be pinned once it's on.

---

## Verification

From a pod running on the cluster:

```bash
showmount -e truenas.thepugh.family
```

Should list the export along with its authorized network:

```text
Export list for truenas.thepugh.family:
/mnt/Main/k8s-dev 192.168.160.0/27
etc.
```

A mount/write/read round-trip confirms the export is actually usable, not just visible:

```bash
mount -t nfs -o nolock truenas.thepugh.family:/mnt/Main/k8s-dev /mnt/test
echo "hello from k8s" > /mnt/test/test.txt
cat /mnt/test/test.txt
umount /mnt/test
```

Testing this requires a pod with `securityContext.privileged: true` (the `mount` syscall needs `CAP_SYS_ADMIN`, which the cluster's baseline Pod Security level doesn't grant by default) — run it in a throwaway namespace labeled `pod-security.kubernetes.io/enforce: privileged`, and delete the namespace afterward rather than leaving a permanently-privileged namespace around.
