variable "project_name" {
  description = "Project name used as a prefix for Hetzner Cloud resources."
  type        = string
  default     = "tinytasks-platform"
}

variable "location" {
  description = "Hetzner Cloud location for all servers."
  type        = string
  default     = "nbg1"
}

variable "image" {
  description = "Operating system image for Kubernetes nodes."
  type        = string
  default     = "ubuntu-24.04"
}

variable "server_type" {
  description = "Hetzner Cloud server type for Kubernetes nodes."
  type        = string
  default     = "cx23"
}

variable "worker_count" {
  description = "Number of Kubernetes worker nodes."
  type        = number
  default     = 2
}

variable "ssh_public_key_path" {
  description = "Path to the SSH public key used to access Kubernetes nodes."
  type        = string
  default     = "~/.ssh/hetzner_devops_platform.pub"
}

variable "network_ip_range" {
  description = "Address range for the Hetzner private network."
  type        = string
  default     = "10.0.0.0/16"
}

variable "subnet_ip_range" {
  description = "Address range for the TinyTasks platform subnet."
  type        = string
  default     = "10.0.0.0/24"
}

variable "allowed_ssh_cidr" {
  description = "CIDR block allowed to access TinyTasks platform nodes over SSH."
  type        = string
  default     = "0.0.0.0/0"
}