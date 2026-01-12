variable "node_name" {
  type        = string
  description = "The Proxmox node where the VM will be created"
  default     = "lab"
}

variable "vm_name" {
  type        = string
}

variable "vm_id" {
  type        = number
  default     = null
}

variable "cloud_image_id" {
  type = string
  description = "The cloud image id from downloaded image"
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

variable "bridge" {
  type    = string
  default = "vmbr0"
}

variable "user_data" {
  type = string
  description = "Script to run when VM init"
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