output "control_plane_public_ip" {
  description = "Public IPv4 address of the control-plane node."
  value       = hcloud_server.control_plane.ipv4_address
}

output "worker_public_ips" {
  description = "Public IPv4 addresses of the worker nodes."
  value       = hcloud_server.worker[*].ipv4_address
}