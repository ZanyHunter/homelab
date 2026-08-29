terraform {
  required_providers {
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 2.38.0"
    }
    helm = {
      source  = "hashicorp/helm"
      version = "~> 2.15.0"
    }
    # Not referenced by this file — used by the Terragrunt-generated
    # secrets.tf (see tofu/live/root.hcl's secrets_tf local), for the
    # cloudflare_api_token this unit's cert-manager Secret consumes. See the
    # same note in modules/network/terraform.tf.
    sops = {
      source  = "carlpett/sops"
      version = "~> 1.1.0"
    }
    # ArgoCD's OIDC client secret (#32) — random_password.argocd_oidc_client_secret.
    random = {
      source  = "hashicorp/random"
      version = "~> 3.6.0"
    }
    # The Cloudflare Tunnel + public DNS records for photos.<domain_name>
    # (#33/#39) — first use of this provider in this repo. cert-manager's
    # DNS-01 use of the Cloudflare API token predates this and never needed
    # a Terraform provider (it just hands the raw token to cert-manager's
    # own Kubernetes Secret).
    cloudflare = {
      source  = "cloudflare/cloudflare"
      version = "~> 5.22.0"
    }
  }
}
