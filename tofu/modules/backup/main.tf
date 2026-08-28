# MinIO: an S3-compatible gateway in front of the NFS share, since Velero
# needs an S3 API and doesn't speak NFS natively. Single-tenant standalone
# mode is plenty for homelab scale; its own data volume is just another PVC
# on the existing nfs_storage-backed StorageClass.
resource "kubernetes_namespace" "minio" {
  metadata {
    name = "minio"
    labels = {
      # The main minio Deployment itself passes "restricted" cleanly with the
      # explicit containerSecurityContext below, but the chart's post-install
      # Job (makeBucketJob/makeUserJob, creates the bucket/root user) has its
      # own separate securityContext value that only exposes {enabled,
      # runAsUser, runAsGroup} — no way to set the allowPrivilegeEscalation/
      # capabilities/seccompProfile "restricted" also requires. PSA applies
      # namespace-wide, so the whole namespace stays at "baseline" (still a
      # real improvement over the previous unrestricted default) rather than
      # patching around the chart's limited values schema for a Job that
      # only runs once at install/upgrade time.
      "pod-security.kubernetes.io/enforce" = "baseline"
      "pod-security.kubernetes.io/audit"   = "baseline"
      "pod-security.kubernetes.io/warn"    = "baseline"
    }
  }
}

resource "random_password" "minio_root_password" {
  length  = 32
  special = false
}

resource "kubernetes_secret" "minio_credentials" {
  metadata {
    name      = "minio-credentials"
    namespace = kubernetes_namespace.minio.metadata[0].name
  }

  data = {
    rootUser     = "velero-admin"
    rootPassword = random_password.minio_root_password.result
  }

  type = "Opaque"
}

resource "helm_release" "minio" {
  name       = "minio"
  repository = "https://charts.min.io/"
  chart      = "minio"
  version    = var.chart_versions.minio
  namespace  = kubernetes_namespace.minio.metadata[0].name

  values = [
    yamlencode({
      mode           = "standalone"
      existingSecret = kubernetes_secret.minio_credentials.metadata[0].name
      persistence = {
        enabled      = true
        storageClass = var.nfs_storage_class_name
        size         = var.backup.minio_storage_size
      }
      # Chart default is a 16Gi memory *request* (sized for distributed mode)
      # — wildly oversized for a single-tenant backup target.
      resources = {
        requests = {
          memory = "512Mi"
        }
      }
      containerSecurityContext = {
        allowPrivilegeEscalation = false
        capabilities             = { drop = ["ALL"] }
        runAsNonRoot             = true
        seccompProfile           = { type = "RuntimeDefault" }
      }
      buckets = [
        {
          name   = var.backup.minio_bucket
          policy = "none"
          purge  = false
        }
      ]
      # No ingress/LoadBalancer: internal-only, reached in-cluster by Velero
      # over ClusterIP (the chart default).
    })
  ]

  depends_on = [
    kubernetes_secret.minio_credentials,
  ]
}

# Velero: backs up Kubernetes object definitions (Deployments, Services,
# ConfigMaps/Secrets, PVC/PV objects, ArgoCD Applications, etc.) to the MinIO
# bucket above. File-system backup (restic/kopia, deployNodeAgent) and CSI
# volume snapshots are both left disabled: today everything is already
# NFS-backed, and that NFS share has its own offsite backup outside this
# repo's concern — backing up the same bytes a second way through Velero
# would be redundant. Revisit if a non-NFS-backed volume type shows up.
resource "kubernetes_namespace" "velero" {
  metadata {
    name = "velero"
    labels = {
      # Same story as minio above: the main Deployment (+ its
      # velero-plugin-for-aws initContainer) passes "restricted" cleanly with
      # the explicit securityContext below, but the chart's pre-upgrade
      # "velero-upgrade-crds" hook Job doesn't expose a securityContext value
      # at all — its image's default user is a non-numeric name ("cnb"),
      # which the kubelet can't verify as non-root without an explicit
      # runAsUser it has no way to set here. Namespace-wide PSA stays at
      # "baseline" because of that one hook Job.
      "pod-security.kubernetes.io/enforce" = "baseline"
      "pod-security.kubernetes.io/audit"   = "baseline"
      "pod-security.kubernetes.io/warn"    = "baseline"
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

resource "kubernetes_secret" "velero_minio_credentials" {
  metadata {
    name      = "velero-minio-credentials"
    namespace = kubernetes_namespace.velero.metadata[0].name
  }

  # velero-plugin-for-aws expects a single "cloud" key holding an AWS-style
  # credentials file — MinIO reuses its S3-compatible API for this.
  data = {
    cloud = <<-EOT
      [default]
      aws_access_key_id=velero-admin
      aws_secret_access_key=${random_password.minio_root_password.result}
    EOT
  }

  type = "Opaque"
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
        existingSecret = kubernetes_secret.velero_minio_credentials.metadata[0].name
      }
      snapshotsEnabled = false
      deployNodeAgent  = false
      configuration = {
        backupStorageLocation = [
          {
            name     = "default"
            provider = "aws"
            bucket   = var.backup.minio_bucket
            default  = true
            credential = {
              name = kubernetes_secret.velero_minio_credentials.metadata[0].name
              key  = "cloud"
            }
            config = {
              # MinIO doesn't validate AWS regions; "minio" just needs to be
              # a non-empty, consistent value.
              region           = "minio"
              s3Url            = "http://minio.${kubernetes_namespace.minio.metadata[0].name}.svc.cluster.local:9000"
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
    helm_release.minio,
    kubernetes_secret.velero_minio_credentials,
  ]
}

# --- NetworkPolicies: default-deny + only the traffic each namespace
# actually needs (#31) ---------------------------------------------------
locals {
  backup_namespaces = {
    minio  = kubernetes_namespace.minio.metadata[0].name
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

# Same-namespace pod-to-pod traffic (e.g. minio's own post-install "make
# bucket" Job talking to the minio Deployment's Service) — found live that
# without this, that Job hangs forever with no obvious error, just a stuck
# 0/1 "Running" post-upgrade hook. Applied to every namespace by default
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

# velero -> minio (backupStorageLocation), and the matching ingress side.
resource "kubernetes_network_policy" "velero_allow_minio_egress" {
  metadata {
    name      = "allow-minio-egress"
    namespace = kubernetes_namespace.velero.metadata[0].name
  }

  spec {
    pod_selector {}
    policy_types = ["Egress"]

    egress {
      to {
        namespace_selector {
          match_labels = { "kubernetes.io/metadata.name" = kubernetes_namespace.minio.metadata[0].name }
        }
      }
      ports {
        port     = "9000"
        protocol = "TCP"
      }
    }
  }
}

resource "kubernetes_network_policy" "minio_allow_velero_ingress" {
  metadata {
    name      = "allow-velero-ingress"
    namespace = kubernetes_namespace.minio.metadata[0].name
  }

  spec {
    pod_selector {}
    policy_types = ["Ingress"]

    ingress {
      from {
        namespace_selector {
          match_labels = { "kubernetes.io/metadata.name" = kubernetes_namespace.velero.metadata[0].name }
        }
      }
      ports {
        port     = "9000"
        protocol = "TCP"
      }
    }
  }
}
