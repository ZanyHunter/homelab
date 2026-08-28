locals {
  repo_root = get_repo_root()

  # Verbatim port of the old flat tofu/secrets.tf, generated only into units
  # that actually need decrypted credentials (see each unit's terragrunt.hcl)
  # — network/talos-cluster/core-addons/observability get this, the rest
  # (backup/keycloak-infra/keycloak-realm) never do, so their state never
  # contains Proxmox/Unifi/Cloudflare/Discord credentials.
  secrets_tf = <<-EOF
    data "sops_file" "secrets" {
      source_file = "${local.repo_root}/tofu/secrets.enc.yaml"
    }

    locals {
      proxmox_provider = {
        endpoint = data.sops_file.secrets.data["proxmox_provider.endpoint"]
        insecure = tobool(data.sops_file.secrets.data["proxmox_provider.insecure"])
        username = data.sops_file.secrets.data["proxmox_provider.username"]
        password = data.sops_file.secrets.data["proxmox_provider.password"]
      }

      unifi_provider = {
        api_key        = data.sops_file.secrets.data["unifi_provider.api_key"]
        api_url        = data.sops_file.secrets.data["unifi_provider.api_url"]
        allow_insecure = tobool(data.sops_file.secrets.data["unifi_provider.allow_insecure"])
      }

      cloudflare_api_token = data.sops_file.secrets.data["cloudflare_api_token"]

      discord_alert_webhook = data.sops_file.secrets.data["discord_alert_webhook"]
    }
  EOF

}

# State lives on an SMB-mounted NAS share (tofu/state/, gitignored, mounted
# out-of-band — see docs/src/bootstrap-environment/09-remote-state.md), one
# file per unit, path computed here rather than hand-typed per unit.
remote_state {
  backend = "local"
  generate = {
    path      = "backend.tf"
    if_exists = "overwrite"
  }
  config = {
    path = "${local.repo_root}/tofu/state/${path_relative_to_include()}/terraform.tfstate"
  }
}
