# --- kube-prometheus-stack: Prometheus + Alertmanager + Grafana + node-exporter
# + kube-state-metrics, one chart --------------------------------------------
# One namespace for the whole observability stack (Prometheus, Alertmanager,
# Grafana, Loki, Alloy) — node-exporter (hostNetwork/hostPID, /proc+/sys
# hostPath) and Alloy (hostPath log mounts) both do real host-level things,
# same justification already used for metallb-system/csi-driver-nfs.
resource "kubernetes_namespace" "monitoring" {
  metadata {
    name = "monitoring"
    labels = {
      "pod-security.kubernetes.io/enforce" = "privileged"
      "pod-security.kubernetes.io/audit"   = "privileged"
      "pod-security.kubernetes.io/warn"    = "privileged"
    }
  }
}

resource "random_password" "grafana_admin_password" {
  length  = 24
  special = false
}

resource "kubernetes_secret" "grafana_admin_credentials" {
  metadata {
    name      = "grafana-admin-credentials"
    namespace = kubernetes_namespace.monitoring.metadata[0].name
  }

  data = {
    admin-user     = "admin"
    admin-password = random_password.grafana_admin_password.result
  }

  type = "Opaque"
}

# SSO (#32): Grafana's own native OIDC support (auth.generic_oauth, no
# oauth2-proxy sidecar needed) — this secret is generated here, in the unit
# that consumes it, and passed downstream to keycloak-realm to create the
# matching keycloak_openid_client. See the comment on the
# grafana_oidc_client_secret output for why the dependency runs in this
# direction.
resource "random_password" "grafana_oidc_client_secret" {
  length  = 32
  special = false
}

# Kept in its own Secret (sourced into the pod via envValueFrom below) rather
# than inline in the "grafana.ini" values block, so the client secret doesn't
# end up in the plaintext-rendered grafana.ini ConfigMap — same reasoning as
# grafana-admin-credentials/MinIO/Velero already isolating credentials this way.
resource "kubernetes_secret" "grafana_oidc_credentials" {
  metadata {
    name      = "grafana-oidc-credentials"
    namespace = kubernetes_namespace.monitoring.metadata[0].name
  }

  data = {
    client-secret = random_password.grafana_oidc_client_secret.result
  }

  type = "Opaque"
}

# Any Deployment/StatefulSet control-plane taint tolerated here so
# node-exporter and Alloy actually land on all 6 nodes, control planes
# included — both charts default to no tolerations at all, which would
# otherwise silently skip metrics/logs from 3 of this cluster's 6 nodes.
locals {
  tolerate_control_plane = [
    { operator = "Exists", effect = "NoSchedule" }
  ]
}

