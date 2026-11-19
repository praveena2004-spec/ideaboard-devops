# $0 on an AWS free-tier account (covered by free-tier usage/credits):
# one t3.small (free-tier eligible, 2 GB) running k3s + one db.t3.micro RDS PostgreSQL (20 GB gp2), no NAT.
environment          = "free-tier"
region               = "us-east-1"
cluster_flavor       = "k3s"
node_size            = "small"
db_size              = "micro"
db_high_availability = false
# Tighten to your own IP for SSH if you like; the Kubernetes API must stay
# reachable from GitHub-hosted runners for the CD pipeline.
admin_cidrs = ["0.0.0.0/0"]
