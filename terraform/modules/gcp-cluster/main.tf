# GCP implementation of the cluster interface: a zonal GKE Standard cluster
# on the project's default network with one managed node pool.

locals {
  cluster_name = "${var.name}-${var.environment}"
  location     = "${var.region}-${var.zone_suffix}"
  # Cloud-neutral size -> GCE machine type.
  machine_types = {
    small  = "e2-small"
    medium = "e2-medium"
    large  = "e2-standard-2"
  }
  labels = {
    project     = var.name
    environment = var.environment
    managed-by  = "terraform"
  }
}

resource "google_project_service" "container" {
  project            = var.project_id
  service            = "container.googleapis.com"
  disable_on_destroy = false
}

resource "google_container_cluster" "this" {
  project  = var.project_id
  name     = local.cluster_name
  location = local.location

  min_master_version = var.kubernetes_version

  # Manage nodes with the separate node pool below instead of the default pool.
  remove_default_node_pool = true
  initial_node_count       = 1

  release_channel {
    channel = "REGULAR"
  }

  # Allow `terraform destroy` for demo environments. Set true for real production.
  deletion_protection = false

  resource_labels = local.labels
  depends_on      = [google_project_service.container]
}

resource "google_container_node_pool" "default" {
  project    = var.project_id
  name       = "default"
  location   = local.location
  cluster    = google_container_cluster.this.name
  node_count = var.node_count

  node_config {
    machine_type = local.machine_types[var.node_size]
    disk_size_gb = 30
    oauth_scopes = ["https://www.googleapis.com/auth/cloud-platform"]
    labels       = local.labels
  }

  management {
    auto_repair  = true
    auto_upgrade = true
  }

  # Replace nodes one at a time during upgrades.
  upgrade_settings {
    max_surge       = 1
    max_unavailable = 0
  }
}
