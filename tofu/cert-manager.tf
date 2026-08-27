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

resource "time_sleep" "wait_for_cert_manager" {
  depends_on      = [helm_release.cert_manager]
  create_duration = "30s"
}

resource "terraform_data" "cert_manager_issuers" {
  depends_on = [
    time_sleep.wait_for_cert_manager,
    kubernetes_secret.cloudflare_api_token
  ]

  input = talos_cluster_kubeconfig.this.kubeconfig_raw

  provisioner "local-exec" {
    command = <<EOT
echo "${self.input}" > kubeconfig.tmp
kubectl --kubeconfig kubeconfig.tmp apply -f - <<EOF
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: letsencrypt-prod
spec:
  acme:
    server: https://acme-v02.api.letsencrypt.org/directory
    email: ${local.acme_email}
    privateKeySecretRef:
      name: letsencrypt-prod
    solvers:
    - dns01:
        cloudflare:
          apiTokenSecretRef:
            name: cloudflare-api-token
            key: api-token
EOF
rm -f kubeconfig.tmp
EOT
  }

  provisioner "local-exec" {
    when    = destroy
    command = <<EOT
echo "${self.input}" > kubeconfig.tmp
kubectl --kubeconfig kubeconfig.tmp delete --ignore-not-found -f - <<EOF
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: letsencrypt-prod
EOF
rm -f kubeconfig.tmp
EOT
  }
}