resource "helm_release" "kube_prometheus_stack" {
  name       = "kube-prometheus-stack"
  repository = "https://prometheus-community.github.io/helm-charts"
  chart      = "kube-prometheus-stack"
  version    = var.chart_versions.kube_prometheus_stack
  namespace  = kubernetes_namespace.monitoring.metadata[0].name

  values = [
    yamlencode({
      prometheus-node-exporter = {
        tolerations = local.tolerate_control_plane
      }

      # Talos runs kube-proxy/kube-scheduler/kube-controller-manager bound to
      # loopback only, not reachable on the node IP the way a kubeadm cluster
      # exposes them — this chart's default scrape jobs for all three assume
      # kubeadm-style host-network exposure. Found live as 3 permanently
      # firing TargetDown alerts ("connection refused" on the node IPs) the
      # first time a real alert round-tripped through Alertmanager. Disabling
      # the scrape jobs and their matching default alert-rule groups rather
      # than chasing Talos-side metrics exposure, which is out of scope here.
      kubeControllerManager = { enabled = false }
      kubeScheduler         = { enabled = false }
      kubeProxy             = { enabled = false }
      defaultRules = {
        rules = {
          kubeControllerManager  = false
          kubeSchedulerAlerting  = false
          kubeSchedulerRecording = false
          kubeProxy              = false
        }
      }

      prometheus = {
        prometheusSpec = {
          retention = "15d"
          storageSpec = {
            volumeClaimTemplate = {
              spec = {
                storageClassName = var.nfs_storage_class_name
                accessModes      = ["ReadWriteOnce"]
                resources = {
                  requests = { storage = "20Gi" }
                }
              }
            }
          }

          # cert-manager and Velero both expose Prometheus-annotation-style
          # metrics (prometheus.io/scrape, .../port, .../path — on by default
          # in both charts, no values change needed on their side) but don't
          # get a ServiceMonitor from this repo: a ServiceMonitor living in
          # core-addons/backup would need this chart's Prometheus Operator
          # CRDs to already exist, but core-addons/backup apply *before*
          # observability in the Terragrunt DAG — a real ordering conflict.
          # additionalScrapeConfigs avoids it entirely: it's just Prometheus
          # config, rendered by this same helm_release, no CRD involved.
          additionalScrapeConfigs = [
            {
              job_name = "cert-manager"
              kubernetes_sd_configs = [
                { role = "pod", namespaces = { names = ["cert-manager"] } }
              ]
              relabel_configs = [
                { source_labels = ["__meta_kubernetes_pod_annotation_prometheus_io_scrape"], action = "keep", regex = "true" },
                { source_labels = ["__meta_kubernetes_pod_annotation_prometheus_io_path"], action = "replace", target_label = "__metrics_path__", regex = "(.+)" },
                { source_labels = ["__address__", "__meta_kubernetes_pod_annotation_prometheus_io_port"], action = "replace", regex = "([^:]+)(?::\\d+)?;(\\d+)", replacement = "$1:$2", target_label = "__address__" },
                { source_labels = ["__meta_kubernetes_namespace"], action = "replace", target_label = "namespace" },
                { source_labels = ["__meta_kubernetes_pod_name"], action = "replace", target_label = "pod" },
              ]
            },
            {
              job_name = "velero"
              kubernetes_sd_configs = [
                { role = "pod", namespaces = { names = ["velero"] } }
              ]
              relabel_configs = [
                { source_labels = ["__meta_kubernetes_pod_annotation_prometheus_io_scrape"], action = "keep", regex = "true" },
                { source_labels = ["__meta_kubernetes_pod_annotation_prometheus_io_path"], action = "replace", target_label = "__metrics_path__", regex = "(.+)" },
                { source_labels = ["__address__", "__meta_kubernetes_pod_annotation_prometheus_io_port"], action = "replace", regex = "([^:]+)(?::\\d+)?;(\\d+)", replacement = "$1:$2", target_label = "__address__" },
                { source_labels = ["__meta_kubernetes_namespace"], action = "replace", target_label = "namespace" },
                { source_labels = ["__meta_kubernetes_pod_name"], action = "replace", target_label = "pod" },
              ]
            }
          ]
        }
      }

      # Node-down, pod-crashlooping, and PVC-nearly-full are all already
      # covered by this chart's own bundled default rules (defaultRules.create
      # is on by default) — only cert-manager cert expiry and Velero backup
      # staleness need a rule of our own. additionalPrometheusRulesMap is
      # rendered by this same helm_release (same reasoning as
      # additionalScrapeConfigs above: no separate PrometheusRule CR, no CRD
      # ordering risk).
      additionalPrometheusRulesMap = {
        cert-manager-and-velero-alerts = {
          groups = [
            {
              name = "cert-manager.rules"
              rules = [
                {
                  alert  = "CertManagerCertificateExpiringSoon"
                  expr   = "certmanager_certificate_expiration_timestamp_seconds - time() < 86400 * 7"
                  for    = "1h"
                  labels = { severity = "warning" }
                  annotations = {
                    summary     = "Certificate {{ $labels.name }}/{{ $labels.exported_namespace }} expires in under 7 days"
                    description = "cert-manager reports {{ $labels.name }} in {{ $labels.exported_namespace }} expiring soon — check `kubectl get certificate -A`."
                  }
                }
              ]
            },
            {
              name = "velero.rules"
              rules = [
                {
                  alert = "VeleroBackupStale"
                  # 100000s (~27.8h) gives the daily 03:00 schedule (var.backup.schedule
                  # in the backup unit) a buffer past 24h before paging.
                  expr   = "time() - max(velero_backup_last_successful_timestamp) by (schedule) > 100000"
                  for    = "1h"
                  labels = { severity = "critical" }
                  annotations = {
                    summary     = "Velero schedule {{ $labels.schedule }} has no successful backup in over 24h"
                    description = "No successful Velero backup for schedule {{ $labels.schedule }} recently — check `velero backup get`."
                  }
                }
              ]
            }
          ]
        }
      }

      alertmanager = {
        config = {
          route = {
            group_by        = ["namespace"]
            group_wait      = "30s"
            group_interval  = "5m"
            repeat_interval = "12h"
            receiver        = "discord"
            routes = [
              # The chart's always-firing Watchdog heartbeat stays routed to
              # null — it exists to prove the alerting pipeline itself is
              # alive, not to page anyone every 12h.
              { receiver = "null", matchers = ["alertname = \"Watchdog\""] }
            ]
          }
          receivers = [
            { name = "null" },
            {
              name = "discord"
              discord_configs = [
                { webhook_url = local.discord_alert_webhook, send_resolved = true }
              ]
            }
          ]
        }
      }

      grafana = {
        admin = {
          existingSecret = kubernetes_secret.grafana_admin_credentials.metadata[0].name
          userKey        = "admin-user"
          passwordKey    = "admin-password"
        }
        # Sources the OIDC client secret from its own Secret rather than
        # inlining it in "grafana.ini" below, which renders into a plaintext
        # ConfigMap — grafana.ini references it back via $__env{}. Map keyed
        # by env var name (not a list) — see chart's templates/_pod.tpl.
        envValueFrom = {
          GF_AUTH_GENERIC_OAUTH_CLIENT_SECRET = {
            secretKeyRef = {
              name = kubernetes_secret.grafana_oidc_credentials.metadata[0].name
              key  = "client-secret"
            }
          }
        }
        "grafana.ini" = {
          server = {
            root_url = "https://grafana.k8s.thepugh.family"
          }
          auth = {
            # Hides the local-login UI so normal users go through Keycloak.
            disable_login_form = true
          }
          "auth.basic" = {
            # Local admin disabled (#32) only after a real Keycloak login was
            # verified live through auth.generic_oauth below — this is what
            # actually blocks the local admin login (disable_login_form alone
            # still leaves basic-auth reachable via direct API calls).
            # Recoverable by flipping this back + reapplying, same
            # break-glass story as every other Tofu-managed credential here.
            enabled = false
          }
          "auth.generic_oauth" = {
            enabled       = true
            name          = "Keycloak"
            client_id     = "grafana"
            client_secret = "$__env{GF_AUTH_GENERIC_OAUTH_CLIENT_SECRET}"
            # "groups" so role_attribute_path below can match on Keycloak
            # group membership rather than a hardcoded per-person identity —
            # see keycloak-realm's keycloak_openid_client_scope.groups.
            scopes              = "openid email profile groups"
            auth_url            = "https://keycloak.k8s.thepugh.family/realms/homelab/protocol/openid-connect/auth"
            token_url           = "https://keycloak.k8s.thepugh.family/realms/homelab/protocol/openid-connect/token"
            api_url             = "https://keycloak.k8s.thepugh.family/realms/homelab/protocol/openid-connect/userinfo"
            role_attribute_path = "contains(groups[*], 'platform-admins') && 'Admin' || 'Viewer'"
            allow_sign_up       = true
          }
        }
        persistence = {
          enabled          = true
          storageClassName = var.nfs_storage_class_name
          size             = "2Gi"
        }
        # kube-prometheus-stack auto-provisions its own Prometheus/Alertmanager
        # datasources; Loki isn't part of this chart, so it needs adding here.
        additionalDataSources = [
          {
            name      = "Loki"
            type      = "loki"
            access    = "proxy"
            url       = "http://loki-gateway.${kubernetes_namespace.monitoring.metadata[0].name}.svc.cluster.local"
            isDefault = false
          }
        ]
        ingress = {
          enabled          = true
          ingressClassName = "nginx"
          hosts            = ["grafana.k8s.thepugh.family"]
          annotations = {
            "nginx.ingress.kubernetes.io/ssl-redirect" = "true"
            "cert-manager.io/cluster-issuer"           = "letsencrypt-prod"
          }
          tls = [
            {
              secretName = "grafana-tls"
              hosts      = ["grafana.k8s.thepugh.family"]
            }
          ]
        }
      }
    })
  ]

  depends_on = [
    kubernetes_secret.grafana_admin_credentials,
    kubernetes_secret.grafana_oidc_credentials,
  ]
}

