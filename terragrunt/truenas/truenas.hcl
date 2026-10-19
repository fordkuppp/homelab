# TrueNAS provider and version pin, shared by every truenas unit.
# Included alongside root.hcl, which owns the shared backend and secrets.
locals {
  secrets = yamldecode(sops_decrypt_file("${get_repo_root()}/sops/secrets.enc.yaml"))
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
