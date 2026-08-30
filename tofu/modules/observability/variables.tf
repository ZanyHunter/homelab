variable "chart_versions" {
  description = "Pinned Helm chart versions for the add-ons this unit manages. Plain numbers.periods only, no leading \"v\"."
  type = object({
    kube_prometheus_stack = string
    loki                  = string
    alloy                 = string
  })
}

variable "nfs_storage_class_name" {
  type        = string
  description = "Name of the NFS StorageClass (core-addons unit's output) Prometheus/Grafana/Loki's data volumes are provisioned on."
}

variable "domain_name" {
  type        = string
  description = "Domain suffix for this environment (e.g. dev.thepugh.family) — drives Grafana's ingress hostname and OIDC endpoints. See tofu/modules/network/variables.tf's domain_name for the full picture."
}

variable "network_cidr" {
  type        = string
  description = "This environment's k8s VLAN subnet (e.g. 192.168.160.0/27) — used to scope the NetworkPolicy CIDR block that allows Prometheus to scrape kubelet on node IPs. See tofu/modules/network/variables.tf's network_cidr for the full picture."
}
