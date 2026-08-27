# --- Postgres: Keycloak's only backing store -------------------------------
# Hand-rolled rather than a chart: a single-instance Postgres is simple enough
# that pulling in a community chart wasn't worth the pinning-risk exposure
# (see the MinIO/Bitnami note in tofu/modules/backup — the same concern
# applies to most third-party Postgres charts). Runs on the same
# nfs_storage-backed StorageClass as everything else; Postgres-on-NFS has
# known caveats (fsync/locking semantics), but at this homelab scale and
# write volume it's an accepted tradeoff — revisit if a Ceph-backed
# StorageClass ever exists (#28).
resource "kubernetes_namespace" "keycloak" {
  metadata {
    name = "keycloak"
  }
}

resource "random_password" "keycloak_db_password" {
  length  = 32
  special = false
}

resource "kubernetes_secret" "keycloak_db_credentials" {
  metadata {
    name      = "keycloak-db-credentials"
    namespace = kubernetes_namespace.keycloak.metadata[0].name
  }

  data = {
    password = random_password.keycloak_db_password.result
  }

  type = "Opaque"
}

resource "kubernetes_service" "keycloak_postgres" {
  metadata {
    name      = "keycloak-postgres"
    namespace = kubernetes_namespace.keycloak.metadata[0].name
  }

  spec {
    selector = { app = "keycloak-postgres" }
    port {
      port        = 5432
      target_port = 5432
    }
  }
}

resource "kubernetes_stateful_set_v1" "keycloak_postgres" {
  metadata {
    name      = "keycloak-postgres"
    namespace = kubernetes_namespace.keycloak.metadata[0].name
  }

  spec {
    service_name = kubernetes_service.keycloak_postgres.metadata[0].name
    replicas     = 1

    selector {
      match_labels = { app = "keycloak-postgres" }
    }

    template {
      metadata {
        labels = { app = "keycloak-postgres" }
      }

      spec {
        container {
          name  = "postgres"
          image = "postgres:${var.postgres_version}-alpine"

          port {
            container_port = 5432
          }

          env {
            name  = "POSTGRES_DB"
            value = "keycloak"
          }
          env {
            name  = "POSTGRES_USER"
            value = "keycloak"
          }
          env {
            name = "POSTGRES_PASSWORD"
            value_from {
              secret_key_ref {
                name = kubernetes_secret.keycloak_db_credentials.metadata[0].name
                key  = "password"
              }
            }
          }
          # Avoids postgres refusing to start over a non-empty mount root
          # (e.g. a stray lost+found directory from some CSI drivers).
          env {
            name  = "PGDATA"
            value = "/var/lib/postgresql/data/pgdata"
          }

          volume_mount {
            name       = "data"
            mount_path = "/var/lib/postgresql/data"
          }

          readiness_probe {
            exec {
              command = ["pg_isready", "-U", "keycloak"]
            }
            initial_delay_seconds = 5
            period_seconds        = 10
          }
          liveness_probe {
            exec {
              command = ["pg_isready", "-U", "keycloak"]
            }
            initial_delay_seconds = 30
            period_seconds        = 30
          }

          resources {
            requests = {
              cpu    = "100m"
              memory = "256Mi"
            }
          }
        }
      }
    }

    volume_claim_template {
      metadata {
        name = "data"
      }
      spec {
        access_modes       = ["ReadWriteOnce"]
        storage_class_name = var.nfs_storage_class_name
        resources {
          requests = {
            storage = "5Gi"
          }
        }
      }
    }
  }
}

# --- Keycloak ----------------------------------------------------------------
resource "random_password" "keycloak_admin_password" {
  length  = 24
  special = false
}

# Keys match what Keycloak 26.x parses at first startup to bootstrap the
# initial admin account (KC_BOOTSTRAP_ADMIN_*) — see
# docs/src/bootstrap-environment/08-sso.md.
resource "kubernetes_secret" "keycloak_admin_credentials" {
  metadata {
    name      = "keycloak-admin-credentials"
    namespace = kubernetes_namespace.keycloak.metadata[0].name
  }

  data = {
    KC_BOOTSTRAP_ADMIN_USERNAME = "admin"
    KC_BOOTSTRAP_ADMIN_PASSWORD = random_password.keycloak_admin_password.result
  }

  type = "Opaque"
}

resource "helm_release" "keycloak" {
  name       = "keycloak"
  repository = "https://codecentric.github.io/helm-charts"
  chart      = "keycloakx"
  version    = var.chart_versions.keycloak
  namespace  = kubernetes_namespace.keycloak.metadata[0].name

  values = [
    yamlencode({
      replicas = 1
      # The base Keycloak image ships with an empty CMD by design (bare
      # `kc.sh` just prints help) — the chart requires these explicitly, it
      # doesn't default them itself.
      command = ["/opt/keycloak/bin/kc.sh"]
      args    = ["start"]
      http = {
        # Modern Keycloak serves at "/" by default; the chart defaults to
        # "/auth" only for backwards compatibility with older installs.
        relativePath = "/"
      }
      proxy = {
        enabled = true
        # ingress-nginx sends X-Forwarded-* headers, not RFC7239 Forwarded.
        mode = "xforwarded"
      }
      database = {
        vendor            = "postgres"
        hostname          = kubernetes_service.keycloak_postgres.metadata[0].name
        port              = "5432"
        database          = "keycloak"
        username          = "keycloak"
        existingSecret    = kubernetes_secret.keycloak_db_credentials.metadata[0].name
        existingSecretKey = "password"
      }
      # extraEnv/extraEnvFrom are raw YAML strings in this chart (tpl'd and
      # inlined directly), not native lists — see chart's statefulset.yaml.
      extraEnv     = <<-EOT
        - name: KC_HOSTNAME
          value: https://keycloak.k8s.thepugh.family
      EOT
      extraEnvFrom = <<-EOT
        - secretRef:
            name: ${kubernetes_secret.keycloak_admin_credentials.metadata[0].name}
      EOT
      resources = {
        requests = {
          cpu    = "250m"
          memory = "768Mi"
        }
      }
      ingress = {
        enabled          = true
        ingressClassName = "nginx"
        annotations = {
          "nginx.ingress.kubernetes.io/ssl-redirect" = "true"
          "cert-manager.io/cluster-issuer"           = "letsencrypt-prod"
        }
        rules = [
          {
            host  = "keycloak.k8s.thepugh.family"
            paths = [{ path = "/", pathType = "Prefix" }]
          }
        ]
        tls = [
          {
            hosts      = ["keycloak.k8s.thepugh.family"]
            secretName = "keycloak-tls"
          }
        ]
      }
    })
  ]

  depends_on = [
    kubernetes_stateful_set_v1.keycloak_postgres,
    kubernetes_secret.keycloak_db_credentials,
    kubernetes_secret.keycloak_admin_credentials,
  ]
}

# Keycloak's first-boot DB migration + bootstrap-admin creation takes longer
# than the other add-ons' 30s buffer elsewhere in this repo.
resource "time_sleep" "wait_for_keycloak" {
  depends_on      = [helm_release.keycloak]
  create_duration = "45s"
}
