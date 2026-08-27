# Der SSH-Key wird bewusst NICHT von Terraform verwaltet, sondern nur
# referenziert. Er existierte vor diesem Projekt und wird von weiteren Servern
# im selben Hetzner-Projekt mitbenutzt. Wuerde Terraform ihn besitzen, koennte
# ein destroy den Zugang zu jenen Servern mitreissen.
#
# Nebeneffekt, der uns entgegenkommt: Hetzner lehnt einen zweiten Key mit
# gleichem Fingerprint ohnehin ab.
data "hcloud_ssh_key" "admin" {
  name = var.ssh_key_name
}

# Die Primary IPs sind bewusst eigene Ressourcen und nicht Teil des Servers.
# Sie sind der stabile Anker, auf den DNS zeigt: der Server darf jederzeit
# weggeworfen und neu gebaut werden, ohne dass sich die IP aendert.
# delete_protection verhindert, dass ein unbedachtes destroy den Anker mitnimmt.
resource "hcloud_primary_ip" "v4" {
  name              = "${var.node_name}-v4"
  type              = "ipv4"
  location          = var.location
  auto_delete       = false
  delete_protection = true

  labels = { site = "thomaszachmann" }
}

resource "hcloud_primary_ip" "v6" {
  name              = "${var.node_name}-v6"
  type              = "ipv6"
  location          = var.location
  auto_delete       = false
  delete_protection = true

  labels = { site = "thomaszachmann" }
}

resource "hcloud_server" "web" {
  name        = var.node_name
  server_type = var.server_type
  image       = var.os_image
  location    = var.location
  ssh_keys    = [data.hcloud_ssh_key.admin.id]

  public_net {
    ipv4_enabled = true
    ipv4         = hcloud_primary_ip.v4.id
    ipv6_enabled = true
    ipv6         = hcloud_primary_ip.v6.id
  }

  user_data = templatefile("${path.module}/cloud-init.yaml.tftpl", {
    node_user   = var.node_user
    ssh_pubkey  = trimspace(data.hcloud_ssh_key.admin.public_key)
    k3s_version = var.k3s_version
    node_name   = var.node_name
    tls_san     = hcloud_primary_ip.v4.ip_address
  })

  labels = {
    role = "k3s-server"
    site = "thomaszachmann"
  }

  # Der hcloud-Provider ersetzt den Server, sobald sich ssh_keys aendert.
  # Da der Zugang nach dem ersten Boot ohnehin ueber cloud-init verwaltet
  # wird, waere das ein Rebuild ohne Gegenwert.
  #
  # user_data steht bewusst NICHT hier: eine geaenderte Node-Konfiguration
  # SOLL den Server ersetzen, denn das ist der einzige Weg, sie anzuwenden.
  lifecycle {
    ignore_changes = [ssh_keys]
  }
}
