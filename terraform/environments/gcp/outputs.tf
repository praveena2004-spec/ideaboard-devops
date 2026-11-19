output "cloud" {
  value = module.cluster.cloud
}

output "cluster_name" {
  value = module.cluster.cluster_name
}

output "cluster_endpoint" {
  value = module.cluster.cluster_endpoint
}

output "kubeconfig_command" {
  value = module.cluster.kubeconfig_command
}
