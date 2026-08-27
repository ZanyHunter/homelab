terraform {
  required_providers {
    proxmox = {
      source  = "bpg/proxmox"
      version = "~> 0.82.1"
    }
    talos = {
      source  = "siderolabs/talos"
      version = "~> 0.8.1"
    }
    # Not referenced by this file — used by the Terragrunt-generated
    # secrets.tf (see tofu/live/root.hcl's secrets_tf local). See the same
    # note in modules/network/terraform.tf.
    sops = {
      source  = "carlpett/sops"
      version = "~> 1.1.0"
    }
  }
}
