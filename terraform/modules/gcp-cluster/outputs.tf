# Shared output interface (identical names in modules/aws-cluster).
output "cloud" {
  value = "gcp"
}

output "cluster_name" {
  value = google_container_cluster.this.name
}

output "cluster_endpoint" {
  value = "https://${google_container_cluster.this.endpoint}"
}

output "cluster_ca_certificate" {
  description = "Base64-encoded cluster CA certificate."
  value       = google_container_cluster.this.master_auth[0].cluster_ca_certificate
}

output "kubeconfig_command" {
  description = "Run this to point kubectl at the cluster."
  value       = "gcloud container clusters get-credentials ${google_container_cluster.this.name} --zone ${local.location} --project ${var.project_id}"
}
