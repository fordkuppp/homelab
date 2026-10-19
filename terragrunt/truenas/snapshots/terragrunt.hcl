include "root" {
  path   = find_in_parent_folders("root.hcl")
  expose = true
}

terraform {
  source = "../../modules/truenas-snapshots"
}

locals {
  secrets = include.root.locals.secrets
}

generate "versions" {
  path      = "versions.tf"
  if_exists = "overwrite"
  contents  = <<EOF
terraform {
  required_providers {
    truenas = {
      source  = "truenas/truenas"
      version = "~> 1.5"
    }
  }
}
EOF
}

generate "provider" {
  path      = "provider.tf"
  if_exists = "overwrite"
  contents  = <<EOF
provider "truenas" {
  endpoint = "${local.secrets.truenas.endpoint}"
  api_key  = "${local.secrets.truenas.api_key}"
  insecure = true
}
EOF
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
