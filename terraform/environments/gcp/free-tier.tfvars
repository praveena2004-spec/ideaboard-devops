# Near-$0 on GCP: one always-free e2-micro VM (us-central1, 30 GB pd-standard)
# running k3s. Cloud SQL db-f1-micro is NOT in the always-free tier (~$9/month);
# it is covered by the $300 free-trial credit of a new GCP account.
environment          = "free-tier"
region               = "us-central1"
cluster_flavor       = "k3s"
node_size            = "small"
db_size              = "micro"
db_high_availability = false
admin_cidrs          = ["0.0.0.0/0"]
