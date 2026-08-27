terraform {
  required_providers {
    unifi = {
      source = "ubiquiti-community/unifi"
      # Pinned exactly, not "~> 0.41.3": 0.41.25 (the latest release matching
      # that range as of this refactor) silently dropped the "purpose",
      # "dhcp_enabled", and "vlan_id" arguments from unifi_network's schema —
      # a real breaking regression within what should be a compatible patch
      # range. 0.41.3 is the exact version already proven working in
      # production (see the committed tofu/.terraform.lock.hcl before this
      # refactor).
      version = "0.41.3"
    }
    # Not referenced by this file — used by the Terragrunt-generated
    # secrets.tf (see tofu/live/root.hcl's secrets_tf local), which decrypts
    # tofu/secrets.enc.yaml for the unifi_provider credentials this unit's
    # generated provider.tf consumes. required_providers can only appear
    # once per unit, so it's declared here rather than in a second generated
    # file.
    sops = {
      source  = "carlpett/sops"
      version = "~> 1.1.0"
    }
  }
}
