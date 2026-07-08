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
    proxmox = {
      source  = "bpg/proxmox"
      version = "~> 0.82.1"
    }
    talos = {
      source  = "siderolabs/talos"
      version = "~> 0.8.1"
    }
    time = {
      source = "hashicorp/time"
      version = "~> 0.13.1"
    }
  }
}
