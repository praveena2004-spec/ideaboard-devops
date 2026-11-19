# ---------------------------------------------------------------------------
# Shared cluster interface. modules/gcp-cluster accepts the SAME variables, so
# environments can switch cloud without changing their inputs.
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
  description = "Cloud region, e.g. us-east-1."
  type        = string
}

variable "node_count" {
  description = "Number of worker nodes."
  type        = number
  default     = 2
}

variable "node_size" {
  description = "Cloud-neutral node size: small | medium | large. Mapped to an instance type per cloud."
  type        = string
  default     = "medium"
  validation {
    condition     = contains(["small", "medium", "large"], var.node_size)
    error_message = "node_size must be small, medium or large."
  }
}

variable "kubernetes_version" {
  description = "Kubernetes minor version, or null for the provider default."
  type        = string
  default     = null
}

# --- AWS-specific ---
variable "vpc_cidr" {
  description = "CIDR for the cluster VPC."
  type        = string
  default     = "10.40.0.0/16"
}
