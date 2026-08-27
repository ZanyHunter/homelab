variable "postgres_version" {
  description = "Pinned postgres:<version>-alpine image tag for Keycloak's hand-rolled backing database. Major version only (e.g. \"16\")."
  type        = string
}

variable "chart_versions" {
  type = object({
    keycloak = string
  })
}

variable "nfs_storage_class_name" {
  type        = string
  description = "Name of the NFS StorageClass (core-addons unit's output) Postgres's data volume is provisioned on."
}
