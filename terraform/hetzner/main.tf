resource "hcloud_ssh_key" "cluster" {
  name       = "${var.project_name}-ssh-public-key"
  public_key = file(pathexpand(var.ssh_public_key_path))
}

resource "hcloud_network" "cluster" {
  name     = "${var.project_name}-net"
  ip_range = var.network_ip_range
}

resource "hcloud_network_subnet" "cluster" {
  network_id   = hcloud_network.cluster.id
  type         = "cloud"
  network_zone = "eu-central"
  ip_range     = var.subnet_ip_range
}

resource "hcloud_firewall" "cluster" {
  name = "${var.project_name}-firewall"

  rule {
    direction = "in"
    protocol  = "tcp"
    port      = "22"
    source_ips = [
      var.allowed_ssh_cidr
    ]
  }
}

resource "hcloud_server" "control_plane" {
  name = "${var.project_name}-control-plane"
  labels = {
    project    = var.project_name
    role       = "control-plane"
    managed_by = "terraform"
  }
  server_type  = var.server_type
  image        = var.image
  location     = var.location
  ssh_keys     = [hcloud_ssh_key.cluster.id]
  firewall_ids = [hcloud_firewall.cluster.id]

  network {
    subnet_id = hcloud_network_subnet.cluster.id
    ip        = "10.0.0.10"
    alias_ips = []
  }
}

resource "hcloud_server" "worker" {
  count = var.worker_count

  name = "${var.project_name}-worker-${count.index + 1}"
  labels = {
    project    = var.project_name
    role       = "worker"
    managed_by = "terraform"
  }
  server_type  = var.server_type
  image        = var.image
  location     = var.location
  ssh_keys     = [hcloud_ssh_key.cluster.id]
  firewall_ids = [hcloud_firewall.cluster.id]

  network {
    subnet_id = hcloud_network_subnet.cluster.id
    ip        = "10.0.0.1${count.index + 1}"
    alias_ips = []
  }
}