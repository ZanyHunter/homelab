# --- Realm + a demo OIDC client, managed via the keycloak provider (same
# "provider talks to the app's own API declaratively" pattern already used
# for unifi_network.this) -----------------------------------------------------
# No explicit dependency on Keycloak having finished starting: Terragrunt's
# unit-level dependency ordering already guarantees the keycloak-infra unit
# (including its time_sleep.wait_for_keycloak) is fully applied before this
# unit starts — see modules/keycloak-infra/outputs.tf.
resource "keycloak_realm" "homelab" {
  realm        = "homelab"
  enabled      = true
  display_name = "Homelab"
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

# Not read by anything — exists so the demo credentials are recoverable
# (e.g. `kubectl get secret ... -o yaml`) without digging through Tofu state
# directly. Lives in sso-demo (this unit's own namespace) rather than the
# keycloak-infra unit's "keycloak" namespace, since units can't reference
# each other's resources directly.
resource "kubernetes_secret" "demo_user_credentials" {
  metadata {
    name      = "sso-demo-user-credentials"
    namespace = kubernetes_namespace.sso_demo.metadata[0].name
  }

  data = {
    username = keycloak_user.demo.username
    password = random_password.demo_user_password.result
  }

  type = "Opaque"
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
          # oauth2-proxy's session cookie bundles Keycloak's access/ID/refresh
          # tokens, which routinely exceeds ingress-nginx's default proxy
          # buffer size — found live as a real "upstream sent too big header"
          # 502 on /oauth2/callback, not a transient issue.
          "nginx.ingress.kubernetes.io/proxy-buffer-size" = "16k"
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
