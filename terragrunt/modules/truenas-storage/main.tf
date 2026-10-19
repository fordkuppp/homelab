resource "truenas_dataset" "this" {
  for_each = var.datasets

  name        = each.value.name
  atime       = each.value.atime
  aclmode     = each.value.aclmode
  acltype     = each.value.acltype
  copies      = each.value.copies
  comments    = each.value.comments
  compression = each.value.compression

  # These hold terabytes of data. Removing one from config should fail loudly,
  # not silently destroy a dataset.
  lifecycle {
    prevent_destroy = true
  }
}

resource "truenas_nfs_share" "this" {
  for_each = var.nfs_shares

  path          = each.value.path
  enabled       = each.value.enabled
  ro            = each.value.ro
  hosts         = each.value.hosts
  networks      = each.value.networks
  maproot_user  = each.value.maproot_user
  maproot_group = each.value.maproot_group
  comment       = each.value.comment
}

resource "truenas_smb_share" "this" {
  for_each = var.smb_shares

  name    = each.value.name
  path    = each.value.path
  enabled = each.value.enabled
  comment = each.value.comment
}
