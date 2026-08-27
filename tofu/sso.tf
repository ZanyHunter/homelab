# --- Postgres: Keycloak's only backing store -------------------------------
# Hand-rolled rather than a chart: a single-instance Postgres is simple enough
# that pulling in a community chart wasn't worth the pinning-risk exposure
# (see the MinIO/Bitnami note in tofu/backup.tf — the same concern applies to
# most third-party Postgres charts). Runs on the same nfs_storage-backed
# StorageClass as everything else; Postgres-on-NFS has known caveats
# (fsync/locking semantics), but at this homelab scale and write volume it's
# an accepted tradeoff — revisit if a Ceph-backed StorageClass ever exists.
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
        storage_class_name = kubernetes_storage_class.nfs.metadata[0].name
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
    helm_release.ingress_nginx,
  ]
}

# Keycloak's first-boot DB migration + bootstrap-admin creation takes longer
# than the other add-ons' 30s buffer elsewhere in this repo.
resource "time_sleep" "wait_for_keycloak" {
  depends_on      = [helm_release.keycloak]
  create_duration = "45s"
}

# --- Realm + a demo OIDC client, managed via the keycloak provider (same
# "provider talks to the app's own API declaratively" pattern already used
# for unifi_network.this) -----------------------------------------------------
resource "keycloak_realm" "homelab" {
  realm        = "homelab"
  enabled      = true
  display_name = "Homelab"

  depends_on = [time_sleep.wait_for_keycloak]
}

# A real per-app client secret should be ksops-encrypted under that app's
# apps/<app>/ directory once a real app lands (see docs/src/bootstrap-
# environment/06-gitops.md) — this demo client is Tofu-managed end-to-end
# instead, since oauth2-proxy here exists purely to prove the Keycloak wiring
# works, not as a real app.
resource "random_password" "oauth2_proxy_client_secret" {
  length  = 32
  special = false
}

resource "keycloak_openid_client" "oauth2_proxy" {
  realm_id  = keycloak_realm.homelab.id
  client_id = "oauth2-proxy"
  name      = "oauth2-proxy (forward-auth demo)"
  enabled   = true

  access_type           = "CONFIDENTIAL"
  standard_flow_enabled = true
  client_secret         = random_password.oauth2_proxy_client_secret.result

  valid_redirect_uris = ["https://sso-demo.k8s.thepugh.family/oauth2/callback"]
  web_origins         = ["+"]

  depends_on = [time_sleep.wait_for_keycloak]
}

# A real test user so the forward-auth flow can actually be logged into, not
# just have a client that exists.
resource "random_password" "demo_user_password" {
  length  = 20
  special = false
}

resource "keycloak_user" "demo" {
  realm_id = keycloak_realm.homelab.id
  username = "demo"
  enabled  = true

  email          = "demo@k8s.thepugh.family"
  email_verified = true
  first_name     = "Demo"
  last_name      = "User"

  initial_password {
    value     = random_password.demo_user_password.result
    temporary = false
  }

  depends_on = [time_sleep.wait_for_keycloak]
}

# Not read by anything — exists so the demo credentials are recoverable
# (e.g. `tofu output -raw` style, or `kubectl get secret ... -o yaml`)
# without digging through Tofu state directly.
resource "kubernetes_secret" "demo_user_credentials" {
  metadata {
    name      = "sso-demo-user-credentials"
    namespace = kubernetes_namespace.keycloak.metadata[0].name
  }

  data = {
    username = keycloak_user.demo.username
    password = random_password.demo_user_password.result
  }

  type = "Opaque"
}

# --- oauth2-proxy + whoami: the forward-auth demo/template -------------------
# Proves the Keycloak wiring end-to-end and doubles as the copy-paste
# template for real apps that need forward-auth (Grocy, etc. — see
# docs/src/bootstrap-environment/08-sso.md). Kept as a living reference
# rather than torn down after verification, since future app integrations
# will want something to copy.
resource "kubernetes_namespace" "sso_demo" {
  metadata {
    name = "sso-demo"
  }
}

resource "random_password" "oauth2_proxy_cookie_secret" {
  length  = 32
  special = false
}

resource "kubernetes_secret" "oauth2_proxy_credentials" {
  metadata {
    name      = "oauth2-proxy-credentials"
    namespace = kubernetes_namespace.sso_demo.metadata[0].name
  }

  data = {
    client-id     = keycloak_openid_client.oauth2_proxy.client_id
    client-secret = keycloak_openid_client.oauth2_proxy.client_secret
    cookie-secret = random_password.oauth2_proxy_cookie_secret.result
  }

  type = "Opaque"
}

