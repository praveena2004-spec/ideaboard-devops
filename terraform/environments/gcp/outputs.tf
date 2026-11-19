# Identical in environments/aws and environments/gcp: everything downstream (scripts/infra.sh, the
# pipeline) reads these names and never needs to know which cloud it is.
output "cloud" { value = module.platform.cloud }
output "cluster_flavor" { value = module.platform.cluster_flavor }
output "cluster_name" { value = module.platform.cluster_name }
output "public_ip" { value = module.platform.public_ip }
output "ssh_user" { value = module.platform.ssh_user }
output "kubeconfig_command" { value = module.platform.kubeconfig_command }
output "database_host" { value = module.platform.database_host }
output "database_port" { value = module.platform.database_port }
output "database_name" { value = module.platform.database_name }
output "database_username" { value = module.platform.database_username }

output "database_password" {
  value     = module.platform.database_password
  sensitive = true
}

output "ssh_private_key" {
  value     = module.platform.ssh_private_key
  sensitive = true
}
