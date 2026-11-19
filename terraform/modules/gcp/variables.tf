# ---------------------------------------------------------------------------
# Shared platform interface. modules/aws accepts exactly the same variables
# (plus its own cloud-specific ones at the bottom), so an environment switches
# cloud without changing its inputs. A third cloud = a third module with this
# interface.
# ---------------------------------------------------------------------------
variable "name" {
  description = "Base name for all resources, e.g. \"ideaboard\"."
  type        = string
}

variable "environment" {
  description = "Environment name, e.g. free-tier, staging, production."
  type        = string
}

variable "region" {
  description = "Cloud region."
  type        = string
}

variable "cluster_flavor" {
  description = "k3s = one VM running lightweight Kubernetes (free-tier friendly); managed = EKS/GKE."
  type        = string
  default     = "k3s"
  validation {
    condition     = contains(["k3s", "managed"], var.cluster_flavor)
    error_message = "cluster_flavor must be k3s or managed."
  }
}

variable "node_size" {
  description = "Cloud-neutral node size: small | medium | large."
  type        = string
  default     = "small"
  validation {
    condition     = contains(["small", "medium", "large"], var.node_size)
    error_message = "node_size must be small, medium or large."
  }
}

variable "node_count" {
  description = "Worker nodes (managed flavor only; k3s is always one VM)."
  type        = number
  default     = 2
}

variable "kubernetes_version" {
  description = "Kubernetes minor version for the managed flavor, or null for the default."
  type        = string
  default     = null
}

variable "db_size" {
  description = "Cloud-neutral database size: micro | small | medium."
  type        = string
  default     = "micro"
  validation {
    condition     = contains(["micro", "small", "medium"], var.db_size)
    error_message = "db_size must be micro, small or medium."
  }
}

variable "db_high_availability" {
  description = "Standby replica in a second zone (Multi-AZ / REGIONAL). Not free-tier."
  type        = bool
  default     = false
}

variable "admin_cidrs" {
  description = "CIDRs allowed to reach SSH and the Kubernetes API of the k3s VM. The API also needs to be reachable from your CI runners (GitHub-hosted runners have no fixed IPs)."
  type        = list(string)
  default     = ["0.0.0.0/0"]
}

# --- GCP-specific ---
variable "project_id" {
  description = "GCP project ID."
  type        = string
}

variable "zone_suffix" {
  description = "Zone within the region for the VM / zonal cluster (a, b, c, f...)."
  type        = string
  default     = "a"
}

variable "subnet_cidr" {
  description = "Primary CIDR of the VPC subnet."
  type        = string
  default     = "10.50.0.0/20"
}
