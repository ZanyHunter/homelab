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
  # the dev export (see docs/src/reference/nfs-export-settings.md)
  # was for — the same should apply to whatever export var.nfs_storage points at
  # for other clusters.
  parameters = {
    server = var.nfs_storage.server
    share  = var.nfs_storage.share
  }

  depends_on = [helm_release.csi_driver_nfs]
}

# --- Ceph RBD storage (#28) — database/block-semantics-sensitive workloads,
# where NFS's fsync/locking semantics are a real correctness risk. External
# cluster mode: connects to the existing Proxmox Ceph cluster (ceph-1
# datastore, already backing Talos VM disks) directly — no Ceph daemons run
# inside Kubernetes. Not the default StorageClass; NFS stays default for
# general file storage, apps opt into this one per-PVC. -----------------------
resource "kubernetes_namespace" "ceph_csi_rbd" {
  metadata {
    name = "ceph-csi-rbd"
    labels = {
      # The node-plugin DaemonSet does real block-device operations
      # (rbd map/mount) on the host — same justification as csi-driver-nfs's
      # node-plugin above.
      "pod-security.kubernetes.io/enforce" = "privileged"
      "pod-security.kubernetes.io/audit"   = "privileged"
      "pod-security.kubernetes.io/warn"    = "privileged"
    }
  }
}

# CephX credential for the client manually created against var.ceph.pool_name
# only (docs/src/guides/deploy-from-scratch.md) — scoped to that one pool, not
# broad cluster access, since this is the same physical Ceph cluster backing
# every Proxmox VM disk. Tofu-managed Secret rather than the chart's own
# secret.create, matching how every other credential in this repo (MinIO,
# Grafana, Velero) is handled.
resource "kubernetes_secret" "ceph_csi_rbd_credentials" {
  metadata {
    name      = "ceph-csi-rbd-secret"
    namespace = kubernetes_namespace.ceph_csi_rbd.metadata[0].name
  }

  data = {
    userID  = var.ceph_rbd_client_id
    userKey = local.ceph_rbd_client_key[var.cluster_name]
  }

  type = "Opaque"
}

resource "helm_release" "ceph_csi_rbd" {
  name       = "ceph-csi-rbd"
  repository = "https://ceph.github.io/csi-charts"
  chart      = "ceph-csi-rbd"
  version    = var.chart_versions.ceph_csi_rbd
  namespace  = kubernetes_namespace.ceph_csi_rbd.metadata[0].name

  values = [
    yamlencode({
      csiConfig = [
        {
          clusterID = var.ceph.cluster_id
          monitors  = var.ceph.monitors
        }
      ]
      storageClass = {
        create        = true
        name          = "ceph-rbd-${var.cluster_name}"
        clusterID     = var.ceph.cluster_id
        pool          = var.ceph.pool_name
        imageFeatures = "layering"
        # Not the default — NFS (kubernetes_storage_class.nfs above) stays
        # default for general file storage; apps opt into this one per-PVC
        # for database/block-semantics-sensitive volumes only.
        reclaimPolicy           = "Delete"
        allowVolumeExpansion    = true
        provisionerSecret       = kubernetes_secret.ceph_csi_rbd_credentials.metadata[0].name
        controllerExpandSecret  = kubernetes_secret.ceph_csi_rbd_credentials.metadata[0].name
        controllerPublishSecret = kubernetes_secret.ceph_csi_rbd_credentials.metadata[0].name
        nodeStageSecret         = kubernetes_secret.ceph_csi_rbd_credentials.metadata[0].name
        # *SecretNamespace fields deliberately omitted — they default to the
        # Helm release namespace, which is where the Secret above already is.
      }
    })
  ]

  depends_on = [kubernetes_secret.ceph_csi_rbd_credentials]
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
    labels = {
      "pod-security.kubernetes.io/enforce" = "restricted"
      "pod-security.kubernetes.io/audit"   = "restricted"
      "pod-security.kubernetes.io/warn"    = "restricted"
    }
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

  values = [
    yamlencode({
      controller = {
        service = {
          annotations = {
            # Pins this Service to a fixed address instead of letting
            # MetalLB assign whatever's free in the pool (#10) — the
            # network unit's wildcard DNS record points at this exact same
            # var.ingress_ip, so it needs to be stable.
            "metallb.universe.tf/loadBalancerIPs" = var.ingress_ip
          }
        }
      }
    })
  ]

  depends_on = [helm_release.metallb]
}

resource "kubernetes_namespace" "argocd" {
  metadata {
    name = "argocd"
    labels = {
      "pod-security.kubernetes.io/enforce" = "restricted"
      "pod-security.kubernetes.io/audit"   = "restricted"
      "pod-security.kubernetes.io/warn"    = "restricted"
    }
  }
}

