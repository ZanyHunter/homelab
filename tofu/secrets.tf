data "sops_file" "secrets" {
  source_file = "${path.module}/secrets.enc.yaml"
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
}
