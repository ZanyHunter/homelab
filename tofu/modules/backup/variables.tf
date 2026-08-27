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
