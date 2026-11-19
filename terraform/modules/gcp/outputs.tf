# Shared output interface (identical names in modules/aws).
output "cloud" {
  value = "gcp"
}

output "cluster_flavor" {
  value = var.cluster_flavor
}

output "cluster_name" {
  value = local.is_k3s ? google_compute_instance.k3s[0].name : google_container_cluster.this[0].name
}

output "public_ip" {
  description = "k3s flavor: the VM's public IP (the app is served on http://<ip>/). Managed flavor: null - use the LoadBalancer Service address."
  value       = local.is_k3s ? google_compute_instance.k3s[0].network_interface[0].access_config[0].nat_ip : null
}

output "ssh_user" {
  value = local.ssh_user
}

output "ssh_private_key" {
  description = "k3s flavor only: key used by scripts/infra.sh to fetch the kubeconfig."
  value       = local.is_k3s ? tls_private_key.ssh[0].private_key_openssh : null
  sensitive   = true
}

output "kubeconfig_command" {
  value = local.is_k3s ? "scripts/infra.sh gcp <tfvars> kubeconfig" : "gcloud container clusters get-credentials ${google_container_cluster.this[0].name} --zone ${local.zone} --project ${var.project_id}"
}

output "database_host" {
  value = google_sql_database_instance.this.private_ip_address
}

output "database_port" {
  value = local.db_port
}

output "database_name" {
  value = local.db_name
}

output "database_username" {
  value = local.db_user
}

output "database_password" {
  value     = random_password.db.result
  sensitive = true
}
