# ---------------------------------------------------------------------------
# Shared cluster interface - same variables as modules/aws-cluster.
# ---------------------------------------------------------------------------
variable "name" {
  description = "Base name for all resources, e.g. \"ideaboard\"."
  type        = string
}

variable "environment" {
  description = "staging or production."
  type        = string
  validation {
    condition     = contains(["staging", "production"], var.environment)
    error_message = "environment must be staging or production."
  }
}

variable "region" {
  description = "Cloud region, e.g. us-central1."
  type        = string
}

variable "node_count" {
  description = "Number of worker nodes (per zone for regional clusters; this module uses a zonal cluster)."
  type        = number
  default     = 2
}

variable "node_size" {
  description = "Cloud-neutral node size: small | medium | large. Mapped to a machine type per cloud."
  type        = string
  default     = "medium"
  validation {
    condition     = contains(["small", "medium", "large"], var.node_size)
    error_message = "node_size must be small, medium or large."
  }
}

variable "kubernetes_version" {
  description = "Minimum Kubernetes master version, or null for the release-channel default."
  type        = string
  default     = null
}

# --- GCP-specific ---
variable "project_id" {
  description = "GCP project ID."
  type        = string
}

variable "zone_suffix" {
  description = "Zone within the region for the zonal cluster (a, b, c...)."
  type        = string
  default     = "a"
}
