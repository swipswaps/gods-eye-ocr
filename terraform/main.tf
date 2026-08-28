terraform {
  required_providers {
    digitalocean = {
      source  = "digitalocean/digitalocean"
      version = "~> 2.0"
    }
  }
}

provider "digitalocean" {
  token = var.do_token
}

resource "digitalocean_droplet" "backend" {
  image    = "ubuntu-22-04-x64"
  name     = "gods-eye-backend"
  region   = "nyc1"
  size     = "s-1vcpu-1gb"
  ssh_keys = [var.ssh_fingerprint]
}

output "droplet_ip" {
  value = digitalocean_droplet.backend.ipv4_address
}
