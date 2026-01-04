variable "node_name" {
  type        = string
  description = "The Proxmox node where the VM will be created"
}

variable "vm_name" {
  type        = string
}

variable "vm_id" {
  type        = number
  default     = null
}

variable "template_id" {
  type        = number
  description = "The ID of the template to clone from"
}

variable "ip_address" {
  type        = string
  description = "The IPv4 address in CIDR notation (e.g. 192.168.1.10/24)"
}

variable "gateway" {
  type        = string
  description = "The default gateway for the network"
  default     = "192.168.1.1"
}

variable "dns_servers" {
  type        = list(string)
  description = "List of DNS servers"
  default     = ["1.1.1.1"]
}

variable "cpu_cores" {
  type    = number
  description = "The number of CPU cores"
  default = 1
}

variable "memory" {
  type    = number
  description = "The dedicated memory in megabytes"
  default = 1024
}

variable "disk_size_gb" {
  type    = number
  default = 20
}

variable "datastore_id" {
  type    = string
  default = "local-lvm"
}

variable "ssh_public_key" {
  type        = string
  description = "Public SSH key for the default user"
}

variable "username" {
  type = string
  description = "SSH username"
}

variable "password" {
  type = string
  description = "SSH password"
}

variable "bridge" {
  type    = string
  default = "vmbr0"
}

variable "on_boot" {
  type        = bool
  description = "True to start the VM on boot"
  default     = true
}

variable "description" {
  type        = string
  description = "Proxmox VM notes"
  default     = "Managed by OpenTofu"
}

variable "tags" {
  type        = list(string)
  description = "Tags for the VM (e.g., ['k3s', 'worker'])"
  default     = []
}