# --- Loki: log storage, Monolithic mode (SingleBinary in the chart's own
# terminology) — homelab scale, no object storage dependency, everything on
# the same nfs_storage-backed StorageClass as the rest of this repo ----------
resource "helm_release" "loki" {
  name       = "loki"
  repository = "https://grafana.github.io/helm-charts"
  chart      = "loki"
  version    = var.chart_versions.loki
  namespace  = kubernetes_namespace.monitoring.metadata[0].name

  values = [
    yamlencode({
      deploymentMode = "SingleBinary"
      # SimpleScalable/Distributed component replicas must be zeroed out
      # when running SingleBinary mode — the chart validates this.
      read    = { replicas = 0 }
      write   = { replicas = 0 }
      backend = { replicas = 0 }

      # Both are optional memcached-based query-performance caches, not
      # required for Loki to function — and both default to a memory request
      # sized for a much larger deployment (chunksCache alone requests ~8Gi)
      # than any single node in this 6-node/4GB-RAM-per-node cluster has,
      # which left loki-chunks-cache-0 permanently unschedulable
      # ("Insufficient memory" on all 6 nodes) on the first real apply. Same
      # class of oversized-chart-default problem already hit with MinIO
      # (tofu/modules/backup/main.tf) — not worth tuning a cache size for at
      # this log volume, so just disabled.
      resultsCache = { enabled = false }
      chunksCache  = { enabled = false }

      loki = {
        auth_enabled = false # single-tenant homelab use, not multi-tenant SaaS
        commonConfig = {
          replication_factor = 1
        }
        storage = {
          type = "filesystem"
        }
        schemaConfig = {
          configs = [
            {
              from         = "2024-01-01"
              store        = "tsdb"
              object_store = "filesystem"
              schema       = "v13"
              index = {
                prefix = "loki_index_"
                period = "24h"
              }
            }
          ]
        }
      }

      singleBinary = {
        replicas = 1
        persistence = {
          enabled      = true
          storageClass = var.nfs_storage_class_name
          size         = "20Gi"
        }
      }
    })
  ]
}

