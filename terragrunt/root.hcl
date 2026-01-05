locals {
  secrets_path = "${get_repo_root()}/sops/secrets.enc.yaml"
  secrets = yamldecode(sops_decrypt_file(local.secrets_path))
}

remote_state {
  backend = "s3"
  generate = {
    path      = "backend.tf"
    if_exists = "overwrite_terragrunt"
  }
  config = {
    endpoint = "https://${local.secrets.cloudflare.r2.account_id}.r2.cloudflarestorage.com"
    bucket   = local.secrets.cloudflare.r2.bucket_name

    key      = "${path_relative_to_include()}/tofu.tfstate"

    region   = "auto"

    access_key = local.secrets.cloudflare.r2.access_key
    secret_key = local.secrets.cloudflare.r2.secret_key

    # Skip AWS specific settings
    skip_credentials_validation = true
    skip_metadata_api_check     = true
    skip_region_validation      = true
    skip_requesting_account_id  = true
    skip_s3_checksum            = true
    use_path_style              = true
  }
}

generate "provider" {
  path      = "provider.tf"
  if_exists = "overwrite"
  contents = <<EOF
provider "proxmox" {
  endpoint  = "${local.secrets.proxmox.endpoint}"
  api_token = "${local.secrets.proxmox.token_id}=${local.secrets.proxmox.token_secret}"
  insecure  = true

  ssh {
    agent  = true
    username = "${local.secrets.proxmox.ssh.host.username}"
    private_key = <<EOF_KEY
${local.secrets.proxmox.ssh.host.private_key}
EOF_KEY
  }
}
EOF
}

generate "versions" {
  path = "versions.tf"
  if_exists     = "overwrite_terragrunt"
  contents = <<EOF
terraform {
  required_providers {
    proxmox = {
      source  = "bpg/proxmox"
      version = "0.90.0"
    }
  }
}
EOF
}

inputs = {
  secrets = local.secrets
}