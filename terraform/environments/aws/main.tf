# AWS entry point. Prefer the wrapper:  scripts/infra.sh aws free-tier apply
# (it runs terraform init / workspace select / apply -var-file=<name>.tfvars).
#
# Credentials come from the standard AWS chain (AWS_PROFILE, env vars, SSO, or
# OIDC in CI) - never put keys in this repo.

terraform {
  required_version = ">= 1.6"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 5.40, < 7.0"
    }
  }

  # Remote state for teams: uncomment and fill in (bucket must already exist).
  # backend "s3" {
  #   bucket       = "my-tf-state-bucket"
  #   key          = "ideaboard/terraform.tfstate"
  #   region       = "us-east-1"
  #   use_lockfile = true
  # }
}

provider "aws" {
  region = var.region
}

module "platform" {
  source = "../../modules/aws"

  name                 = var.name
  environment          = var.environment
  region               = var.region
  cluster_flavor       = var.cluster_flavor
  node_size            = var.node_size
  node_count           = var.node_count
  kubernetes_version   = var.kubernetes_version
  db_size              = var.db_size
  db_high_availability = var.db_high_availability
  admin_cidrs          = var.admin_cidrs
}
