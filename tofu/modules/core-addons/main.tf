# --- NFS storage -------------------------------------------------------------
resource "kubernetes_namespace" "csi_driver_nfs" {
  metadata {
    name = "csi-driver-nfs"
    labels = {
      # The node-plugin DaemonSet performs real mount(2) syscalls on the host and
      # needs privileged access to do so, same as metallb-system's speaker pods.
      "pod-security.kubernetes.io/enforce" = "privileged"
      "pod-security.kubernetes.io/audit"   = "privileged"
      "pod-security.kubernetes.io/warn"    = "privileged"
    }
  }
}

resource "helm_release" "csi_driver_nfs" {
  name       = "csi-driver-nfs"
  repository = "https://raw.githubusercontent.com/kubernetes-csi/csi-driver-nfs/master/charts"
  chart      = "csi-driver-nfs"
  version    = var.chart_versions.csi_driver_nfs
  namespace  = kubernetes_namespace.csi_driver_nfs.metadata[0].name
}

resource "kubernetes_storage_class" "nfs" {
  metadata {
    # Named after the cluster (e.g. "nfs-dev", "nfs-prod") since this config is
    # reused across clusters that each point at their own dedicated NFS export —
    # see var.nfs_storage.
    name = "nfs-${var.cluster_name}"
    annotations = {
      "storageclass.kubernetes.io/is-default-class" = "true"
    }
  }

  storage_provisioner    = "nfs.csi.k8s.io"
  reclaim_policy         = "Delete"
  volume_binding_mode    = "Immediate"
  allow_volume_expansion = true

  # No mount_options: this driver mounts a per-PV subdirectory under `share`,
  # which only works over NFSv4 (NFSv4's unified pseudo-filesystem allows
  # mounting arbitrary subdirectories of an export; NFSv3's mountd only accepts
  # exact export paths). TrueNAS originally had NFSv4 disabled service-wide, so
  # unspecified negotiation fell back to v3 and every subdirectory mount failed.
  # Fixed by enabling NFSv4 on the NFS service in TrueNAS — auto-negotiation now
  # picks v4.2, confirmed via a real mount showing "local_lock=none" (locks are
  # sent to the server, not just held client-local) whether or not "nolock" is
  # set — under NFSv3 that flag mattered (no rpc.statd was available inside the
  # driver's container), but NFSv4 doesn't use NLM/rpc.statd at all, so it's a
  # no-op now and left out rather than kept as misleading dead weight.

  # No subDir parameter: the driver creates one subdirectory per PV under this
  # share automatically, which is exactly what root-squash being disabled on
  # the dev export (see docs/src/bootstrap-environment/05-nfs-storage-access.md)
  # was for — the same should apply to whatever export var.nfs_storage points at
  # for other clusters.
  parameters = {
    server = var.nfs_storage.server
    share  = var.nfs_storage.share
  }

  depends_on = [helm_release.csi_driver_nfs]
}

# --- MetalLB / ingress-nginx / ArgoCD -----------------------------------------
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

  # Helm's default wait behavior blocks until this LoadBalancer Service gets
  # an external IP — which on a from-scratch bootstrap it never will in time,
  # since MetalLB's IPAddressPool is GitOps-managed (apps/cluster-addons/)
  # and ArgoCD (below, depends on this release) hasn't even been created yet
  # to sync it. Discovered via a real from-scratch destroy/recreate: on an
  # already-running cluster this never mattered, since the Service already
  # had an IP carried forward from before. MetalLB assigns the real IP
  # asynchronously once ArgoCD syncs the pool, same eventual-consistency
  # pattern already relied on for cert-manager ClusterIssuers.
  wait = false

  depends_on = [helm_release.metallb]
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
    helm_release.ingress_nginx,
    kubernetes_secret.sops_age_key
  ]

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
          # Hardcoded literal, matching every other ingress hostname in this
          # repo (keycloak/sso-demo) — none derive from a per-environment
          # domain variable yet. Real multi-environment support needs this
          # solved properly (tracked under #26/Terragrunt); out of scope for
          # this round, which only wires the VLAN/subnet through per-env.
          hostname = "argocd.k8s.thepugh.family"
          annotations = {
            "nginx.ingress.kubernetes.io/backend-protocol" = "HTTP"
            "nginx.ingress.kubernetes.io/ssl-redirect"     = "true"
            "cert-manager.io/cluster-issuer"               = "letsencrypt-prod"
          }
          tls = true
        }
      }
    }),
    # ksops: lets ArgoCD decrypt SOPS-encrypted manifests under apps/ at sync
    # time. Patches the repo-server with the ksops/kustomize binaries (an
    # init container copies them in, overriding the built-in kustomize) and
    # mounts the same age key already used for tofu/secrets.enc.yaml so it
    # can actually decrypt. See docs/src/bootstrap-environment/06-gitops.md.
    yamlencode({
      configs = {
        cm = {
          "kustomize.buildOptions" = "--enable-alpha-plugins --enable-exec"
        }
      }
      repoServer = {
        volumes = [
          { name = "custom-tools", emptyDir = {} },
          { name = "sops-age-key", secret = { secretName = kubernetes_secret.sops_age_key.metadata[0].name } }
        ]
        initContainers = [
          {
            name    = "install-ksops"
            image   = "viaductoss/ksops:v${var.ksops_version}"
            command = ["/usr/local/bin/ksops", "install", "--with-kustomize", "/custom-tools"]
            volumeMounts = [
              { name = "custom-tools", mountPath = "/custom-tools" }
            ]
          }
        ]
        volumeMounts = [
          { name = "custom-tools", mountPath = "/usr/local/bin/kustomize", subPath = "kustomize" },
          { name = "custom-tools", mountPath = "/usr/local/bin/ksops", subPath = "ksops" },
          { name = "sops-age-key", mountPath = "/app/config/sops-age", readOnly = true }
        ]
        env = [
          { name = "SOPS_AGE_KEY_FILE", value = "/app/config/sops-age/keys.txt" }
        ]
      }
    })
  ]
}

# --- cert-manager --------------------------------------------------------------
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
# managed by ArgoCD (apps/cluster-addons/), not Tofu — see
# docs/src/bootstrap-environment/06-gitops.md. This Secret stays here because
# it's sourced from tofu/secrets.enc.yaml (the Cloudflare API token), and the
# ClusterIssuers' dns01.cloudflare.apiTokenSecretRef just references it by name.

# --- GitOps: app-of-apps + ksops age key --------------------------------------
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