# SSO (#32): ArgoCD's own native OIDC support (no Dex/oauth2-proxy needed) —
# this secret is generated here, in the unit that consumes it, and passed
# downstream to keycloak-realm to create the matching keycloak_openid_client.
# See the comment on the argocd_oidc_client_secret output for why the
# dependency runs in this direction.
resource "random_password" "argocd_oidc_client_secret" {
  length  = 32
  special = false
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
          hostname         = "argocd.${var.domain_name}"
          annotations = {
            "nginx.ingress.kubernetes.io/backend-protocol" = "HTTP"
            "nginx.ingress.kubernetes.io/ssl-redirect"     = "true"
            "cert-manager.io/cluster-issuer"               = "letsencrypt-prod"
          }
          tls = true
        }
      }
      configs = {
        cm = {
          # The chart's own default ("https://argocd.example.com") is what
          # ArgoCD actually uses to build its OIDC redirect_uri (not the
          # incoming request's Host header) — left unset, Keycloak correctly
          # rejects the callback as not matching keycloak_openid_client.argocd's
          # valid_redirect_uris (#32, found live as a real login attempt).
          url = "https://argocd.${var.domain_name}"
          # Local admin disabled (#32) only after a real Keycloak login was
          # verified live through the oidc.config below — recoverable by
          # flipping this back to "true" + reapplying, same break-glass story
          # as every other Tofu-managed credential in this repo.
          "admin.enabled" = "false"
          # requestedScopes includes "groups" so RBAC below can match on
          # Keycloak group membership rather than a hardcoded per-person
          # identity — see keycloak-realm's keycloak_openid_client_scope.groups.
          "oidc.config" = yamlencode({
            name            = "Keycloak"
            issuer          = "https://keycloak.${var.domain_name}/realms/homelab"
            clientID        = "argocd"
            clientSecret    = "$oidc.keycloak.clientSecret"
            requestedScopes = ["openid", "profile", "email", "groups"]
          })
        }
        # Adds a key to argocd-secret without owning the whole object — keeps
        # the client secret out of the plaintext argocd-cm ConfigMap that
        # oidc.config above lives in.
        secret = {
          extra = {
            "oidc.keycloak.clientSecret" = random_password.argocd_oidc_client_secret.result
          }
        }
        rbac = {
          # Group-based, not tied to any specific person's identity: anyone
          # in the "platform-admins" Keycloak group gets admin. Real accounts
          # and their group membership are managed by hand in Keycloak's
          # admin console (see docs/src/explanation/sso-and-keycloak.md), not
          # in Tofu.
          "policy.csv" = "g, platform-admins, role:admin"
          "scopes"     = "[groups]"
        }
      }
    }),
    # ksops: lets ArgoCD decrypt SOPS-encrypted manifests under apps/ at sync
    # time. Patches the repo-server with the ksops/kustomize binaries (an
    # init container copies them in, overriding the built-in kustomize) and
    # mounts the same age key already used for tofu/secrets.enc.yaml so it
    # can actually decrypt. See docs/src/explanation/gitops-app-of-apps.md.
    yamlencode({
      configs = {
        cm = {
          # --enable-helm: lets a kustomization.yaml's helmCharts: field
          # inline-render a Helm chart (e.g. Immich's) alongside plain
          # manifests — the repo-server image already bundles helm itself
          # for ArgoCD's own native Helm-source support, so this is just
          # exposing it to Kustomize's own inflator too.
          "kustomize.buildOptions" = "--enable-alpha-plugins --enable-exec --enable-helm"
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
            # Only ever copies two binaries into an emptyDir — no real
            # privilege needed. Found live that this was the one gap keeping
            # the argocd namespace off "restricted" PSA (#31).
            securityContext = {
              allowPrivilegeEscalation = false
              runAsNonRoot             = true
              runAsUser                = 65534
              capabilities             = { drop = ["ALL"] }
              seccompProfile           = { type = "RuntimeDefault" }
            }
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
    labels = {
      "pod-security.kubernetes.io/enforce" = "restricted"
      "pod-security.kubernetes.io/audit"   = "restricted"
      "pod-security.kubernetes.io/warn"    = "restricted"
    }
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
# docs/src/explanation/gitops-app-of-apps.md. This Secret stays here because
# it's sourced from tofu/secrets.enc.yaml (the Cloudflare API token), and the
# ClusterIssuers' dns01.cloudflare.apiTokenSecretRef just references it by name.

# --- External Secrets Operator (#42) --------------------------------------
# Mirrors the Tofu-generated Keycloak client secrets keycloak-realm writes
# into its own keycloak-secrets namespace (see that unit's main.tf) out into
# each real app's own GitOps-managed namespace, so a keycloak-realm destroy/
# recreate or a deliberate secret rotation reaches the running app
# automatically instead of silently drifting from an already-committed
# ksops-encrypted file. Deliberately no Vault: the "external" store here is
# just another Kubernetes Secret, read via ESO's kubernetes provider — a
# narrow, conscious revisit of the ksops-over-ESO decision in CLAUDE.md's
# History (that reasoning still holds for every other secret in this repo,
# just not for this subset, which also has to independently track a live
# Tofu value). The ClusterSecretStore/ExternalSecret objects themselves are
# GitOps-managed (apps/cluster-addons/ and each app's own apps/<app>/base/),
# same "Tofu owns secret material, GitOps owns everything else" split used
# throughout this repo.
resource "kubernetes_namespace" "external_secrets" {
  metadata {
    name = "external-secrets"
    labels = {
      "pod-security.kubernetes.io/enforce" = "restricted"
      "pod-security.kubernetes.io/audit"   = "restricted"
      "pod-security.kubernetes.io/warn"    = "restricted"
    }
  }
}

# The external-secrets chart bundles its CRDs as regular chart templates
# (gated by its own installCRDs value), not Helm's protected crds/ folder —
# meaning a plain `helm uninstall` tries to delete them like any other
# templated object. Deleting a CRD blocks until every one of its CR
# instances is gone, but the 6 GitOps-managed ExternalSecret objects each
# carry ESO's own cleanup finalizer, removable only by ESO's own controller —
# which is torn down as part of that same uninstall. A real full
# `terragrunt destroy` hit exactly this deadlock (#44): Tofu's helm timeout
# expired mid-uninstall, hard-failing this whole unit's destroy and
# correctly blocking every unit downstream of it in the DAG from running at
# all. installCRDs=false below stops Helm from ever touching CRD lifecycle
# (create or delete) so this can't recur; the CRDs are applied once here
# instead, via a plain `kubectl apply` a create-only local-exec provisioner
# runs (a Terraform provisioner's shell can't reach the kubernetes/helm
# providers' own authenticated session, hence the throwaway kubeconfig built
# from var.kubernetes_client_configuration). No destroy provisioner is
# defined, so a `terraform destroy` just drops this resource from state
# without touching the live CRDs — on a full environment teardown they
# vanish along with the VMs themselves (talos-cluster destroys after
# core-addons in the DAG) rather than through a synchronous, blockable
# delete. (A destroy-time local-exec that force-strips finalizers from every
# live ExternalSecret before the Helm uninstall runs was considered instead
# and rejected — it would need the same temp-kubeconfig plumbing on the
# riskier destroy path, for no benefit over simply never asking Tofu to
# delete the CRDs at all.)
#
# files/external-secrets-crds.yaml is a pinned `helm template` render of
# templates/crds/ from this same chart version — the same "committed static
# render" idiom apps/immich/immich.yaml already uses, here because Tofu has
# no other create-only-apply primitive rather than immich.yaml's live-OCI-
# rendering bug. Regenerate it by hand whenever chart_versions.external_secrets
# bumps (the triggers block below forces a re-apply when that happens, but
# won't regenerate the file's contents for you).
resource "null_resource" "external_secrets_crds" {
  triggers = {
    chart_version = var.chart_versions.external_secrets
  }

  provisioner "local-exec" {
    interpreter = ["/bin/bash", "-c"]
    command     = <<-EOT
      set -euo pipefail
      kubeconfig_file=$(mktemp)
      trap 'rm -f "$kubeconfig_file"' EXIT
      cat > "$kubeconfig_file" <<KCFG
      apiVersion: v1
      kind: Config
      clusters:
        - name: core-addons
          cluster:
            server: ${var.kubernetes_client_configuration.host}
            certificate-authority-data: ${var.kubernetes_client_configuration.ca_certificate}
      users:
        - name: core-addons
          user:
            client-certificate-data: ${var.kubernetes_client_configuration.client_certificate}
            client-key-data: ${var.kubernetes_client_configuration.client_key}
      contexts:
        - name: core-addons
          context:
            cluster: core-addons
            user: core-addons
      current-context: core-addons
      KCFG
      kubectl --kubeconfig "$kubeconfig_file" apply --server-side --force-conflicts -f "${path.module}/files/external-secrets-crds.yaml"
    EOT
  }
}

resource "helm_release" "external_secrets" {
  name       = "external-secrets"
  repository = "https://charts.external-secrets.io"
  chart      = "external-secrets"
  version    = var.chart_versions.external_secrets
  namespace  = kubernetes_namespace.external_secrets.metadata[0].name

  values = [
    yamlencode({
      installCRDs = false
    })
  ]

  depends_on = [null_resource.external_secrets_crds]
}

# Created here (alongside ArgoCD, early in this unit's own apply) rather
# than in keycloak-realm, which populates the real Secret values into it —
# keycloak-realm is the last of core-addons' 4 dependents to apply, often
# several minutes after ArgoCD is already up and syncing
# apps/cluster-addons/'s RBAC against this same namespace name. A real
# from-scratch apply hit that race directly (#44): ArgoCD's automated sync
# hit a missing-namespace error, retried its default 5 times, then gave up
# rather than continuing — needing a manual forced sync once the namespace
# (created late, by keycloak-realm) finally existed. See
# keycloak-realm/main.tf's kubernetes_secret.*_oidc_client_secret resources
# and this unit's keycloak_secrets_namespace output.
resource "kubernetes_namespace" "keycloak_secrets" {
  metadata {
    name = "keycloak-secrets"
    labels = {
      "pod-security.kubernetes.io/enforce" = "restricted"
      "pod-security.kubernetes.io/audit"   = "restricted"
      "pod-security.kubernetes.io/warn"    = "restricted"
    }
  }
}

# cluster-addons is Tofu-managed for the identical reason keycloak-secrets
# above now is: it used to be a bare string in local.core_addons_namespaces,
# left for ArgoCD's own CreateNamespace=true to create — true on every
# previously-live cluster (ArgoCD had already synced by the time anyone
# looked), false on a real from-scratch apply, where this unit's own
# NetworkPolicies for it can be applied before ArgoCD has synced anything at
# all (#44), failing with "namespaces \"cluster-addons\" not found".
# CreateNamespace=true stays in the ApplicationSet template below regardless
# — harmless no-op once Tofu already owns the namespace, and removing it
# would mean special-casing one app out of the template every other app
# shares.
resource "kubernetes_namespace" "cluster_addons" {
  metadata {
    name = "cluster-addons"
    labels = {
      "pod-security.kubernetes.io/enforce" = "restricted"
      "pod-security.kubernetes.io/audit"   = "restricted"
      "pod-security.kubernetes.io/warn"    = "restricted"
    }
  }
}

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

# App-of-apps: one Application per apps/<app>/overlays/<cluster_name>
# directory, discovered automatically via the git directory generator — so
# adding a new app just means adding apps/<app>/base/ plus an
# overlays/<env>/ per existing environment and pushing, no Tofu change and
# no manual `kubectl apply`/`argocd app create` needed. The generator
# matches only *this* environment's overlay (apps/*/overlays/${var.cluster_name}),
# since dev/prod are entirely separate clusters/ArgoCD installs — each only
# ever syncs its own overlay, never the other's. path[1] (not
# path.basename, which would resolve to "dev"/"prod" here) picks out the
# app-name path segment regardless of overlay depth — see
# docs/src/explanation/gitops-app-of-apps.md for the base/overlays
# structure and the checklist for adding a new app or a new environment.
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
                  { path = "apps/*/overlays/${var.cluster_name}" }
                ]
              }
            }
          ]
          template = {
            metadata = {
              name = "{{path[1]}}"
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
                namespace = "{{path[1]}}"
              }
              syncPolicy = {
                automated = {
                  prune    = true
                  selfHeal = true
                }
                syncOptions = ["CreateNamespace=true"]
                # ArgoCD's own default (5 attempts, short backoff) gave up
                # permanently on a real from-scratch apply (#44) while
                # apps/cluster-addons/'s RBAC was still waiting on
                # keycloak-realm's namespace to exist, needing a manual
                # forced sync to recover. A much higher limit with a capped
                # backoff means a future race of this same shape (a
                # dependent namespace/CRD/RBAC object created by a
                # slower-to-apply Tofu unit) self-heals on its own instead.
                retry = {
                  limit = 30
                  backoff = {
                    duration    = "10s"
                    factor      = 2
                    maxDuration = "3m"
                  }
                }
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

# --- NetworkPolicies: default-deny + only the traffic each namespace
# actually needs (#31) ---------------------------------------------------
locals {
  core_addons_namespaces = merge(
    {
      csi_driver_nfs   = kubernetes_namespace.csi_driver_nfs.metadata[0].name
      ceph_csi_rbd     = kubernetes_namespace.ceph_csi_rbd.metadata[0].name
      metallb_system   = kubernetes_namespace.metallb_system.metadata[0].name
      ingress_nginx    = kubernetes_namespace.ingress_nginx.metadata[0].name
      argocd           = kubernetes_namespace.argocd.metadata[0].name
      cert_manager     = kubernetes_namespace.cert_manager.metadata[0].name
      external_secrets = kubernetes_namespace.external_secrets.metadata[0].name
      cluster_addons   = kubernetes_namespace.cluster_addons.metadata[0].name
      keycloak_secrets = kubernetes_namespace.keycloak_secrets.metadata[0].name
    },
    # Only when the Cloudflare Tunnel actually exists (var.public_ingress_enabled)
    # — otherwise there's no cloudflared namespace for these policies to attach
    # to. See the Cloudflare Tunnel section below.
    var.public_ingress_enabled ? { cloudflared = kubernetes_namespace.cloudflared[0].metadata[0].name } : {}
  )
}

resource "kubernetes_network_policy" "default_deny_all" {
  for_each = local.core_addons_namespaces

  metadata {
    name      = "default-deny-all"
    namespace = each.value
  }

  spec {
    pod_selector {}
    policy_types = ["Ingress", "Egress"]
  }
}

resource "kubernetes_network_policy" "allow_dns_egress" {
  for_each = local.core_addons_namespaces

  metadata {
    name      = "allow-dns-egress"
    namespace = each.value
  }

  spec {
    pod_selector {}
    policy_types = ["Egress"]

    egress {
      to {
        namespace_selector {
          match_labels = { "kubernetes.io/metadata.name" = "kube-system" }
        }
      }
      ports {
        port     = "53"
        protocol = "UDP"
      }
      ports {
        port     = "53"
        protocol = "TCP"
      }
    }
  }
}

resource "kubernetes_network_policy" "allow_same_namespace" {
  for_each = local.core_addons_namespaces

  metadata {
    name      = "allow-same-namespace"
    namespace = each.value
  }

  spec {
    pod_selector {}
    policy_types = ["Ingress", "Egress"]

    ingress {
      from {
        pod_selector {}
      }
    }
    egress {
      to {
        pod_selector {}
      }
    }
  }
}

# csi-driver-nfs, ceph-csi-rbd, metallb-system, argocd (application-controller),
# cert-manager (+ its webhook, via the CRD conversion path), and
# external-secrets (watches ExternalSecret/ClusterSecretStore CRs and mints
# short-lived ServiceAccount tokens via TokenRequest) all watch/write
# Kubernetes objects directly.
resource "kubernetes_network_policy" "allow_apiserver_egress" {
  for_each = {
    for k, v in local.core_addons_namespaces : k => v
    if contains(["csi_driver_nfs", "ceph_csi_rbd", "metallb_system", "argocd", "cert_manager", "external_secrets"], k)
  }

  metadata {
    name      = "allow-apiserver-egress"
    namespace = each.value
  }

  spec {
    pod_selector {}
    policy_types = ["Egress"]

    egress {
      to {
        ip_block {
          cidr = "10.96.0.1/32"
        }
      }
      ports {
        port     = "443"
        protocol = "TCP"
      }
    }
  }
}

# The apiserver calls admission/conversion webhooks directly from a
# control-plane node's real IP, not from a pod — no podSelector to match,
# hence an ipBlock over the node subnet. Needed by cert-manager-webhook,
# metallb-webhook-service, and external-secrets-webhook specifically.
resource "kubernetes_network_policy" "allow_webhook_ingress" {
  for_each = {
    for k, v in local.core_addons_namespaces : k => v
    if contains(["metallb_system", "cert_manager", "external_secrets"], k)
  }

  metadata {
    name      = "allow-webhook-ingress"
    namespace = each.value
  }

  spec {
    pod_selector {}
    policy_types = ["Ingress"]

    ingress {
      from {
        ip_block {
          cidr = var.network_cidr
        }
      }
      ports {
        port     = "443"
        protocol = "TCP"
      }
    }
  }
}

# cert-manager, argocd's repo-server (git clone over HTTPS), argocd-server's
# OIDC calls to Keycloak's external hostname (#32 — resolves back through
# ingress-nginx's LoadBalancer IP, within this 0.0.0.0/0 range), cloudflared's
# outbound-only connection to Cloudflare's edge (#33/#39), and (below)
# ingress-nginx's outbound proxying all need real internet egress.
resource "kubernetes_network_policy" "allow_internet_egress" {
  for_each = {
    for k, v in local.core_addons_namespaces : k => v
    if contains(["cert_manager", "argocd", "cloudflared"], k)
  }

  metadata {
    name      = "allow-internet-egress"
    namespace = each.value
  }

  spec {
    pod_selector {}
    policy_types = ["Egress"]

    egress {
      to {
        ip_block {
          cidr = "0.0.0.0/0"
        }
      }
      ports {
        port     = "443"
        protocol = "TCP"
      }
    }
  }
}

# Prometheus's additionalScrapeConfigs job (tofu/modules/observability)
# scrapes cert-manager's own metrics endpoint directly.
resource "kubernetes_network_policy" "cert_manager_allow_monitoring_ingress" {
  metadata {
    name      = "allow-monitoring-ingress"
    namespace = kubernetes_namespace.cert_manager.metadata[0].name
  }

  spec {
    pod_selector {}
    policy_types = ["Ingress"]

    ingress {
      from {
        namespace_selector {
          match_labels = { "kubernetes.io/metadata.name" = "monitoring" }
        }
      }
      ports {
        port     = "9402"
        protocol = "TCP"
      }
    }
  }
}

# ingress-nginx is the cluster's actual entry point: real external traffic
# (from anywhere on the LAN, via the MetalLB LoadBalancer IP) lands here, not
# just other pods — an empty ingress "from" means "allow from any source".
resource "kubernetes_network_policy" "ingress_nginx_allow_external_ingress" {
  metadata {
    name      = "allow-external-ingress"
    namespace = kubernetes_namespace.ingress_nginx.metadata[0].name
  }

  spec {
    pod_selector {}
    policy_types = ["Ingress"]

    ingress {
      ports {
        port     = "80"
        protocol = "TCP"
      }
      ports {
        port     = "443"
        protocol = "TCP"
      }
    }
  }
}

# ingress-nginx's whole job is proxying to backend Services scattered across
# every namespace in the cluster (today: argocd, keycloak, sso-demo,
# monitoring; more as real apps land under apps/) — enumerating each one
# here would need updating every time a new app gets an Ingress, so this
# scopes to the pod network CIDR broadly rather than per-namespace.
resource "kubernetes_network_policy" "ingress_nginx_allow_backend_egress" {
  metadata {
    name      = "allow-backend-egress"
    namespace = kubernetes_namespace.ingress_nginx.metadata[0].name
  }

  spec {
    pod_selector {}
    policy_types = ["Egress"]

    egress {
      to {
        ip_block {
          cidr = "10.244.0.0/16"
        }
      }
    }
  }
}

# csi-driver-nfs's controller/node-plugin pods talk to the NFS server
# directly (mount/provisioning calls) — external to the cluster, and not
# worth pinning exact NFSv4/rpcbind ports for the same reason the backup
# unit's velero/cert-manager internet-egress rules stay port-scoped-only
# rather than IP-scoped.
resource "kubernetes_network_policy" "argocd_allow_ingress_nginx" {
  metadata {
    name      = "allow-ingress-nginx"
    namespace = kubernetes_namespace.argocd.metadata[0].name
  }

  spec {
    pod_selector {
      match_labels = { "app.kubernetes.io/name" = "argocd-server" }
    }
    policy_types = ["Ingress"]

    ingress {
      from {
        namespace_selector {
          match_labels = { "kubernetes.io/metadata.name" = "ingress-nginx" }
        }
      }
    }
  }
}

resource "kubernetes_network_policy" "csi_driver_nfs_allow_server_egress" {
  metadata {
    name      = "allow-nfs-server-egress"
    namespace = kubernetes_namespace.csi_driver_nfs.metadata[0].name
  }

  spec {
    pod_selector {}
    policy_types = ["Egress"]

    egress {
      to {
        ip_block {
          cidr = "0.0.0.0/0"
        }
      }
    }
  }
}

# ceph-csi's provisioner/node-plugin talk to the Ceph monitors directly —
# scoped to the exact monitor IPs (var.ceph.monitors) rather than a broad
# allow like the NFS rule above, since those are precisely known. Both the
# legacy (6789) and msgr2 (3300) ports: ceph-csi/librbd can negotiate either
# depending on the client's messenger version, even though var.ceph.monitors
# itself only lists the 6789 addresses.
resource "kubernetes_network_policy" "ceph_csi_rbd_allow_monitor_egress" {
  metadata {
    name      = "allow-ceph-monitor-egress"
    namespace = kubernetes_namespace.ceph_csi_rbd.metadata[0].name
  }

  spec {
    pod_selector {}
    policy_types = ["Egress"]

    egress {
      dynamic "to" {
        for_each = var.ceph.monitors
        content {
          ip_block {
            cidr = "${split(":", to.value)[0]}/32"
          }
        }
      }
      ports {
        port     = "6789"
        protocol = "TCP"
      }
      ports {
        port     = "3300"
        protocol = "TCP"
      }
    }
  }
}

# --- Cloudflare Tunnel: public ingress (#33/#39/#40) --------------------------
# Outbound-only connection from cloudflared to Cloudflare's edge — no port-
# forward, no inbound rule on the router. Transport only, not an auth layer:
# every app behind it keeps using the exact same Ingress/cert-manager/
# NetworkPolicy chain LAN traffic already goes through. See
# docs/src/explanation/public-ingress.md for the full design.
#
# Gated entirely on var.public_ingress_enabled (false for dev): only prod is
# meant to be publicly exposed long-term. Dev's exposure proved the whole
# mechanism works end-to-end (including surfacing the Universal SSL and
# Keycloak redirect_uri gotchas documented below and in 14-public-ingress.md)
# and was explicitly temporary — the user has an existing Immich elsewhere
# at photos.thepugh.family they're migrating to a legacy domain before prod
# is ever stood up, so dev standing up its own conflicting public presence
# in the meantime isn't worth the redirect_uri/hostname-split complexity it
# creates. The module code stays generic (env.hcl-driven, not dev-specific)
# so prod can flip this on later with no code change, same as every other
# environment-specific value in this repo.
resource "kubernetes_namespace" "cloudflared" {
  count = var.public_ingress_enabled ? 1 : 0

  metadata {
    name = "cloudflared"
    labels = {
      "pod-security.kubernetes.io/enforce" = "restricted"
      "pod-security.kubernetes.io/audit"   = "restricted"
      "pod-security.kubernetes.io/warn"    = "restricted"
    }
  }
}

# The password a locally-managed tunnel would authenticate with — unused
# directly since config_src = "cloudflare" (remote-managed), but the API
# still requires one to create the tunnel object.
resource "random_bytes" "cloudflare_tunnel_secret" {
  count = var.public_ingress_enabled ? 1 : 0

  length = 32
}

resource "cloudflare_zero_trust_tunnel_cloudflared" "this" {
  count = var.public_ingress_enabled ? 1 : 0

  account_id    = var.cloudflare_account_id
  name          = "homelab-${var.cluster_name}"
  config_src    = "cloudflare"
  tunnel_secret = random_bytes.cloudflare_tunnel_secret[0].base64
}

# Ready-to-run connector credential for `cloudflared tunnel run --token`.
# There's no separate resource attribute for this — Terraform has to ask
# Cloudflare's API for it explicitly via this data source.
data "cloudflare_zero_trust_tunnel_cloudflared_token" "this" {
  count = var.public_ingress_enabled ? 1 : 0

  account_id = var.cloudflare_account_id
  tunnel_id  = cloudflare_zero_trust_tunnel_cloudflared.this[0].id
}

# Public hostnames live one level under public_apex_domain (thepugh.family),
# not under domain_name (dev.thepugh.family) — Cloudflare's free Universal
# SSL only covers *.thepugh.family (one level), not *.dev.thepugh.family
# (two), so a hostname built from domain_name gets no valid edge certificate
# at all and every browser sees a raw TLS handshake failure before any
# request reaches the tunnel. Found live: photos.dev.thepugh.family worked
# over plain HTTP but failed HTTPS with ERR_SSL_VERSION_OR_CYPHER_MISMATCH.
# public_hostname_suffix keeps dev/prod from colliding on the same public
# hostname for the same app once prod is real.
locals {
  public_hostnames         = { for app in var.public_apps : app.hostname => "${app.hostname}${var.public_hostname_suffix}.${var.public_apex_domain}" }
  keycloak_public_hostname = "keycloak${var.public_hostname_suffix}.${var.public_apex_domain}"
}

# Remote-managed ingress rules — allowlist only, evaluated top to bottom,
# first match wins. Each var.public_apps entry forwards its whole hostname;
# Keycloak (var.public_keycloak_realm) gets exactly one path-scoped route for
# /realms/homelab/* and nothing else — /admin, bare "/", anything not listed
# at all, falls through to the final http_status:404 catch-all, which must
# stay last. This is the actual mechanism keeping Keycloak's admin console
# internal/VPN-only: not a denylist rule that could miss a path, but nothing
# else ever being forwarded through the tunnel in the first place.
resource "cloudflare_zero_trust_tunnel_cloudflared_config" "this" {
  count = var.public_ingress_enabled ? 1 : 0

  account_id = var.cloudflare_account_id
  tunnel_id  = cloudflare_zero_trust_tunnel_cloudflared.this[0].id

  config = {
    ingress = concat(
      [
        for app in var.public_apps : {
          hostname = local.public_hostnames[app.hostname]
          # https:// + origin_server_name, not a plain http:// shortcut:
          # cloudflared validates ingress-nginx's real cert-manager-issued
          # cert before forwarding (Full-strict-equivalent for the
          # cloudflared-to-origin leg — see 14-public-ingress.md's TLS
          # section on why that's free here and worth doing properly).
          service = "https://ingress-nginx-controller.${kubernetes_namespace.ingress_nginx.metadata[0].name}.svc.cluster.local:443"
          origin_request = {
            # Rewritten back to the app's real *internal* hostname
            # (<hostname>.<domain_name>) — not the public one above —
            # since that's what ingress-nginx's existing Ingress/cert-
            # manager Certificate for this app actually matches. Without
            # this, ingress-nginx would see the public hostname (no
            # matching Ingress rule) instead and fail to route at all.
            http_host_header   = "${app.hostname}.${var.domain_name}"
            origin_server_name = "${app.hostname}.${var.domain_name}"
          }
        }
      ],
      var.public_keycloak_realm ? [
        {
          hostname = local.keycloak_public_hostname
          path     = "^/realms/homelab/.*"
          service  = "https://ingress-nginx-controller.${kubernetes_namespace.ingress_nginx.metadata[0].name}.svc.cluster.local:443"
          origin_request = {
            http_host_header   = "keycloak.${var.domain_name}"
            origin_server_name = "keycloak.${var.domain_name}"
          }
        }
      ] : [],
      [{ service = "http_status:404" }]
    )
  }
}

# Public CNAME per app, proxied (orange-clouded — required for tunnel
# routing to actually work, an unproxied/DNS-only record would just resolve
# to cfargotunnel.com with nothing behind it). Same zone/DNS-Edit scope
# cert-manager's DNS-01 already uses — no new token permission needed here.
resource "cloudflare_dns_record" "public_apps" {
  for_each = var.public_ingress_enabled ? local.public_hostnames : {}

  zone_id = var.cloudflare_zone_id
  name    = each.value
  type    = "CNAME"
  content = "${cloudflare_zero_trust_tunnel_cloudflared.this[0].id}.cfargotunnel.com"
  proxied = true
  ttl     = 1
}

resource "cloudflare_dns_record" "keycloak_public" {
  count = var.public_ingress_enabled && var.public_keycloak_realm ? 1 : 0

  zone_id = var.cloudflare_zone_id
  name    = local.keycloak_public_hostname
  type    = "CNAME"
  content = "${cloudflare_zero_trust_tunnel_cloudflared.this[0].id}.cfargotunnel.com"
  proxied = true
  ttl     = 1
}

resource "kubernetes_secret" "cloudflared_tunnel_token" {
  count = var.public_ingress_enabled ? 1 : 0

  metadata {
    name      = "cloudflared-tunnel-token"
    namespace = kubernetes_namespace.cloudflared[0].metadata[0].name
  }

  data = {
    token = data.cloudflare_zero_trust_tunnel_cloudflared_token.this[0].token
  }

  type = "Opaque"
}

# Hand-rolled, not a chart — Cloudflare doesn't publish an official Helm
# chart for cloudflared, and this repo already avoids third-party charts for
# pinned-version risk (see Postgres in keycloak-infra, MinIO in backup).
# Two replicas: Cloudflare Tunnel natively supports multiple concurrent
# connectors on the same tunnel token, so this is real redundancy for free,
# not just a cosmetic replica count.
resource "kubernetes_deployment" "cloudflared" {
  count = var.public_ingress_enabled ? 1 : 0

  metadata {
    name      = "cloudflared"
    namespace = kubernetes_namespace.cloudflared[0].metadata[0].name
    labels    = { app = "cloudflared" }
  }

  spec {
    replicas = 2
    selector {
      match_labels = { app = "cloudflared" }
    }
    template {
      metadata {
        labels = { app = "cloudflared" }
      }
      spec {
        security_context {
          run_as_non_root = true
          run_as_user     = 65532
        }
        container {
          name  = "cloudflared"
          image = "cloudflare/cloudflared:${var.cloudflared_version}"
          # --protocol http2 forces TCP-only transport to Cloudflare's edge
          # (the default would prefer QUIC/UDP), keeping the NetworkPolicy
          # below to a single TCP port instead of also opening UDP.
          args = ["tunnel", "--no-autoupdate", "--protocol", "http2", "run"]
          env {
            name = "TUNNEL_TOKEN"
            value_from {
              secret_key_ref {
                name = kubernetes_secret.cloudflared_tunnel_token[0].metadata[0].name
                key  = "token"
              }
            }
          }
          security_context {
            allow_privilege_escalation = false
            run_as_non_root            = true
            run_as_user                = 65532
            capabilities {
              drop = ["ALL"]
            }
            seccomp_profile {
              type = "RuntimeDefault"
            }
          }
          resources {
            requests = {
              cpu    = "50m"
              memory = "64Mi"
            }
            limits = {
              memory = "128Mi"
            }
          }
        }
      }
    }
  }
}

# cloudflared -> ingress-nginx's ClusterIP Service, the one in-cluster hop
# every tunneled request makes on its way to the app's own Ingress.
resource "kubernetes_network_policy" "cloudflared_allow_ingress_nginx_egress" {
  count = var.public_ingress_enabled ? 1 : 0

  metadata {
    name      = "allow-ingress-nginx-egress"
    namespace = kubernetes_namespace.cloudflared[0].metadata[0].name
  }

  spec {
    pod_selector {}
    policy_types = ["Egress"]

    egress {
      to {
        namespace_selector {
          match_labels = { "kubernetes.io/metadata.name" = kubernetes_namespace.ingress_nginx.metadata[0].name }
        }
      }
      ports {
        port     = "443"
        protocol = "TCP"
      }
    }
  }
}
