include "root" {
  path   = find_in_parent_folders("root.hcl")
  expose = true
}

terraform {
  source = "../../../modules/proxmox-vm-template"
}

locals {
  secrets = include.root.locals.secrets
}

inputs = {
  username       = local.secrets.proxmox.ssh.default.username
  password       = local.secrets.proxmox.ssh.default.password
  ssh_public_key = local.secrets.proxmox.ssh.default.public_key

  vm_name                       = "ubuntu-2404-template"
  vm_id                         = 9000
  virtual_environment_node_name = "lab"

  cloud_image_file = "https://cloud-images.ubuntu.com/noble/current/noble-server-cloudimg-amd64.img"
}