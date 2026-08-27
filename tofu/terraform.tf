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
    helm = {
      source  = "hashicorp/helm"
      version = "~> 2.15.0"
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
      source  = "hashicorp/time"
      version = "~> 0.13.1"
    }
    sops = {
      source  = "carlpett/sops"
      version = "~> 1.1.0"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.6.0"
    }
    keycloak = {
      source  = "keycloak/keycloak"
      version = "~> 5.9.0"
    }
  }
}