# --- Alloy: ships every pod's container logs into Loki, labeled by
# namespace/pod/container — the current, maintained log-shipping agent
# (Promtail is deprecated) ----------------------------------------------------
resource "helm_release" "alloy" {
  name       = "alloy"
  repository = "https://grafana.github.io/helm-charts"
  chart      = "alloy"
  version    = var.chart_versions.alloy
  namespace  = kubernetes_namespace.monitoring.metadata[0].name

  values = [
    yamlencode({
      controller = {
        tolerations = local.tolerate_control_plane
      }
      alloy = {
        configMap = {
          create  = true
          content = <<-EOT
            logging {
              level  = "info"
              format = "logfmt"
            }

            discovery.kubernetes "pods" {
              role = "pod"
            }

            discovery.relabel "pods" {
              targets = discovery.kubernetes.pods.targets

              rule {
                source_labels = ["__meta_kubernetes_namespace"]
                target_label  = "namespace"
              }
              rule {
                source_labels = ["__meta_kubernetes_pod_name"]
                target_label  = "pod"
              }
              rule {
                source_labels = ["__meta_kubernetes_pod_container_name"]
                target_label  = "container"
              }
            }

            loki.source.kubernetes "pods" {
              targets    = discovery.relabel.pods.output
              forward_to = [loki.write.default.receiver]
            }

            loki.write "default" {
              endpoint {
                url = "http://loki-gateway.${kubernetes_namespace.monitoring.metadata[0].name}.svc.cluster.local/loki/api/v1/push"
              }
            }
          EOT
        }
      }
    })
  ]

  depends_on = [helm_release.loki]
}

