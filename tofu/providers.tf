provider "proxmox" {
  endpoint = local.proxmox_provider.endpoint
  insecure = local.proxmox_provider.insecure

  username = local.proxmox_provider.username
  password = local.proxmox_provider.password
}

provider "unifi" {
  api_key        = local.unifi_provider.api_key
  api_url        = local.unifi_provider.api_url
  allow_insecure = local.unifi_provider.allow_insecure
}

