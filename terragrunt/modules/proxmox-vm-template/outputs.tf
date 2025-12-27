output "template_id" {
  description = "VM id of the template"
  value       = proxmox_virtual_environment_vm.cloud_template.vm_id
}

output "template_name" {
  description = "The name of the VM template"
  value       = proxmox_virtual_environment_vm.cloud_template.name
}

output "node_name" {
  description = "The node where the template resides"
  value       = proxmox_virtual_environment_vm.cloud_template.node_name
}

output "cloud_image_id" {
  description = "The ID of the downloaded cloud image"
  value       = proxmox_virtual_environment_download_file.cloud_images.id
}
