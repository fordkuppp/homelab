variable "datasets" {
  description = "ZFS datasets to manage"
  type = map(object({
    name        = string
    atime       = optional(string)
    aclmode     = optional(string)
    acltype     = optional(string)
    copies      = optional(number)
    comments    = optional(string)
    compression = optional(string)
  }))
  default = {}
}

variable "nfs_shares" {
  description = "NFS exports"
  type = map(object({
    path          = string
    enabled       = optional(bool, true)
    ro            = optional(bool, false)
    hosts         = optional(list(string), [])
    networks      = optional(list(string), [])
    maproot_user  = optional(string)
    maproot_group = optional(string)
    comment       = optional(string)
  }))
  default = {}
}

variable "smb_shares" {
  description = "SMB shares"
  type = map(object({
    name    = string
    path    = string
    enabled = optional(bool, true)
    comment = optional(string)
  }))
  default = {}
}
