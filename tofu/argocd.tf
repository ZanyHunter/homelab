resource "kubernetes_namespace" "metallb_system" {
  metadata {
    name = "metallb-system"
    labels = {
      "pod-security.kubernetes.io/enforce" = "privileged"
      "pod-security.kubernetes.io/audit"   = "privileged"
      "pod-security.kubernetes.io/warn"    = "privileged"
    }
  }
}

resource "helm_release" "metallb" {
  name       = "metallb"
  repository = "https://metallb.github.io/metallb"
  chart      = "metallb"
  version    = var.chart_versions.metallb
  namespace  = kubernetes_namespace.metallb_system.metadata[0].name

  depends_on = [
    talos_cluster_kubeconfig.this,
    data.talos_cluster_health.this
  ]
}

resource "time_sleep" "wait_for_metallb" {
  depends_on      = [helm_release.metallb]
  create_duration = "30s"
}

resource "terraform_data" "metallb_config" {
  depends_on = [
    helm_release.metallb,
    time_sleep.wait_for_metallb
  ]

  input = talos_cluster_kubeconfig.this.kubeconfig_raw

  provisioner "local-exec" {
    command = <<EOT
echo "${self.input}" > kubeconfig.tmp
kubectl --kubeconfig kubeconfig.tmp apply -f - <<EOF
apiVersion: metallb.io/v1beta1
kind: IPAddressPool
metadata:
  name: default-pool
  namespace: metallb-system
spec:
  addresses:
  - 192.168.160.5-192.168.160.8
  - 192.168.160.12-192.168.160.14
---
apiVersion: metallb.io/v1beta1
kind: L2Advertisement
metadata:
  name: l2-advertisement
  namespace: metallb-system
spec:
  ipAddressPools:
  - default-pool
EOF
rm -f kubeconfig.tmp
EOT
  }

  provisioner "local-exec" {
    when    = destroy
    command = <<EOT
echo "${self.input}" > kubeconfig.tmp
kubectl --kubeconfig kubeconfig.tmp delete --ignore-not-found -f - <<EOF
apiVersion: metallb.io/v1beta1
kind: IPAddressPool
metadata:
  name: default-pool
  namespace: metallb-system
---
apiVersion: metallb.io/v1beta1
kind: L2Advertisement
metadata:
  name: l2-advertisement
  namespace: metallb-system
EOF
rm -f kubeconfig.tmp
EOT
  }
}

resource "kubernetes_namespace" "ingress_nginx" {
  metadata {
    name = "ingress-nginx"
  }
}

resource "helm_release" "ingress_nginx" {
  name       = "ingress-nginx"
  repository = "https://kubernetes.github.io/ingress-nginx"
  chart      = "ingress-nginx"
  version    = var.chart_versions.ingress_nginx
  namespace  = kubernetes_namespace.ingress_nginx.metadata[0].name

  depends_on = [
    talos_cluster_kubeconfig.this,
    data.talos_cluster_health.this,
    terraform_data.metallb_config
  ]
}

resource "kubernetes_namespace" "argocd" {
  metadata {
    name = "argocd"
  }
}

resource "helm_release" "argocd" {
  name       = "argocd"
  repository = "https://argoproj.github.io/argo-helm"
  chart      = "argo-cd"
  version    = var.chart_versions.argocd
  namespace  = kubernetes_namespace.argocd.metadata[0].name

  depends_on = [
    talos_cluster_kubeconfig.this,
    data.talos_cluster_health.this,
    helm_release.ingress_nginx
  ]
  lifecycle {
    ignore_changes = [metadata]
  }

  values = [
    yamlencode({
      # Enable high-availability mode (sentinel redis, replicas, pdbs, anti-affinity)
      ha = {
        enabled = true
      }
      # Ingress configuration
      server = {
        extraArgs = ["--insecure"]
        ingress = {
          enabled          = true
          ingressClassName = "nginx"
          hostname         = "argocd.k8s.thepugh.family"
          annotations = {
            "nginx.ingress.kubernetes.io/backend-protocol" = "HTTP"
            "nginx.ingress.kubernetes.io/ssl-redirect"     = "true"
            "cert-manager.io/cluster-issuer"               = "letsencrypt-prod"
          }
          tls = true
        }
      }
    })
  ]
}
