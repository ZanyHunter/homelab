resource "kubernetes_namespace" "cert_manager" {
  metadata {
    name = "cert-manager"
  }
}

resource "helm_release" "cert_manager" {
  name       = "cert-manager"
  repository = "https://charts.jetstack.io"
  chart      = "cert-manager"
  version    = "v${var.chart_versions.cert_manager}"
  namespace  = kubernetes_namespace.cert_manager.metadata[0].name

  set {
    name  = "installCRDs"
    value = "true"
  }

  depends_on = [
    talos_cluster_kubeconfig.this,
    data.talos_cluster_health.this
  ]
}

resource "kubernetes_secret" "cloudflare_api_token" {
  metadata {
    name      = "cloudflare-api-token"
    namespace = kubernetes_namespace.cert_manager.metadata[0].name
  }

  data = {
    api-token = local.cloudflare_api_token
  }

  type = "Opaque"
}

# The letsencrypt-prod and letsencrypt-staging ClusterIssuers themselves are
# managed by ArgoCD now (apps/cluster-addons/), not Tofu — see
# docs/src/bootstrap-environment/06-gitops.md. This Secret stays here because
# it's sourced from tofu/secrets.enc.yaml (the Cloudflare API token), and the
# ClusterIssuers' dns01.cloudflare.apiTokenSecretRef just references it by name.
