include "root" {
  path   = find_in_parent_folders("root.hcl")
  expose = true
}

terraform {
  source = "../../../modules/proxmox-vm-template"
}

dependency "ubuntu_img" {
  config_path = "../../images/vm/ubuntu2404"
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

  cloud_image_id = dependency.ubuntu_img.outputs.file_id
}