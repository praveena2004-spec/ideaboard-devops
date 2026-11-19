# GCP implementation of the platform interface:
#   network   custom VPC + subnet, private services access for Cloud SQL
#   security  firewall: web -> VM, admin -> SSH/API; database has no public IP
#   database  Cloud SQL for PostgreSQL (private IP only)
#   compute   k3s on one Compute Engine VM  OR  GKE Standard + node pool

locals {
  prefix   = "${var.name}-${var.environment}"
  is_k3s   = var.cluster_flavor == "k3s"
  zone     = "${var.region}-${var.zone_suffix}"
  db_port  = 5432
  db_name  = replace(var.name, "-", "_")
  db_user  = replace(var.name, "-", "_")
  ssh_user = "ubuntu"
  vm_tag   = "${local.prefix}-k3s"

  # Cloud-neutral sizes -> GCP types. "small" = e2-micro (always-free tier in
  # us-central1/us-east1/us-west1).
  machine_types = { small = "e2-micro", medium = "e2-medium", large = "e2-standard-2" }
  db_tiers      = { micro = "db-f1-micro", small = "db-g1-small", medium = "db-custom-1-3840" }

  labels = {
    project     = var.name
    environment = var.environment
    managed-by  = "terraform"
  }
}

resource "google_project_service" "apis" {
  for_each = toset(concat(
    ["compute.googleapis.com", "servicenetworking.googleapis.com", "sqladmin.googleapis.com"],
    local.is_k3s ? [] : ["container.googleapis.com"],
  ))
  project            = var.project_id
  service            = each.value
  disable_on_destroy = false
}

# =============================== network ===================================
resource "google_compute_network" "this" {
  project                 = var.project_id
  name                    = local.prefix
  auto_create_subnetworks = false
  depends_on              = [google_project_service.apis]
}

resource "google_compute_subnetwork" "this" {
  project       = var.project_id
  name          = local.prefix
  region        = var.region
  network       = google_compute_network.this.id
  ip_cidr_range = var.subnet_cidr

  # Secondary ranges for GKE pods/services (VPC-native); unused by k3s.
  secondary_ip_range {
    range_name    = "pods"
    ip_cidr_range = "10.60.0.0/16"
  }
  secondary_ip_range {
    range_name    = "services"
    ip_cidr_range = "10.70.0.0/20"
  }
}

# Private services access: Cloud SQL gets an IP inside our VPC, not a public one.
resource "google_compute_global_address" "private_services" {
  project       = var.project_id
  name          = "${local.prefix}-private-services"
  purpose       = "VPC_PEERING"
  address_type  = "INTERNAL"
  prefix_length = 20
  network       = google_compute_network.this.id
}

resource "google_service_networking_connection" "this" {
  network                 = google_compute_network.this.id
  service                 = "servicenetworking.googleapis.com"
  reserved_peering_ranges = [google_compute_global_address.private_services.name]
}

# =============================== security ==================================
resource "google_compute_firewall" "web" {
  project       = var.project_id
  name          = "${local.prefix}-web"
  network       = google_compute_network.this.name
  description   = "Public HTTP to the app"
  source_ranges = ["0.0.0.0/0"]
  target_tags   = [local.vm_tag]
  allow {
    protocol = "tcp"
    ports    = ["80"]
  }
}

resource "google_compute_firewall" "admin" {
  count         = local.is_k3s ? 1 : 0
  project       = var.project_id
  name          = "${local.prefix}-admin"
  network       = google_compute_network.this.name
  description   = "SSH (key only) and Kubernetes API (client-cert auth)"
  source_ranges = var.admin_cidrs
  target_tags   = [local.vm_tag]
  allow {
    protocol = "tcp"
    ports    = ["22", "6443"]
  }
}

# =============================== database ==================================
resource "random_password" "db" {
  length  = 32
  special = false
}

resource "google_sql_database_instance" "this" {
  project          = var.project_id
  name             = local.prefix
  region           = var.region
  database_version = "POSTGRES_16"

  settings {
    edition           = "ENTERPRISE" # shared-core tiers (db-f1-micro) need the Enterprise edition
    tier              = local.db_tiers[var.db_size]
    availability_type = var.db_high_availability ? "REGIONAL" : "ZONAL"
    disk_size         = 10
    disk_autoresize   = true
    user_labels       = local.labels

    ip_configuration {
      ipv4_enabled    = false # no public IP
      private_network = google_compute_network.this.id
    }

    backup_configuration {
      enabled = true
    }
  }

  # Demo-friendly teardown. Set true for real production.
  deletion_protection = false
  depends_on          = [google_service_networking_connection.this]
}

resource "google_sql_database" "this" {
  project  = var.project_id
  name     = local.db_name
  instance = google_sql_database_instance.this.name
}

resource "google_sql_user" "this" {
  project  = var.project_id
  name     = local.db_user
  instance = google_sql_database_instance.this.name
  password = random_password.db.result
}

# ======================== compute: k3s on one VM ==========================
resource "tls_private_key" "ssh" {
  count     = local.is_k3s ? 1 : 0
  algorithm = "ED25519"
}

resource "google_compute_instance" "k3s" {
  count        = local.is_k3s ? 1 : 0
  project      = var.project_id
  name         = "${local.prefix}-k3s"
  zone         = local.zone
  machine_type = local.machine_types[var.node_size]
  tags         = [local.vm_tag]
  labels       = local.labels

  boot_disk {
    initialize_params {
      image = "ubuntu-os-cloud/ubuntu-2404-lts-amd64"
      size  = 30            # always-free: 30 GB
      type  = "pd-standard" # always-free disk type
    }
  }

  network_interface {
    subnetwork = google_compute_subnetwork.this.id
    access_config {} # ephemeral public IP
  }

  metadata = {
    ssh-keys = "${local.ssh_user}:${tls_private_key.ssh[0].public_key_openssh}"
    startup-script = templatefile("${path.module}/../shared/k3s-bootstrap.sh.tftpl", {
      public_ip_cmd = "curl -s -H 'Metadata-Flavor: Google' http://metadata.google.internal/computeMetadata/v1/instance/network-interfaces/0/access-configs/0/external-ip"
    })
  }

  shielded_instance_config {
    enable_secure_boot = true
  }
}

# ===================== compute: managed GKE (optional) =====================
resource "google_container_cluster" "this" {
  count    = local.is_k3s ? 0 : 1
  project  = var.project_id
  name     = local.prefix
  location = local.zone

  min_master_version = var.kubernetes_version
  network            = google_compute_network.this.id
  subnetwork         = google_compute_subnetwork.this.id

  ip_allocation_policy {
    cluster_secondary_range_name  = "pods"
    services_secondary_range_name = "services"
  }

  remove_default_node_pool = true
  initial_node_count       = 1
  release_channel {
    channel = "REGULAR"
  }

  deletion_protection = false
  resource_labels     = local.labels
  depends_on          = [google_project_service.apis]
}

resource "google_container_node_pool" "default" {
  count      = local.is_k3s ? 0 : 1
  project    = var.project_id
  name       = "default"
  location   = local.zone
  cluster    = google_container_cluster.this[0].name
  node_count = var.node_count

  node_config {
    machine_type = local.machine_types[var.node_size]
    disk_size_gb = 30
    oauth_scopes = ["https://www.googleapis.com/auth/cloud-platform"]
    labels       = local.labels
    tags         = [local.vm_tag]
  }

  management {
    auto_repair  = true
    auto_upgrade = true
  }

  upgrade_settings {
    max_surge       = 1
    max_unavailable = 0
  }
}
