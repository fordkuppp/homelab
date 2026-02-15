include "root" {
  path   = find_in_parent_folders("root.hcl")
  expose = true
}

terraform {
  source = "../../../modules/proxmox-vm"
}

dependency "ubuntu_image" {
  config_path = "../../images/vm/ubuntu2404"
}

locals {
  secrets = include.root.locals.secrets
}

inputs = {
  vm_name = "docker-1"
  vm_id   = 1200

  memory = 8192

  cloud_image_id = dependency.ubuntu_image.outputs.file_id

  ip_address     = "192.168.1.30/24"
  on_boot        = true
  ssh_public_key = local.secrets.proxmox.ssh.default.public_key

  user_data = templatefile("../script/install-komodo.sh", {
    compose_content = file("../../../../docker/compose/komodo/mongo.compose.yaml")
    env_content     = file("../../../../docker/compose/komodo/compose.env")
  })
}