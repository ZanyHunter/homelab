# Velero: backs up Kubernetes object definitions (Deployments, Services,
# ConfigMaps/Secrets, PVC/PV objects, ArgoCD Applications, etc.) to the Garage
# bucket (garage.tf). File-system backup (restic/kopia, deployNodeAgent) and CSI
# volume snapshots are both left disabled: today everything is already
# NFS-backed, and that NFS share has its own offsite backup outside this
# repo's concern — backing up the same bytes a second way through Velero
# would be redundant. Revisit if a non-NFS-backed volume type shows up.
resource "kubernetes_namespace" "velero" {
  metadata {
    name = "velero"
    labels = {
      # The main Deployment (+ its velero-plugin-for-aws initContainer) and
      # the chart's pre-upgrade "velero-upgrade-crds" hook Job would only need
      # "baseline" (see the securityContext comments below for the hook Job's
      # own gap) — but node-agent's DaemonSet (File System Backup, #28's
      # follow-up: actual volume data, not just object definitions) genuinely
      # needs host-level access to every pod's volume mount path
      # (nodeAgent.podVolumePath, /var/lib/kubelet/pods) and runs as root by
      # the chart's own default (nodeAgent.podSecurityContext.runAsUser: 0) —
      # same category of need as metallb-system/csi-driver-nfs/monitoring/
      # ceph-csi-rbd's node-level DaemonSets.
      "pod-security.kubernetes.io/enforce" = "privileged"
      "pod-security.kubernetes.io/audit"   = "privileged"
      "pod-security.kubernetes.io/warn"    = "privileged"
    }
  }
}

locals {
  velero_container_security_context = {
    allowPrivilegeEscalation = false
    capabilities             = { drop = ["ALL"] }
    runAsNonRoot             = true
    # Required alongside runAsNonRoot: the velero image's default user is a
    # non-numeric name ("cnb", a Cloud Native Buildpacks convention), and the
    # kubelet can't verify a non-numeric user is actually non-root without an
    # explicit numeric runAsUser — found live as a CreateContainerConfigError
    # on the chart's velero-upgrade-crds pre-upgrade hook Job.
    runAsUser      = 1000
    seccompProfile = { type = "RuntimeDefault" }
  }
}

resource "helm_release" "velero" {
  name       = "velero"
  repository = "https://vmware-tanzu.github.io/helm-charts/"
  chart      = "velero"
  version    = var.chart_versions.velero
  namespace  = kubernetes_namespace.velero.metadata[0].name

  values = [
    yamlencode({
      initContainers = [
        {
          name  = "velero-plugin-for-aws"
          image = "velero/velero-plugin-for-aws:v${var.velero_plugin_for_aws_version}"
          volumeMounts = [
            { name = "plugins", mountPath = "/target" }
          ]
          securityContext = local.velero_container_security_context
        }
      ]
      containerSecurityContext = local.velero_container_security_context
      credentials = {
        useSecret      = true
        existingSecret = kubernetes_secret.velero_garage_credentials.metadata[0].name
      }
      snapshotsEnabled = false
      # File System Backup (kopia/restic) — actual volume *data*, not just
      # Kubernetes object definitions, needed now that Ceph-backed PVCs exist
      # (#28) and aren't otherwise covered by anything (Ceph's own
      # replication protects against disk failure, not accidental/logical
      # data loss; the NAS's offsite backup only ever covered NFS-backed
      # data). Opt-in per-pod via the backup.velero.io/backup-volumes
      # annotation (see keycloak-infra's Postgres StatefulSet) rather than
      # defaultVolumesToFsBackup — deliberately not backing up every volume
      # in the cluster (Garage's own data, Loki chunks, Prometheus TSDB, etc.)
      # by default, consistent with this repo's preference for explicit
      # opt-in over broad defaults. Works identically regardless of which
      # StorageClass a PVC uses, so it's one mechanism for both NFS- and
      # Ceph-backed volumes rather than needing CSI snapshots as a second,
      # Ceph-only mechanism.
      deployNodeAgent = true
      configuration = {
        # File System Backup's kopia repository writes its config under
        # $HOME/udmrepo — with runAsUser=1000 and no matching /etc/passwd
        # entry in the image, $HOME is unset, so kopia resolves that to the
        # filesystem root and fails with "mkdir /udmrepo: permission denied".
        # Found live on the very first real backup attempt after enabling
        # File System Backup. /tmp is writable regardless of the container's
        # non-root securityContext.
        extraEnvVars = [
          { name = "HOME", value = "/tmp" }
        ]
        # Garage is the backend now (#108). The location keeps its original
        # name "default" on purpose: every existing kopia BackupRepository is
        # keyed off it (<namespace>-default-kopia), so renaming it would
        # orphan all of them. (It used to point at MinIO, retired in #108.)
        backupStorageLocation = [
          {
            name     = "default"
            provider = "aws"
            bucket   = var.garage.bucket
            default  = true
            credential = {
              name = kubernetes_secret.velero_garage_credentials.metadata[0].name
              key  = "cloud"
            }
            config = {
              # Garage validates the region against its s3_region setting.
              region           = "garage"
              s3Url            = "http://garage.${kubernetes_namespace.garage.metadata[0].name}.svc.cluster.local:3900"
              s3ForcePathStyle = "true"
            }
          }
        ]
      }
      schedules = {
        cluster-daily = {
          schedule = var.backup.schedule
          template = {
            ttl = var.backup.ttl
          }
        }
      }
    })
  ]

  depends_on = [
    kubernetes_deployment_v1.garage,
    kubernetes_secret.velero_garage_credentials,
  ]
}

