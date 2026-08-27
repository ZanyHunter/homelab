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

  # Remote state via a plain local-backend path, deliberately NOT managed by
  # this Tofu config — the directory this points at is meant to be an SMB
  # mount of a share on the NAS, set up out-of-band (see
  # docs/src/bootstrap-environment/09-remote-state.md). This sidesteps two
  # problems a cluster-hosted backend (the MinIO-on-k8s approach originally
  # here) would have: state storage no longer depends on infrastructure this
  # config itself creates/destroys (no "destroying the resource that backs
  # your own state" chicken-and-egg on a full teardown), and no new external
  # dependency (cloud object storage) is introduced either.
  #
  # `path` is a hardcoded literal, not a variable — backend blocks are
  # evaluated before any variables/resources are known. The "dev/" prefix is
  # there so a future prod cluster's state can live alongside dev's on the
  # same share without colliding, once #21 gives it its own Tofu config to
  # hardcode a "prod/" path in.
  backend "local" {
    path = "state/dev/terraform.tfstate"
  }
}

