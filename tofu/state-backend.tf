# Exposes the S3 API port of the existing MinIO instance (tofu/backup.tf) so
# the local `tofu` client can reach it as a remote state backend (see the
# `backend "s3"` block below and docs/src/bootstrap-environment/09-remote-
# state.md) — MinIO otherwise has no ingress/LoadBalancer, since Velero reaches
# it in-cluster over ClusterIP. Only port 9000 (S3 API) gets an Ingress; the
# admin console (port 9001, service "minio-console") deliberately does not.
#
# Hostname is a literal, not a variable, matching every other ingress
# hostname in this repo (argocd/keycloak/sso-demo) — none of them derive from
# var.cluster.name today. It also has to be a literal for a different reason
# here: the `backend` block below can't reference variables/resources at all
# (OpenTofu evaluates backend config before any variables are known), so this
# hostname and the one hardcoded in that block must be kept in sync by hand.
# A real multi-environment split (#21) will need to resolve this properly —
# tracked as part of #26 (Terragrunt), which run-all's a single hostname
# scheme per environment instead of one flat config with hardcoded literals.
resource "kubernetes_ingress_v1" "minio_s3_api" {
  metadata {
    name      = "minio-s3-api"
    namespace = kubernetes_namespace.minio.metadata[0].name
    annotations = {
      "nginx.ingress.kubernetes.io/ssl-redirect" = "true"
      # State files are tiny, but the ingress-nginx default (1m) is an easy
      # thing to trip on by surprise later — disable the limit outright.
      "nginx.ingress.kubernetes.io/proxy-body-size" = "0"
      "cert-manager.io/cluster-issuer"              = "letsencrypt-prod"
    }
  }

  spec {
    ingress_class_name = "nginx"
    rule {
      host = "minio.k8s.thepugh.family"
      http {
        path {
          path      = "/"
          path_type = "Prefix"
          backend {
            service {
              name = "minio"
              port {
                number = 9000
              }
            }
          }
        }
      }
    }
    tls {
      hosts       = ["minio.k8s.thepugh.family"]
      secret_name = "minio-s3-api-tls"
    }
  }

  depends_on = [helm_release.minio, helm_release.ingress_nginx]
}
