# Root configuration for AWS. Usage (one workspace per environment):
#   terraform init
#   terraform workspace select -or-create staging
#   terraform plan  -var-file=staging.tfvars
#   terraform apply -var-file=staging.tfvars
#
# Credentials come from the standard AWS chain (AWS_PROFILE, env vars, SSO,
# or OIDC in CI) - never put keys in this repo.

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

module "cluster" {
  source = "../../modules/aws-cluster"

  name               = var.name
  environment        = var.environment
  region             = var.region
  node_count         = var.node_count
  node_size          = var.node_size
  kubernetes_version = var.kubernetes_version
}
