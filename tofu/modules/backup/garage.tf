# Garage: Velero's replacement S3 backend for MinIO (#108). MinIO's community
# images were pulled from Docker Hub and quay.io, and the project is archived,
# so it can no longer be deployed from scratch. Garage is a single static Rust
# binary; `--single-node --default-bucket` creates its own cluster layout,
# bucket, and access key straight from env vars, so unlike MinIO there's no
# post-install bootstrap Job at all (and no hook-Job NetworkPolicy gotchas).
#
# Storage split, deliberately: object *data* goes on the NFS-backed
# StorageClass, same as MinIO's did, so the bytes land on the NAS and inherit
# its offsite backup. Garage's *metadata* (a SQLite file) can't safely live on
# NFS (SQLite's file locking is unreliable there), so it sits on a small
# Ceph-backed volume instead — which means metadata shares a failure domain
# with the data Velero backs up. Mitigated by periodic metadata snapshots
# written back to the NFS volume (metadata_auto_snapshot_interval), so losing
# the Ceph volume costs at most the last interval, not the whole store.
resource "kubernetes_namespace" "garage" {
  metadata {
    name = "garage"
    labels = {
      "pod-security.kubernetes.io/enforce" = "restricted"
      "pod-security.kubernetes.io/audit"   = "restricted"
      "pod-security.kubernetes.io/warn"    = "restricted"
    }
  }
}

# Garage requires access key IDs shaped "GK" + 24 hex chars and a 64 hex char
# secret, hence random_id (hex) rather than random_password.
resource "random_id" "garage_access_key" {
  byte_length = 12
}

resource "random_id" "garage_secret_key" {
  byte_length = 32
}

resource "random_id" "garage_rpc_secret" {
  byte_length = 32
}

resource "random_password" "garage_admin_token" {
  length  = 48
  special = false
}

locals {
  garage_access_key_id = "GK${random_id.garage_access_key.hex}"
}

resource "kubernetes_secret" "garage_credentials" {
  metadata {
    name      = "garage-credentials"
    namespace = kubernetes_namespace.garage.metadata[0].name
  }

  data = {
    GARAGE_RPC_SECRET         = random_id.garage_rpc_secret.hex
    GARAGE_ADMIN_TOKEN        = random_password.garage_admin_token.result
    GARAGE_DEFAULT_ACCESS_KEY = local.garage_access_key_id
    GARAGE_DEFAULT_SECRET_KEY = random_id.garage_secret_key.hex
  }

  type = "Opaque"
}

resource "kubernetes_secret" "velero_garage_credentials" {
  metadata {
    name      = "velero-garage-credentials"
    namespace = kubernetes_namespace.velero.metadata[0].name
  }

  # Same single "cloud" key velero-plugin-for-aws expects for MinIO.
  data = {
    cloud = <<-EOT
      [default]
      aws_access_key_id=${local.garage_access_key_id}
      aws_secret_access_key=${random_id.garage_secret_key.hex}
    EOT
  }

  type = "Opaque"
}

resource "kubernetes_config_map" "garage" {
  metadata {
    name      = "garage-config"
    namespace = kubernetes_namespace.garage.metadata[0].name
  }

  data = {
    "garage.toml" = <<-EOT
      metadata_dir = "/var/lib/garage/meta"
      data_dir = "/var/lib/garage/data"
      metadata_snapshots_dir = "/var/lib/garage/snapshots"
      metadata_auto_snapshot_interval = "6h"
      db_engine = "sqlite"
      replication_factor = 1

      rpc_bind_addr = "[::]:3901"

      [s3_api]
      s3_region = "garage"
      api_bind_addr = "[::]:3900"

      [admin]
      api_bind_addr = "[::]:3903"
    EOT
  }
}

resource "kubernetes_persistent_volume_claim_v1" "garage_meta" {
  metadata {
    name      = "garage-meta"
    namespace = kubernetes_namespace.garage.metadata[0].name
  }

  spec {
    access_modes       = ["ReadWriteOnce"]
    storage_class_name = var.ceph_storage_class_name
    resources {
      requests = { storage = var.garage.meta_size }
    }
  }

  wait_until_bound = false
}

resource "kubernetes_persistent_volume_claim_v1" "garage_data" {
  metadata {
    name      = "garage-data"
    namespace = kubernetes_namespace.garage.metadata[0].name
  }

  spec {
    access_modes       = ["ReadWriteOnce"]
    storage_class_name = var.nfs_storage_class_name
    resources {
      requests = { storage = var.garage.data_size }
    }
  }

  wait_until_bound = false
}

