# ArgoCD's own decryption key: the *same* age keypair already used for
# tofu/secrets.enc.yaml (see CLAUDE.md "Secrets management"), so there is
# still exactly one place the raw private key touches disk outside of git —
# this machine (and its KeePass backup) — plus this one live Kubernetes
# Secret it's sourced into.
resource "kubernetes_secret" "sops_age_key" {
  metadata {
    name      = "sops-age-key"
    namespace = kubernetes_namespace.argocd.metadata[0].name
  }

  data = {
    "keys.txt" = file(pathexpand("~/.config/sops/age/keys.txt"))
  }

  type = "Opaque"
}

# App-of-apps: one Application per direct subdirectory of apps/, discovered
# automatically via the git directory generator — adding a new app just
# means adding a new directory under apps/ and pushing, no Tofu change and
# no manual `kubectl apply`/`argocd app create` needed.
resource "helm_release" "argocd_apps" {
  name       = "argocd-apps"
  repository = "https://argoproj.github.io/argo-helm"
  chart      = "argocd-apps"
  version    = var.chart_versions.argocd_apps
  namespace  = kubernetes_namespace.argocd.metadata[0].name

  values = [
    yamlencode({
      applicationsets = {
        apps = {
          namespace = kubernetes_namespace.argocd.metadata[0].name
          # If a directory ever disappears from the generator's view (a
          # renamed/removed apps/* folder, or transient git-generator hiccup),
          # only the generated Application object gets pruned — the live
          # resources it manages (MetalLB pool, ClusterIssuers, etc.) are left
          # in place rather than cascade-deleted, and get re-adopted once a
          # matching Application reappears. Decommissioning an app for real
          # still means cleaning up its resources explicitly.
          syncPolicy = {
            preserveResourcesOnDeletion = true
          }
          generators = [
            {
              git = {
                repoURL  = var.gitops.repo_url
                revision = var.gitops.revision
                directories = [
                  { path = "apps/*" }
                ]
              }
            }
          ]
          template = {
            metadata = {
              name = "{{path.basename}}"
            }
            spec = {
              project = "default"
              source = {
                repoURL        = var.gitops.repo_url
                targetRevision = var.gitops.revision
                path           = "{{path}}"
              }
              destination = {
                server    = "https://kubernetes.default.svc"
                namespace = "{{path.basename}}"
              }
              syncPolicy = {
                automated = {
                  prune    = true
                  selfHeal = true
                }
                syncOptions = ["CreateNamespace=true"]
              }
            }
          }
        }
      }
    })
  ]

  depends_on = [
    helm_release.argocd,
    kubernetes_namespace.metallb_system,
    kubernetes_secret.cloudflare_api_token,
  ]
}
