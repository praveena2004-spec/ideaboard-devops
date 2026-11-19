# Same variables as environments/aws (plus project_id). Values come from
# <environment>.tfvars - see free-tier.tfvars and production.tfvars.
variable "name" {
  type    = string
  default = "ideaboard"
}

variable "environment" {
  type = string
}

variable "region" {
  type    = string
  default = "us-central1"
}

variable "cluster_flavor" {
  type    = string
  default = "k3s"
}

variable "node_size" {
  type    = string
  default = "small"
}

variable "node_count" {
  type    = number
  default = 1
}

variable "kubernetes_version" {
  type    = string
  default = null
}

variable "db_size" {
  type    = string
  default = "micro"
}

variable "db_high_availability" {
  type    = bool
  default = false
}

variable "admin_cidrs" {
  type    = list(string)
  default = ["0.0.0.0/0"]
}

variable "project_id" {
  description = "GCP project ID (set via TF_VAR_project_id)."
  type        = string
}
