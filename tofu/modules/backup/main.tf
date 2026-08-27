# MinIO: an S3-compatible gateway in front of the NFS share, since Velero
# needs an S3 API and doesn't speak NFS natively. Single-tenant standalone
# mode is plenty for homelab scale; its own data volume is just another PVC
# on the existing nfs_storage-backed StorageClass.
resource "kubernetes_namespace" "minio" {
  metadata {
    name = "minio"
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
        }
      ]
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
