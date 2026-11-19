# Root configuration for GCP. Usage (one workspace per environment):
#   export TF_VAR_project_id=<your-gcp-project>
#   terraform init
#   terraform workspace select -or-create staging
#   terraform plan  -var-file=staging.tfvars
#   terraform apply -var-file=staging.tfvars
#
# Credentials come from Application Default Credentials
# (`gcloud auth application-default login`, or Workload Identity in CI).

terraform {
  required_version = ">= 1.6"
  required_providers {
    google = {
      source  = "hashicorp/google"
      version = ">= 5.0, < 8.0"
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

module "cluster" {
  source = "../../modules/gcp-cluster"

  name               = var.name
  environment        = var.environment
  region             = var.region
  node_count         = var.node_count
  node_size          = var.node_size
  kubernetes_version = var.kubernetes_version
  project_id         = var.project_id
}
