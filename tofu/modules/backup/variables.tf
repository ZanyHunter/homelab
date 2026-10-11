variable "chart_versions" {
  type = object({
    minio  = string
    velero = string
  })
}

variable "velero_plugin_for_aws_version" {
  description = "Pinned velero/velero-plugin-for-aws image tag — the S3-compatible object storage plugin Velero uses to talk to MinIO. Plain numbers.periods only, no leading \"v\"."
  type        = string
}

variable "backup" {
  description = "Velero/MinIO cluster backup tuning — schedule, retention, and MinIO's own storage size."
  type = object({
    schedule           = string # cron expression for the daily Velero Schedule
    ttl                = string # Velero backup retention, a Go duration string (e.g. "720h")
    minio_bucket       = string
    minio_storage_size = string # PVC size for MinIO's NFS-backed data volume
  })
}

variable "nfs_storage_class_name" {
  type        = string
  description = "Name of the NFS StorageClass (core-addons unit's output) MinIO's own data volume is provisioned on."
}

variable "ceph_storage_class_name" {
  type        = string
  description = "Name of the Ceph-backed StorageClass (core-addons unit's output) Garage's small metadata volume is provisioned on — its SQLite metadata DB can't safely live on NFS."
}

variable "garage" {
  description = "Garage (MinIO's replacement as Velero's S3 backend, #108) — image, bucket, and volume sizes."
  type = object({
    image     = string # full reference, ideally pinned by digest and pulled from a registry we control
    bucket    = string
    data_size = string # PVC size for the NFS-backed object data volume
    meta_size = string # PVC size for the Ceph-backed metadata volume
  })
}
