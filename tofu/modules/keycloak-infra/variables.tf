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

variable "domain_name" {
  type        = string
  description = "Domain suffix for this environment (e.g. dev.thepugh.family) — drives Keycloak's own ingress hostname/frontend URL. See tofu/modules/network/variables.tf's domain_name for the full picture."
}
