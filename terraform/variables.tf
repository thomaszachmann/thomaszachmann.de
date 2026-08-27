variable "domain" {
  description = "Apex-Domain der Website."
  type        = string
  default     = "thomaszachmann.de"
}

variable "cloudflare_zone_id" {
  description = "Zone-ID der Domain. Cloudflare-Dashboard, Zonenuebersicht, rechte Spalte."
  type        = string

  validation {
    condition     = can(regex("^[0-9a-f]{32}$", var.cloudflare_zone_id))
    error_message = "Eine Cloudflare-Zone-ID besteht aus 32 Hex-Zeichen. Vermutlich wurde die Account-ID oder ein Token eingetragen."
  }
}

variable "admin_ip_cidrs" {
  description = "CIDRs, die per SSH auf den Node duerfen. Eigene IP: curl -s https://ifconfig.me"
  type        = list(string)

  validation {
    condition     = length(var.admin_ip_cidrs) > 0
    error_message = "Mindestens ein CIDR ist noetig, sonst ist der Node nicht administrierbar."
  }

  validation {
    condition     = !contains(var.admin_ip_cidrs, "0.0.0.0/0") && !contains(var.admin_ip_cidrs, "::/0")
    error_message = "SSH fuer 0.0.0.0/0 oder ::/0 zu oeffnen hebt den Sinn der Firewall auf."
  }

  validation {
    condition     = alltrue([for c in var.admin_ip_cidrs : can(cidrnetmask(c)) || can(regex(":", c))])
    error_message = "Jeder Eintrag muss ein CIDR mit Praefixlaenge sein, z. B. 203.0.113.7/32 - nicht die nackte IP."
  }
}

variable "ssh_public_key_path" {
  description = "Pfad zum oeffentlichen SSH-Key fuer den Node-Zugang."
  type        = string
  default     = "~/.ssh/id_ed25519.pub"
}

variable "node_user" {
  description = "Nicht-Root-Benutzer auf dem Node."
  type        = string
  default     = "tz"
}

variable "server_type" {
  description = "Hetzner-Servertyp. cx33 = 4 vCPU, 8 GB RAM, 80 GB NVMe."
  type        = string
  default     = "cx33"
}

variable "location" {
  description = "Hetzner-Standort."
  type        = string
  default     = "fsn1"
}

variable "os_image" {
  description = "Basis-Image des Nodes."
  type        = string
  default     = "ubuntu-24.04"
}

variable "k3s_version" {
  description = "Gepinnte k3s-Version. Channel 'stable' am 2026-08-26."
  type        = string
  default     = "v1.36.3+k3s1"
}

variable "node_name" {
  description = "Name des Servers und des Kubernetes-Nodes. Muss zu --node-name im cloud-init passen."
  type        = string
  default     = "tz-web-01"
}
