resource "kubernetes_namespace" "csi_driver_nfs" {
  metadata {
    name = "csi-driver-nfs"
    labels = {
      # The node-plugin DaemonSet performs real mount(2) syscalls on the host and
      # needs privileged access to do so, same as metallb-system's speaker pods.
      "pod-security.kubernetes.io/enforce" = "privileged"
      "pod-security.kubernetes.io/audit"   = "privileged"
      "pod-security.kubernetes.io/warn"    = "privileged"
    }
  }
}

resource "helm_release" "csi_driver_nfs" {
  name       = "csi-driver-nfs"
  repository = "https://raw.githubusercontent.com/kubernetes-csi/csi-driver-nfs/master/charts"
  chart      = "csi-driver-nfs"
  version    = "4.13.4"
  namespace  = kubernetes_namespace.csi_driver_nfs.metadata[0].name

  depends_on = [
    talos_cluster_kubeconfig.this,
    data.talos_cluster_health.this
  ]
}

resource "kubernetes_storage_class" "nfs_dev" {
  metadata {
    name = "nfs-dev"
    annotations = {
      "storageclass.kubernetes.io/is-default-class" = "true"
    }
  }

  storage_provisioner    = "nfs.csi.k8s.io"
  reclaim_policy         = "Delete"
  volume_binding_mode    = "Immediate"
  allow_volume_expansion = true

  # No mount_options: this driver mounts a per-PV subdirectory under `share`,
  # which only works over NFSv4 (NFSv4's unified pseudo-filesystem allows
  # mounting arbitrary subdirectories of an export; NFSv3's mountd only accepts
  # exact export paths). TrueNAS originally had NFSv4 disabled service-wide, so
  # unspecified negotiation fell back to v3 and every subdirectory mount failed.
  # Fixed by enabling NFSv4 on the NFS service in TrueNAS — auto-negotiation now
  # picks v4.2, confirmed via a real mount showing "local_lock=none" (locks are
  # sent to the server, not just held client-local) whether or not "nolock" is
  # set — under NFSv3 that flag mattered (no rpc.statd was available inside the
  # driver's container), but NFSv4 doesn't use NLM/rpc.statd at all, so it's a
  # no-op now and left out rather than kept as misleading dead weight.

  # No subDir parameter: the driver creates one subdirectory per PV under this
  # share automatically, which is exactly what root-squash being disabled on
  # /mnt/Main/k8s-dev (see docs/src/bootstrap-environment/05-nfs-storage-access.md)
  # was for.
  parameters = {
    server = "truenas.thepugh.family"
    share  = "/mnt/Main/k8s-dev"
  }

  depends_on = [helm_release.csi_driver_nfs]
}
