# Proxmox-specific provider and version pins. Included alongside root.hcl,
# which owns the shared backend and secrets. Kept separate because terragrunt
# rejects same-named generate blocks between parent and child, so a non-proxmox
# unit cannot include a root that declares these.
locals {
  secrets = yamldecode(sops_decrypt_file("${get_repo_root()}/sops/secrets.enc.yaml"))
}

generate "provider" {
  path      = "provider.tf"
  if_exists = "overwrite"
  contents  = <<EOF
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
  path      = "versions.tf"
  if_exists = "overwrite_terragrunt"
  contents  = <<EOF
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