resource "proxmox_virtual_environment_download_file" "image" {
  node_name      = var.node_name
  content_type   = var.content_type
  datastore_id   = "local"
  url            = var.url
  file_name      = var.file_name
  upload_timeout = 99999
}
