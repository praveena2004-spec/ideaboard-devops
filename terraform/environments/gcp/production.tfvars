# High-availability production (NOT free): GKE with 3 nodes + REGIONAL Cloud SQL.
environment          = "production"
region               = "us-central1"
cluster_flavor       = "managed"
node_size            = "medium"
node_count           = 3
db_size              = "small"
db_high_availability = true
