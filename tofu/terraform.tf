terraform {
  required_providers {
    unifi = {
      source  = "ubiquiti-community/unifi"
      version = "~> 0.41.3"
    }
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 2.38.0"
    }
    helm = {
      source  = "hashicorp/helm"
      version = "~> 2.15.0"
    }
    proxmox = {
      source  = "bpg/proxmox"
      version = "~> 0.82.1"
    }
    talos = {
      source  = "siderolabs/talos"
      version = "~> 0.8.1"
    }
    time = {
      source  = "hashicorp/time"
      version = "~> 0.13.1"
    }
    sops = {
      source  = "carlpett/sops"
      version = "~> 1.1.0"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.6.0"
    }
    keycloak = {
      source  = "keycloak/keycloak"
      version = "~> 5.9.0"
    }
  }

  # Remote state on the MinIO instance from tofu/backup.tf (see
  # tofu/state-backend.tf for the Ingress exposing it, and
  # docs/src/bootstrap-environment/09-remote-state.md for the full picture).
  # Bucket/key are hardcoded literals, not variables — backend blocks are
  # evaluated before any variables/resources are known, so they can't
  # reference var.tofu_state_bucket or var.cluster.name even though both
  # exist. Credentials come from -backend-config (tofu/backend.hcl,
  # gitignored — see backend.hcl.example) rather than being hardcoded here.
  backend "s3" {
    bucket = "tofu-state"
    key    = "dev/terraform.tfstate"
    region = "us-east-1" # arbitrary — MinIO doesn't validate AWS regions

    endpoints = {
      s3 = "https://minio.k8s.thepugh.family"
    }
    use_path_style              = true
    skip_credentials_validation = true
    skip_region_validation      = true
    skip_metadata_api_check     = true
    skip_requesting_account_id  = true
    # Native conditional-write locking (no DynamoDB-style lock table needed) —
    # requires MinIO to support conditional PUT (If-None-Match), verified
    # against the deployed RELEASE.2024-12-18T13-15-44Z by testing two
    # concurrent applies.
    use_lockfile = true
  }
}

