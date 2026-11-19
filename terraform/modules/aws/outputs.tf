# Shared output interface (identical names in modules/gcp).
output "cloud" {
  value = "aws"
}

output "cluster_flavor" {
  value = var.cluster_flavor
}

output "cluster_name" {
  value = local.is_k3s ? "${local.prefix}-k3s" : aws_eks_cluster.this[0].name
}

output "public_ip" {
  description = "k3s flavor: the VM's public IP (the app is served on http://<ip>/). Managed flavor: null - use the LoadBalancer Service address."
  value       = local.is_k3s ? aws_instance.k3s[0].public_ip : null
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
  value = local.is_k3s ? "scripts/infra.sh aws <tfvars> kubeconfig" : "aws eks update-kubeconfig --region ${var.region} --name ${aws_eks_cluster.this[0].name}"
}

output "database_host" {
  value = aws_db_instance.this.address
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
