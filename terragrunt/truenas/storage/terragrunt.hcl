include "root" {
  path   = find_in_parent_folders("root.hcl")
  expose = true
}

include "truenas" {
  path = find_in_parent_folders("truenas.hcl")
}

terraform {
  source = "../../modules/truenas-storage"
}

inputs = {
  datasets = {
    data = {
      name    = "general/data"
      atime   = "OFF"
      aclmode = "PASSTHROUGH"
      acltype = "nfsv4"
      copies  = 1
    }
    media = {
      name    = "general/media"
      atime   = "OFF"
      aclmode = "PASSTHROUGH"
      acltype = "nfsv4"
      copies  = 1
    }
    backup = {
      name    = "general/backup"
      atime   = "OFF"
      aclmode = "PASSTHROUGH"
      acltype = "nfsv4"
      copies  = 1
    }
  }

  nfs_shares = {
    media = {
      path = "/mnt/general/media"
    }
    backup = {
      path = "/mnt/general/backup"
    }
    data = {
      path          = "/mnt/general/data"
      maproot_user  = "root"
      maproot_group = "wheel"
    }
  }

  smb_shares = {
    media  = { name = "media", path = "/mnt/general/media" }
    backup = { name = "backup", path = "/mnt/general/backup" }
    data   = { name = "data", path = "/mnt/general/data" }
  }
}
