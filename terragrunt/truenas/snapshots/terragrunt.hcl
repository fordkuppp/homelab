include "root" {
  path   = find_in_parent_folders("root.hcl")
  expose = true
}

include "truenas" {
  path = find_in_parent_folders("truenas.hcl")
}

terraform {
  source = "../../modules/truenas-snapshots"
}

inputs = {
  snapshot_tasks = {
    data_daily = {
      dataset        = "general/data"
      lifetime_value = 14
      lifetime_unit  = "DAY"
      naming_schema  = "auto-daily-%Y%m%d-%H%M"
      hour           = "1"
      minute         = "0"
    }
    data_weekly = {
      dataset        = "general/data"
      lifetime_value = 8
      lifetime_unit  = "WEEK"
      naming_schema  = "auto-weekly-%Y%m%d-%H%M"
      hour           = "1"
      minute         = "30"
      dow            = "0"
    }
    backup_daily = {
      dataset        = "general/backup"
      lifetime_value = 14
      lifetime_unit  = "DAY"
      naming_schema  = "auto-daily-%Y%m%d-%H%M"
      hour           = "2"
      minute         = "0"
    }
  }
}
