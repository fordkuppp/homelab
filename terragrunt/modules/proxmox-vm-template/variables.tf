variable "vm_name" {
  type        = string
  description = "The virtual machine name"
}

variable "virtual_environment_node_name" {
  type        = string
  description = "The node name for the Proxmox Virtual Environment API"
}

variable "cloud_image_file" {
  type = string
  description = "Direct download link for cloud image iso"
  default = "https://cloud-images.ubuntu.com/noble/current/noble-server-cloudimg-amd64.img"
}

variable "ssh_public_key" {
  type        = string
  description = "SSH public key for cloud-init user"
}

variable "vm_id" {
  type = number
  description = "VM id"
}