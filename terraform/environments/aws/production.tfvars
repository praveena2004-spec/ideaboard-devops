# High-availability production (NOT free): EKS with 3 nodes + Multi-AZ RDS.
environment          = "production"
region               = "us-east-1"
cluster_flavor       = "managed"
node_size            = "medium"
node_count           = 3
db_size              = "small"
db_high_availability = true