resource "kubernetes_deployment_v1" "garage" {
  metadata {
    name      = "garage"
    namespace = kubernetes_namespace.garage.metadata[0].name
    labels    = { app = "garage" }
  }

  spec {
    replicas = 1

    # Both volumes are ReadWriteOnce and Garage must never have two writers on
    # the same metadata DB.
    strategy {
      type = "Recreate"
    }

    selector {
      match_labels = { app = "garage" }
    }

    template {
      metadata {
        labels = { app = "garage" }
        annotations = {
          # A ConfigMap change alone doesn't restart pods.
          "garage/config-hash" = sha1(kubernetes_config_map.garage.data["garage.toml"])
        }
      }

      spec {
        enable_service_links = false

        security_context {
          run_as_non_root = true
          run_as_user     = 1000
          run_as_group    = 1000
          fs_group        = 1000
          seccomp_profile {
            type = "RuntimeDefault"
          }
        }

        container {
          name    = "garage"
          image   = var.garage.image
          command = ["/garage", "server", "--single-node", "--default-bucket"]

          env {
            name  = "GARAGE_DEFAULT_BUCKET"
            value = var.garage.bucket
          }
          env_from {
            secret_ref {
              name = kubernetes_secret.garage_credentials.metadata[0].name
            }
          }

          port {
            name           = "s3"
            container_port = 3900
          }
          port {
            name           = "rpc"
            container_port = 3901
          }
          port {
            name           = "admin"
            container_port = 3903
          }

          readiness_probe {
            http_get {
              path = "/health"
              port = "admin"
            }
            period_seconds = 10
          }
          liveness_probe {
            http_get {
              path = "/health"
              port = "admin"
            }
            initial_delay_seconds = 30
            period_seconds        = 20
          }

          resources {
            requests = { cpu = "50m", memory = "128Mi" }
            limits   = { memory = "1Gi" }
          }

          # The provider serializes an unset run_as_non_root as an explicit
          # false at the container level, which "restricted" PSA rejects even
          # though the pod-level value is true — so repeat it here.
          security_context {
            allow_privilege_escalation = false
            read_only_root_filesystem  = true
            run_as_non_root            = true
            run_as_user                = 1000
            capabilities {
              drop = ["ALL"]
            }
          }

          volume_mount {
            name       = "config"
            mount_path = "/etc/garage.toml"
            sub_path   = "garage.toml"
          }
          volume_mount {
            name       = "meta"
            mount_path = "/var/lib/garage/meta"
          }
          volume_mount {
            name       = "data"
            mount_path = "/var/lib/garage/data"
            sub_path   = "data"
          }
          volume_mount {
            name       = "data"
            mount_path = "/var/lib/garage/snapshots"
            sub_path   = "snapshots"
          }
        }

        volume {
          name = "config"
          config_map {
            name = kubernetes_config_map.garage.metadata[0].name
          }
        }
        volume {
          name = "meta"
          persistent_volume_claim {
            claim_name = kubernetes_persistent_volume_claim_v1.garage_meta.metadata[0].name
          }
        }
        volume {
          name = "data"
          persistent_volume_claim {
            claim_name = kubernetes_persistent_volume_claim_v1.garage_data.metadata[0].name
          }
        }
      }
    }
  }

  # Don't block on the pod: a stuck pull/provision shouldn't fail the whole
  # backup unit's apply (MinIO's is the live backend until cutover).
  wait_for_rollout = false
}

resource "kubernetes_service_v1" "garage" {
  metadata {
    name      = "garage"
    namespace = kubernetes_namespace.garage.metadata[0].name
  }

  spec {
    selector = { app = "garage" }
    port {
      name        = "s3"
      port        = 3900
      target_port = "s3"
    }
  }
}

# velero -> garage (second BackupStorageLocation), and the matching ingress
# side. Mirrors allow-minio-egress/allow-velero-ingress.
resource "kubernetes_network_policy" "velero_allow_garage_egress" {
  metadata {
    name      = "allow-garage-egress"
    namespace = kubernetes_namespace.velero.metadata[0].name
  }

  spec {
    pod_selector {}
    policy_types = ["Egress"]

    egress {
      to {
        namespace_selector {
          match_labels = { "kubernetes.io/metadata.name" = kubernetes_namespace.garage.metadata[0].name }
        }
      }
      ports {
        port     = "3900"
        protocol = "TCP"
      }
    }
  }
}

resource "kubernetes_network_policy" "garage_allow_velero_ingress" {
  metadata {
    name      = "allow-velero-ingress"
    namespace = kubernetes_namespace.garage.metadata[0].name
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
        port     = "3900"
        protocol = "TCP"
      }
    }
  }
}
