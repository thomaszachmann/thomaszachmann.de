terraform {
  required_version = ">= 1.9.0"

  required_providers {
    hcloud = {
      source  = "hetznercloud/hcloud"
      version = "~> 1.68"
    }
    cloudflare = {
      source  = "cloudflare/cloudflare"
      version = "~> 5.24"
    }
  }
}

# Beide Provider ziehen ihr Token bewusst aus der Umgebung
# (HCLOUD_TOKEN bzw. CLOUDFLARE_API_TOKEN) und nicht aus einer Variable.
# So kann kein Token versehentlich in terraform.tfvars oder in einem
# State-Diff landen.
provider "hcloud" {}

provider "cloudflare" {}
