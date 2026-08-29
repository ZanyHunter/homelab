terraform {
  required_providers {
    proxmox = {
      source = "bpg/proxmox"
      # Bumped from ~> 0.82.1 for the proxmox_ceph_pool resource (added
      # v0.107.0) and proxmox_ceph_status data source (added v0.108.0),
      # needed for the ceph-rbd StorageClass work (#28). No documented
      # reason the old pin was chosen beyond "whatever was current" — unlike
      # the unifi provider's deliberate 0.41.3 pin, this one has no known
      # regression to avoid.
      version = "~> 0.111.0"
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
