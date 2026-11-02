include "root" {
  path   = find_in_parent_folders("root.hcl")
  expose = true
}

include "proxmox" {
  path = find_in_parent_folders("proxmox.hcl")
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

# Pelican Wings host. Configured entirely by ansible/playbooks/composite/wings.yaml
# -- the cloud image already brings docker-ce and nfs-common, which is all Wings
# needs from the image, so there is no user_data.
inputs = {
  vm_name = "wings-1"
  vm_id   = 1201

  cpu_cores    = 4
  memory       = 8192
  disk_size_gb = 100
  disk_discard = "on"
  disk_ssd     = true

  cloud_image_id = dependency.ubuntu_image.outputs.file_id

  # Was docker-1's address; that VM is retired along with Komodo. See docs/ip-plan.md.
  ip_address     = "192.168.1.30/24"
  on_boot        = true
  ssh_public_key = local.secrets.proxmox.ssh.default.public_key

  tags = ["games", "wings"]
}
