resource "proxmox_virtual_environment_download_file" "cloud_images" {
  content_type = "iso"
  datastore_id = "local"
  node_name    = var.virtual_environment_node_name

  url = var.cloud_image_file
}

resource "proxmox_virtual_environment_file" "user_data_cloud_config" {
  content_type = "snippets"
  datastore_id = "local"
  node_name    = var.virtual_environment_node_name

  source_raw {
    data = <<-EOF
    #cloud-config
    hostname: ${var.vm_name}
    timezone: America/Toronto
    users:
      - default
      - name: ubuntu
        groups:
          - sudo
        shell: /bin/bash
        ssh_authorized_keys:
          - ${trimspace(var.ssh_public_key)}
        sudo: ALL=(ALL) NOPASSWD:ALL
    package_update: true
    packages:
      - qemu-guest-agent
      - net-tools
      - curl
    runcmd:
      - systemctl enable qemu-guest-agent
      - systemctl start qemu-guest-agent
      - echo "done" > /tmp/cloud-config.done
    EOF

    file_name = "user-data-cloud-config.yaml"
  }
}

resource "proxmox_virtual_environment_vm" "cloud_template" {
  name      = var.vm_name
  node_name = var.virtual_environment_node_name
  vm_id     = var.vm_id

  template = true
  started  = false

  machine       = "pc"
  scsi_hardware = "virtio-scsi-single"
  bios          = "seabios"
  description   = "Managed by Terraform"

  cpu {
    cores = 1
    type  = "x86-64-v2-AES"
  }

  memory {
    dedicated = 1024
  }

  disk {
    datastore_id = "local-lvm"
    file_id      = proxmox_virtual_environment_download_file.cloud_images.id
    interface    = "scsi0"
    iothread     = true
    discard      = "on"
    size         = 20
  }

  initialization {
    datastore_id = "local-lvm"
    ip_config {
      ipv4 {
        address = "dhcp"
      }
    }

    user_data_file_id = proxmox_virtual_environment_file.user_data_cloud_config.id
  }

  network_device {
    bridge = "vmbr0"
  }
}
