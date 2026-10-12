variable "chart_versions" {
  type = object({
    velero = string
  })
}

variable "velero_plugin_for_aws_version" {
  description = "Pinned velero/velero-plugin-for-aws image tag — the S3-compatible object storage plugin Velero uses to talk to Garage. Plain numbers.periods only, no leading \"v\"."
  type        = string
}

variable "backup" {
  description = "Velero cluster backup tuning — schedule and retention."
  type = object({
    schedule = string # cron expression for the daily Velero Schedule
    ttl      = string # Velero backup retention, a Go duration string (e.g. "720h")
  })
}

variable "nfs_storage_class_name" {
  type        = string
  description = "Name of the NFS StorageClass (core-addons unit's output) Garage's object data volume is provisioned on."
}

variable "ceph_storage_class_name" {
  type        = string
  description = "Name of the Ceph-backed StorageClass (core-addons unit's output) Garage's small metadata volume is provisioned on — its SQLite metadata DB can't safely live on NFS."
}

variable "garage" {
  description = "Garage (Velero's S3 backend, replacing MinIO in #108) — image, bucket, and volume sizes."
  type = object({
    image     = string # full reference, ideally pinned by digest and pulled from a registry we control
    bucket    = string
    data_size = string # PVC size for the NFS-backed object data volume
    meta_size = string # PVC size for the Ceph-backed metadata volume
  })
}
