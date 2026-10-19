# Standalone unit: root.hcl generates proxmox-specific provider/versions blocks,
# and terragrunt rejects same-named generate blocks in a child, so this unit
# defines its own backend and providers rather than including root.
locals {
  secrets = yamldecode(sops_decrypt_file("${get_repo_root()}/sops/secrets.enc.yaml"))
}

terraform {
  source = "../../modules/truenas-snapshots"
}

remote_state {
  backend = "s3"
  generate = {
    path      = "backend.tf"
    if_exists = "overwrite_terragrunt"
  }
  config = {
    endpoint   = "https://${local.secrets.cloudflare.r2.account_id}.r2.cloudflarestorage.com"
    bucket     = local.secrets.cloudflare.r2.bucket_name
    key        = "truenas/snapshots/tofu.tfstate"
    region     = "auto"
    access_key = local.secrets.cloudflare.r2.access_key
    secret_key = local.secrets.cloudflare.r2.secret_key

    skip_credentials_validation = true
    skip_metadata_api_check     = true
    skip_region_validation      = true
    skip_requesting_account_id  = true
    skip_s3_checksum            = true
    use_path_style              = true
  }
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
