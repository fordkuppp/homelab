resource "proxmox_virtual_environment_vm" "node" {
  name      = var.vm_name
  node_name = var.node_name
  vm_id     = var.vm_id

  clone {
    vm_id = var.template_id
  }

  agent {
    enabled = true
  }

  initialization {
    datastore_id = var.datastore_id

    dns {
      servers = var.dns_servers
    }

    ip_config {
      ipv4 {
        address = var.ip_address
        gateway = var.gateway
      }
    }

    user_account {
      keys = [trimspace(var.ssh_public_key)]
      username = var.username
      password = var.password
    }
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
    interface = "scsi0"
    size = var.disk_size_gb
  }

  on_boot = var.on_boot
  description = var.description
  tags = var.tags
}