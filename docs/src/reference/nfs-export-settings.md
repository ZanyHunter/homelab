# NFS Export Settings

The Kubernetes cluster's persistent storage (Immich, Paperless-ngx, and other stateful workloads) is backed by the homelab's NFS NAS (TrueNAS), reached over the network rather than managed by Tofu — see the "Known gaps" section of `CLAUDE.md` for why the NAS itself isn't under IaC management yet. This page documents the export's exact settings and how the cluster reaches it, since neither is visible from the Tofu config alone. Creating this export is a one-time manual prerequisite — see the [Deploy From Scratch](../guides/deploy-from-scratch.md) guide.

---

## Network path

The NAS lives on VLAN 1 (`192.168.0.11`), while each k8s cluster lives on its own VLAN — prod on VLAN 1601 (`192.168.160.0/27`), dev on VLAN 1602 (`192.168.160.32/27`). No additional Unifi firewall/routing rule is needed — inter-VLAN reachability to the NAS on the NFS port (2049) already works when tested from a pod on either cluster.

The NAS is also reachable via `truenas.thepugh.family` — prefer the hostname over the raw IP in any k8s-side configuration (StorageClass, PV definitions, etc.), since the NAS may move to a different VLAN/IP in the future and the hostname would keep working without a k8s-side config change.

## Export settings

Dev and prod each get their own dedicated NFS export — CLAUDE.md's "dev/prod will not share infrastructure" applies here too — separate from the NAS's other exports (which serve the existing Docker Compose Immich instance and Proxmox itself, and are IP-restricted to those specific hosts):

* **Path**: `/mnt/Main/k8s-prod` (prod), `/mnt/Main/k8s-dev` (dev)
* **Authorized network**: that environment's own k8s VLAN subnet — `192.168.160.0/27` for prod, `192.168.160.32/27` for dev (network-restricted rather than open to the whole LAN)
* **Maproot user/group**: `root`/`wheel` (root squash disabled)
* **NFS service version**: NFSv4 must be enabled (Services → NFS on TrueNAS, separate from the per-share config above)

Root squash is disabled specifically because the dynamic NFS provisioner (`csi-driver-nfs`) creates a new subdirectory per PersistentVolumeClaim and needs root to do so — the network-level restriction above is what keeps this export from being broadly accessible, not root-squash.

NFSv4 is required because dynamic provisioning mounts a per-PVC subdirectory under this export rather than the export root, and that only works over NFSv4 — NFSv4's unified pseudo-filesystem lets a client mount any subdirectory of an export, while NFSv3's `mountd` protocol only accepts paths that are themselves an exact export. This was found the hard way while standing up `csi-driver-nfs`: with NFSv4 disabled, unspecified version negotiation fell back to NFSv3, the export root mounted fine, but every subdirectory mount failed with `mount.nfs: Protocol not supported`. Enabling NFSv4 service-wide fixed it — no client-side `vers=` needs to be pinned once it's on.

---

## Verification

From a pod running on the cluster:

```bash
showmount -e truenas.thepugh.family
```

Should list the export along with its authorized network:

```text
Export list for truenas.thepugh.family:
/mnt/Main/k8s-dev 192.168.160.32/27
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

## The `jellyfin-media` export: shared, not per-environment

Unlike `k8s-dev`/`k8s-prod` above, Jellyfin's media library (#52) is a third, dedicated export with genuinely different settings — see [Jellyfin](../explanation/jellyfin.md) for the full "why":

* **Path**: `/mnt/Main/jellyfin-media`
* **Authorized network**: both `192.168.160.0/27` (prod) and `192.168.160.32/27` (dev) — the one export in this repo intentionally reachable from both VLANs, since it backs one physical media library both environments' Jellyfin deployments read in place rather than each getting their own copy.
* **Access pattern**: read-only from Kubernetes (`mountOptions: [ro]` on the static PV, `apps/jellyfin/base/media-pv.yaml`) — Jellyfin never writes to this export, so root-squash/write-access settings that matter for the dynamic-provisioning exports above aren't a consideration here the same way.
* **Permissions**: files must be world-readable (or otherwise readable by whatever uid the Jellyfin pod runs as) for the non-root pod to read them — plain Unix permissions, unrelated to root-squash. See the Jellyfin page's gotchas section for a real permissions issue found live here.
* Not used by `csi-driver-nfs`/any StorageClass at all — this is a static PV pointing directly at a pre-existing, already-populated export, not a dynamic-provisioning target.
