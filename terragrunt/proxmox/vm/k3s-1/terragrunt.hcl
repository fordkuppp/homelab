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
  vm_name = "k3s-1"
  vm_id   = 1100

  cpu_cores    = 4
  memory       = 24576
  disk_size_gb = 64

  cloud_image_id = dependency.ubuntu_image.outputs.file_id

  ip_address     = "192.168.1.20/24"
  on_boot        = true
  ssh_public_key = local.secrets.proxmox.ssh.default.public_key

  user_data = file("../script/install-k3s.sh")

  pci_devices = [
    {
      mapping = "intel-igpu" // Mapping created manually through proxmox UI (Datacenter -> Resource Mapping -> Add PCI Devices)
      pcie    = true
    }
  ]
}