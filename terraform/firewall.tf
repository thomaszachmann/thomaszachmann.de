# Die Firewall laeuft auf Hetzner-Ebene, ausserhalb der VM. Zwei Gruende:
# k3s schreibt eigene nftables-Regeln fuer CNI und Services, ein Host-Firewall
# darueber ist eine bekannte Fehlerquelle. Und eine Firewall, die ein
# kompromittierter Host nicht abschalten kann, ist die bessere Firewall.
#
# Sobald eine Firewall attached ist, gilt fuer eingehenden Verkehr
# Default-Deny. Was hier nicht steht, ist zu.
resource "hcloud_firewall" "web" {
  name = "tz-web"

  rule {
    direction   = "in"
    protocol    = "tcp"
    port        = "80"
    source_ips  = ["0.0.0.0/0", "::/0"]
    description = "HTTP, wird von Traefik permanent auf HTTPS umgeleitet"
  }

  rule {
    direction   = "in"
    protocol    = "tcp"
    port        = "443"
    source_ips  = ["0.0.0.0/0", "::/0"]
    description = "HTTPS"
  }

  rule {
    direction   = "in"
    protocol    = "tcp"
    port        = "22"
    source_ips  = var.admin_ip_cidrs
    description = "SSH nur von der Admin-IP"
  }

  rule {
    direction   = "in"
    protocol    = "icmp"
    source_ips  = ["0.0.0.0/0", "::/0"]
    description = "ICMP fuer Erreichbarkeitsdiagnose"
  }

  # Port 6443 fehlt hier absichtlich. Der kube-apiserver ist nicht aus dem
  # Internet erreichbar; Zugriff laeuft ueber ssh -L, siehe Output
  # kube_tunnel_command.
}

resource "hcloud_firewall_attachment" "web" {
  firewall_id = hcloud_firewall.web.id
  server_ids  = [hcloud_server.web.id]
}