# --- NetworkPolicies: default-deny + only the traffic each namespace
# actually needs (#31) ---------------------------------------------------
locals {
  backup_namespaces = {
    garage = kubernetes_namespace.garage.metadata[0].name
    velero = kubernetes_namespace.velero.metadata[0].name
  }
}

resource "kubernetes_network_policy" "default_deny_all" {
  for_each = local.backup_namespaces

  metadata {
    name      = "default-deny-all"
    namespace = each.value
  }

  spec {
    pod_selector {}
    policy_types = ["Ingress", "Egress"]
  }
}

resource "kubernetes_network_policy" "allow_dns_egress" {
  for_each = local.backup_namespaces

  metadata {
    name      = "allow-dns-egress"
    namespace = each.value
  }

  spec {
    pod_selector {}
    policy_types = ["Egress"]

    egress {
      to {
        namespace_selector {
          match_labels = { "kubernetes.io/metadata.name" = "kube-system" }
        }
      }
      ports {
        port     = "53"
        protocol = "UDP"
      }
      ports {
        port     = "53"
        protocol = "TCP"
      }
    }
  }
}

# Same-namespace pod-to-pod traffic (e.g. a chart's post-install Job talking to
# its own Deployment's Service) — found live, with MinIO's old "make bucket"
# hook Job, that without this such a Job hangs forever with no obvious error,
# just a stuck 0/1 "Running" post-upgrade hook. Applied to every namespace by default
# rather than judged case-by-case per pod, since a helper Job/sidecar's
# same-namespace traffic need is easy to miss ahead of time.
resource "kubernetes_network_policy" "allow_same_namespace" {
  for_each = local.backup_namespaces

  metadata {
    name      = "allow-same-namespace"
    namespace = each.value
  }

  spec {
    pod_selector {}
    policy_types = ["Ingress", "Egress"]

    ingress {
      from {
        pod_selector {}
      }
    }
    egress {
      to {
        pod_selector {}
      }
    }
  }
}

# velero's controller reads/writes Kubernetes objects directly.
resource "kubernetes_network_policy" "velero_allow_apiserver_egress" {
  metadata {
    name      = "allow-apiserver-egress"
    namespace = kubernetes_namespace.velero.metadata[0].name
  }

  spec {
    pod_selector {}
    policy_types = ["Egress"]

    egress {
      to {
        # The in-cluster kubernetes.default.svc ClusterIP is stable and has
        # no pod selector to match against, hence an ipBlock instead.
        ip_block {
          cidr = "10.96.0.1/32"
        }
      }
      ports {
        port     = "443"
        protocol = "TCP"
      }
    }
  }
}

# Prometheus's additionalScrapeConfigs job (tofu/modules/observability)
# scrapes Velero's own metrics endpoint directly.
resource "kubernetes_network_policy" "velero_allow_monitoring_ingress" {
  metadata {
    name      = "allow-monitoring-ingress"
    namespace = kubernetes_namespace.velero.metadata[0].name
  }

  spec {
    pod_selector {}
    policy_types = ["Ingress"]

    ingress {
      from {
        namespace_selector {
          match_labels = { "kubernetes.io/metadata.name" = "monitoring" }
        }
      }
      ports {
        port     = "8085"
        protocol = "TCP"
      }
    }
  }
}
