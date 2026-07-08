provider "proxmox" {
  endpoint = var.proxmox_provider.endpoint
  insecure = var.proxmox_provider.insecure

  username = var.proxmox_provider.username
  password = var.proxmox_provider.password
}

provider "unifi" {
  api_key        = var.unifi_provider.api_key
  api_url        = var.unifi_provider.api_url
  allow_insecure = var.unifi_provider.allow_insecure
}
