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
    random = {
      source  = "hashicorp/random"
      version = "~> 3.6.0"
    }
    # Not referenced by this file — used by the Terragrunt-generated
    # secrets.tf (see tofu/live/root.hcl's secrets_tf local), for the
    # discord_alert_webhook this unit's Alertmanager config consumes. See the
    # same note in modules/network/terraform.tf.
    sops = {
      source  = "carlpett/sops"
      version = "~> 1.1.0"
    }
  }
}
