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