resource "helm_release" "oauth2_proxy" {
  name       = "oauth2-proxy"
  repository = "https://oauth2-proxy.github.io/manifests"
  chart      = "oauth2-proxy"
  version    = var.chart_versions.oauth2_proxy
  namespace  = kubernetes_namespace.sso_demo.metadata[0].name

  values = [
    yamlencode({
      fullnameOverride = "oauth2-proxy"
      config = {
        existingSecret = kubernetes_secret.oauth2_proxy_credentials.metadata[0].name
      }
      extraArgs = {
        provider          = "oidc"
        "oidc-issuer-url" = "https://keycloak.k8s.thepugh.family/realms/${keycloak_realm.homelab.realm}"
        "redirect-url"    = "https://sso-demo.k8s.thepugh.family/oauth2/callback"
        "email-domain"    = "*"
        "cookie-secure"   = "true"
        scope             = "openid email profile"
        # So the X-Auth-Request-User/Email headers ingress-nginx's
        # auth-response-headers annotation copies onto the protected app's
        # request actually have something to copy.
        "set-xauthrequest" = "true"
      }
      ingress = {
        enabled   = true
        className = "nginx"
        # oauth2-proxy owns only /oauth2/* on this host; whoami's own
        # Ingress (below) handles "/" behind auth-url/auth-signin.
        path  = "/oauth2"
        hosts = ["sso-demo.k8s.thepugh.family"]
        annotations = {
          "nginx.ingress.kubernetes.io/ssl-redirect" = "true"
          # Only this Ingress requests the cert for this host — whoami's
          # Ingress below reuses the same secretName without its own
          # cluster-issuer annotation, to avoid two Certificates racing to
          # manage one Secret.
          "cert-manager.io/cluster-issuer" = "letsencrypt-prod"
        }
        tls = [
          {
            secretName = "sso-demo-tls"
            hosts      = ["sso-demo.k8s.thepugh.family"]
          }
        ]
      }
    })
  ]

  depends_on = [
    keycloak_openid_client.oauth2_proxy,
    kubernetes_secret.oauth2_proxy_credentials,
    helm_release.ingress_nginx,
  ]
}

resource "kubernetes_deployment" "whoami" {
  metadata {
    name      = "whoami"
    namespace = kubernetes_namespace.sso_demo.metadata[0].name
    labels    = { app = "whoami" }
  }

  spec {
    replicas = 1
    selector {
      match_labels = { app = "whoami" }
    }
    template {
      metadata {
        labels = { app = "whoami" }
      }
      spec {
        container {
          name  = "whoami"
          image = "traefik/whoami:v${var.whoami_version}"
          port {
            container_port = 80
          }
          resources {
            requests = {
              cpu    = "10m"
              memory = "16Mi"
            }
          }
        }
      }
    }
  }
}

resource "kubernetes_service" "whoami" {
  metadata {
    name      = "whoami"
    namespace = kubernetes_namespace.sso_demo.metadata[0].name
  }
  spec {
    selector = { app = "whoami" }
    port {
      port        = 80
      target_port = 80
    }
  }
}

resource "kubernetes_ingress_v1" "whoami" {
  metadata {
    name      = "whoami"
    namespace = kubernetes_namespace.sso_demo.metadata[0].name
    annotations = {
      "nginx.ingress.kubernetes.io/ssl-redirect"          = "true"
      "nginx.ingress.kubernetes.io/auth-url"              = "http://oauth2-proxy.${kubernetes_namespace.sso_demo.metadata[0].name}.svc.cluster.local/oauth2/auth"
      "nginx.ingress.kubernetes.io/auth-signin"           = "https://sso-demo.k8s.thepugh.family/oauth2/start?rd=$scheme://$host$request_uri"
      "nginx.ingress.kubernetes.io/auth-response-headers" = "X-Auth-Request-User,X-Auth-Request-Email"
    }
  }

  spec {
    ingress_class_name = "nginx"
    rule {
      host = "sso-demo.k8s.thepugh.family"
      http {
        path {
          path      = "/"
          path_type = "Prefix"
          backend {
            service {
              name = kubernetes_service.whoami.metadata[0].name
              port {
                number = 80
              }
            }
          }
        }
      }
    }
    tls {
      hosts       = ["sso-demo.k8s.thepugh.family"]
      secret_name = "sso-demo-tls"
    }
  }

  depends_on = [helm_release.oauth2_proxy]
}
