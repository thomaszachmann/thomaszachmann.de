locals {
  # Cloudflare-Provider v5 verlangt den vollen FQDN, nicht "@" fuer den Apex.
  dns_names = {
    apex = var.domain
    www  = "www.${var.domain}"
  }
}

resource "cloudflare_dns_record" "a" {
  for_each = local.dns_names

  zone_id = var.cloudflare_zone_id
  name    = each.value
  type    = "A"
  content = hcloud_primary_ip.v4.ip_address
  ttl     = 300

  # DNS-only: Cloudflare loest nur auf, der Traffic geht direkt an Hetzner.
  # Ein Proxy hier wuerde den Besucherverkehr ueber einen US-Anbieter leiten
  # und der DSGVO-Argumentation der Website widersprechen.
  proxied = false
  comment = "Terraform: k3s-Node ${var.location}"
}

resource "cloudflare_dns_record" "aaaa" {
  for_each = local.dns_names

  zone_id = var.cloudflare_zone_id
  name    = each.value
  type    = "AAAA"

  # Bewusst die Server-Adresse und nicht hcloud_primary_ip.v6.ip_address:
  # letzteres ist bei IPv6 das /64-Netz, nicht die konkrete Adresse des Hosts.
  content = hcloud_server.web.ipv6_address
  ttl     = 300
  proxied = false
  comment = "Terraform: k3s-Node ${var.location}"
}
