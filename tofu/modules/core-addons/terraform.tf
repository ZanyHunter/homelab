terraform {
  required_providers {
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 2.38.0"
    }
    helm = {
      source  = "hashicorp/helm"
      version = "~> 2.15.0"
    }
    # Not referenced by this file — used by the Terragrunt-generated
    # secrets.tf (see tofu/live/root.hcl's secrets_tf local), for the
    # cloudflare_api_token this unit's cert-manager Secret consumes. See the
    # same note in modules/network/terraform.tf.
    sops = {
      source  = "carlpett/sops"
      version = "~> 1.1.0"
    }
  }
}
