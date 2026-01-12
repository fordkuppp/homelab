resource "proxmox_virtual_environment_file" "cloudinit_file" {
  content_type = "snippets"
  datastore_id = "local"
  node_name    = var.node_name
  source_raw {
    file_name = "${var.vm_name}-config.yaml"
    data      = <<-EOF
#cloud-config
users:
  - name: ubuntu
    lock_passwd: true
    groups:
      - sudo
    shell: /bin/bash
    ssh_authorized_keys:
      - "${trimspace(var.ssh_public_key)}"
    sudo: ALL=(ALL) NOPASSWD:ALL
package_update: true
packages:
  - qemu-guest-agent
  - net-tools
  - curl
write_files:
  - path: /usr/local/bin/user-data.sh
    permissions: '0755'
    content: |
      ${indent(6, var.user_data)}
runcmd:
  - [systemctl, enable, qemu-guest-agent]
  - [systemctl, start, qemu-guest-agent]
  - [ sh, "/usr/local/bin/user-data.sh" ]
EOF
  }
}

resource "proxmox_virtual_environment_file" "metadata_file" {
  content_type = "snippets"
  datastore_id = "local"
  node_name    = var.node_name
  source_raw {
    file_name = "${var.vm_name}-metadata.yaml"
    data      = <<-EOF
instance-id: ${var.vm_name}
local-hostname: ${var.vm_name}
EOF
  }
}

resource "proxmox_virtual_environment_vm" "vm" {
  name      = var.vm_name
  node_name = var.node_name
  vm_id     = var.vm_id

  agent {
    enabled = true
  }

  initialization {
    datastore_id = var.datastore_id
    interface    = "ide2"

    dns {
      servers = var.dns_servers
    }

    ip_config {
      ipv4 {
        address = var.ip_address
        gateway = var.gateway
      }
    }

    user_data_file_id = proxmox_virtual_environment_file.cloudinit_file.id
    meta_data_file_id = proxmox_virtual_environment_file.metadata_file.id
  }

  cpu {
    cores = var.cpu_cores
    type = "host"
  }

  memory {
    dedicated = var.memory
  }

  network_device {
    bridge = "vmbr0"
  }

  disk {
    datastore_id = var.datastore_id
    file_id      = var.cloud_image_id
    interface = "scsi0"
    size = var.disk_size_gb
  }

  on_boot = var.on_boot
  description = var.description
  tags = var.tags
}