terraform {
  required_version = ">= 1.6.0"

  cloud {
    organization = "rpi-cf-app-of-apps"

    workspaces {
      name = "cloudflare-access"
    }
  }

  required_providers {
    cloudflare = {
      source  = "cloudflare/cloudflare"
      version = "~> 5.19"
    }
  }
}

provider "cloudflare" {
  # Uses CLOUDFLARE_API_TOKEN from the environment.
}