terraform {
  required_version = ">= 1.6.0"

  required_providers {
    cloudflare = {
      source  = "cloudflare/cloudflare"
      version = "~> 5.19"
    }
  }

  # Auto-apply from GitHub Actions needs persistent state.
  # Uncomment and configure this block before enabling the workflow.
  #
  # cloud {
  #   organization = "your-terraform-cloud-org"
  #
  #   workspaces {
  #     name = "auto-app-deploy-cloudflare-access"
  #   }
  # }
}

provider "cloudflare" {
  # Uses CLOUDFLARE_API_TOKEN from the environment.
}
