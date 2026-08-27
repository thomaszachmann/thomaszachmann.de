output "ipv4" {
  description = "Primary IPv4 des Nodes. Stabil ueber Server-Rebuilds hinweg."
  value       = hcloud_primary_ip.v4.ip_address
}

output "ipv6" {
  description = "IPv6-Adresse des Nodes."
  value       = hcloud_server.web.ipv6_address
}

output "ssh_command" {
  description = "SSH-Zugang zum Node."
  value       = "ssh ${var.node_user}@${hcloud_primary_ip.v4.ip_address}"
}

output "kube_tunnel_command" {
  description = "Tunnel zum kube-apiserver. In einem eigenen Terminal offen halten."
  value       = "ssh -N -L 6443:127.0.0.1:6443 ${var.node_user}@${hcloud_primary_ip.v4.ip_address}"
}

output "fetch_kubeconfig_command" {
  description = "kubeconfig holen. Sie zeigt bereits auf 127.0.0.1:6443 und passt damit zum Tunnel."
  value       = "ssh ${var.node_user}@${hcloud_primary_ip.v4.ip_address} sudo cat /etc/rancher/k3s/k3s.yaml > kubeconfig && chmod 600 kubeconfig"
}
