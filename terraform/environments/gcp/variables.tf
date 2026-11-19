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

variable "node_count" {
  type    = number
  default = 2
}

variable "node_size" {
  type    = string
  default = "medium"
}

variable "kubernetes_version" {
  type    = string
  default = null
}

variable "project_id" {
  description = "GCP project ID (set via TF_VAR_project_id)."
  type        = string
}
