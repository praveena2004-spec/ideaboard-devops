# GCP entry point. Prefer the wrapper:  scripts/infra.sh gcp free-tier apply
# (requires TF_VAR_project_id). Credentials come from Application Default
# Credentials (`gcloud auth application-default login`, or Workload Identity in CI).

terraform {
  required_version = ">= 1.6"
  required_providers {
    google = {
      source  = "hashicorp/google"
      version = ">= 5.30, < 8.0"
    }
  }

  # Remote state for teams: uncomment and fill in (bucket must already exist).
  # backend "gcs" {
  #   bucket = "my-tf-state-bucket"
  #   prefix = "ideaboard"
  # }
}

provider "google" {
  project = var.project_id
  region  = var.region
}

module "platform" {
  source = "../../modules/gcp"

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
  project_id           = var.project_id
}
