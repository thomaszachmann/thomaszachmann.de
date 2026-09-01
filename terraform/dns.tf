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

# ---------------------------------------------------------------------------
# Weitere Domains auf demselben Node.
#
# Der CLUSTER unterscheidet die Sites am Host-Header, nicht an der IP: alle
# Domains zeigen auf dieselbe Adresse, Traefik routet anhand des Ingress.
# Deshalb reicht hier je Domain ein A- und ein AAAA-Record.
#
# Der Cloudflare-API-Token braucht Zone:DNS:Edit auch fuer die neuen Zonen -
# sowohl fuer diese Records als auch fuer die DNS-01-Challenge von cert-manager.
# ---------------------------------------------------------------------------
locals {
  additional_dns = merge([
    for d, zone in var.additional_domains : {
      "${d}-apex" = { fqdn = d, zone_id = zone }
      "${d}-www"  = { fqdn = "www.${d}", zone_id = zone }
    }
  ]...)
}

resource "cloudflare_dns_record" "additional_a" {
  for_each = local.additional_dns

  zone_id = each.value.zone_id
  name    = each.value.fqdn
  type    = "A"
  content = hcloud_primary_ip.v4.ip_address
  ttl     = 300
  proxied = false
  comment = "Terraform: k3s-Node ${var.location}"
}

resource "cloudflare_dns_record" "additional_aaaa" {
  for_each = local.additional_dns

  zone_id = each.value.zone_id
  name    = each.value.fqdn
  type    = "AAAA"
  content = hcloud_server.web.ipv6_address
  ttl     = 300
  proxied = false
  comment = "Terraform: k3s-Node ${var.location}"
}