# --- NetworkPolicies: default-deny + only the traffic this namespace
# actually needs (#31). PSA already stays at "privileged" above — node-
# exporter (hostNetwork/hostPID) and Alloy (hostPath log mounts) can't run
# under baseline/restricted at all, so there's no PSA tightening to do here
# beyond what's already justified. ------------------------------------------
resource "kubernetes_network_policy" "default_deny_all" {
  metadata {
    name      = "default-deny-all"
    namespace = kubernetes_namespace.monitoring.metadata[0].name
  }

  spec {
    pod_selector {}
    policy_types = ["Ingress", "Egress"]
  }
}

resource "kubernetes_network_policy" "allow_dns_egress" {
  metadata {
    name      = "allow-dns-egress"
    namespace = kubernetes_namespace.monitoring.metadata[0].name
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

# Prometheus <-> Alertmanager <-> Grafana <-> Loki <-> kube-state-metrics <->
# node-exporter <-> Alloy <-> the operator, all in this one namespace.
resource "kubernetes_network_policy" "allow_same_namespace" {
  metadata {
    name      = "allow-same-namespace"
    namespace = kubernetes_namespace.monitoring.metadata[0].name
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

# ingress-nginx -> Grafana.
resource "kubernetes_network_policy" "allow_ingress_nginx" {
  metadata {
    name      = "allow-ingress-nginx"
    namespace = kubernetes_namespace.monitoring.metadata[0].name
  }

  spec {
    pod_selector {
      match_labels = { "app.kubernetes.io/name" = "grafana" }
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

# prometheus-operator/kube-state-metrics/Prometheus itself all talk to the
# apiserver directly (CRD/Endpoint/Pod watches, service discovery).
resource "kubernetes_network_policy" "allow_apiserver_egress" {
  metadata {
    name      = "allow-apiserver-egress"
    namespace = kubernetes_namespace.monitoring.metadata[0].name
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

# Prometheus scrapes kubelet (+ cAdvisor, same port) directly on every
# node's real IP — this is real cluster traffic, not covered by any
# namespace/pod selector since kubelet isn't a pod.
resource "kubernetes_network_policy" "allow_kubelet_egress" {
  metadata {
    name      = "allow-kubelet-egress"
    namespace = kubernetes_namespace.monitoring.metadata[0].name
  }

  spec {
    pod_selector {}
    policy_types = ["Egress"]

    egress {
      to {
        ip_block {
          cidr = "192.168.160.0/27"
        }
      }
      ports {
        port     = "10250"
        protocol = "TCP"
      }
    }
  }
}

# The additionalScrapeConfigs jobs in this unit's own Prometheus config
# (cert-manager:9402, velero:8085) — see the additionalScrapeConfigs comment
# above. Ingress is added on the cert-manager/velero side by their own units.
resource "kubernetes_network_policy" "allow_scrape_targets_egress" {
  metadata {
    name      = "allow-scrape-targets-egress"
    namespace = kubernetes_namespace.monitoring.metadata[0].name
  }

  spec {
    pod_selector {}
    policy_types = ["Egress"]

    egress {
      to {
        namespace_selector {
          match_labels = { "kubernetes.io/metadata.name" = "cert-manager" }
        }
      }
      ports {
        port     = "9402"
        protocol = "TCP"
      }
    }
    egress {
      to {
        namespace_selector {
          match_labels = { "kubernetes.io/metadata.name" = "velero" }
        }
      }
      ports {
        port     = "8085"
        protocol = "TCP"
      }
    }
  }
}

# Alertmanager -> Discord webhook, and Grafana's OIDC calls to Keycloak's
# external hostname (#32 — resolves back through ingress-nginx's LoadBalancer
# IP, within this 0.0.0.0/0 range).
resource "kubernetes_network_policy" "allow_internet_egress" {
  metadata {
    name      = "allow-internet-egress"
    namespace = kubernetes_namespace.monitoring.metadata[0].name
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
