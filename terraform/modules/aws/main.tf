# AWS implementation of the platform interface:
#   network   VPC, public subnets (VM / nodes / load balancers), private subnets (database)
#   security  security groups: web -> VM, admin -> SSH/API, VPC -> database only
#   database  RDS PostgreSQL (private, encrypted)
#   compute   k3s on one EC2 instance  OR  EKS + managed node group
# No NAT gateway: nothing in the private subnets needs internet access, and
# NAT is the most common surprise cost.

locals {
  prefix   = "${var.name}-${var.environment}"
  is_k3s   = var.cluster_flavor == "k3s"
  azs      = slice(data.aws_availability_zones.available.names, 0, 2)
  db_port  = 5432
  db_name  = replace(var.name, "-", "_")
  db_user  = replace(var.name, "-", "_")
  ssh_user = "ubuntu"

  # Cloud-neutral sizes -> AWS types. "small"/"micro" are free-tier eligible
  # (check yours: aws ec2 describe-instance-types --filters Name=free-tier-eligible,Values=true).
  instance_types = { small = "t3.small", medium = "t3.medium", large = "t3.large" }
  db_classes     = { micro = "db.t3.micro", small = "db.t3.small", medium = "db.t3.medium" }

  tags = {
    Project     = var.name
    Environment = var.environment
    ManagedBy   = "terraform"
  }
}

data "aws_availability_zones" "available" {
  state = "available"
}

# =============================== network ===================================
resource "aws_vpc" "this" {
  cidr_block           = var.vpc_cidr
  enable_dns_support   = true
  enable_dns_hostnames = true
  tags                 = merge(local.tags, { Name = local.prefix })
}

resource "aws_internet_gateway" "this" {
  vpc_id = aws_vpc.this.id
  tags   = merge(local.tags, { Name = local.prefix })
}

resource "aws_subnet" "public" {
  count                   = 2
  vpc_id                  = aws_vpc.this.id
  cidr_block              = cidrsubnet(var.vpc_cidr, 8, count.index)
  availability_zone       = local.azs[count.index]
  map_public_ip_on_launch = true
  tags = merge(local.tags, {
    Name                                    = "${local.prefix}-public-${count.index}"
    "kubernetes.io/role/elb"                = "1" # lets EKS LoadBalancer Services use these subnets
    "kubernetes.io/cluster/${local.prefix}" = "shared"
  })
}

# Private subnets have no route to the internet at all.
resource "aws_subnet" "private" {
  count             = 2
  vpc_id            = aws_vpc.this.id
  cidr_block        = cidrsubnet(var.vpc_cidr, 8, count.index + 10)
  availability_zone = local.azs[count.index]
  tags              = merge(local.tags, { Name = "${local.prefix}-private-${count.index}" })
}

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.this.id
  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.this.id
  }
  tags = merge(local.tags, { Name = "${local.prefix}-public" })
}

resource "aws_route_table_association" "public" {
  count          = 2
  subnet_id      = aws_subnet.public[count.index].id
  route_table_id = aws_route_table.public.id
}

# =============================== security ==================================
resource "aws_security_group" "node" {
  name        = "${local.prefix}-node"
  description = "Kubernetes node: public web traffic, admin access, all egress"
  vpc_id      = aws_vpc.this.id
  tags        = local.tags
}

resource "aws_vpc_security_group_ingress_rule" "node_http" {
  security_group_id = aws_security_group.node.id
  description       = "Public HTTP to the app"
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "tcp"
  from_port         = 80
  to_port           = 80
}

resource "aws_vpc_security_group_ingress_rule" "node_https" {
  security_group_id = aws_security_group.node.id
  description       = "Public HTTPS to the app"
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "tcp"
  from_port         = 443
  to_port           = 443
}

resource "aws_vpc_security_group_ingress_rule" "node_admin" {
  for_each          = local.is_k3s ? { for pair in setproduct(var.admin_cidrs, [22, 6443]) : "${pair[0]}-${pair[1]}" => pair } : {}
  security_group_id = aws_security_group.node.id
  description       = each.value[1] == 22 ? "SSH (key only)" : "Kubernetes API (client-cert auth)"
  cidr_ipv4         = each.value[0]
  ip_protocol       = "tcp"
  from_port         = each.value[1]
  to_port           = each.value[1]
}

resource "aws_vpc_security_group_egress_rule" "node_all" {
  security_group_id = aws_security_group.node.id
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "-1"
}

resource "aws_security_group" "db" {
  name        = "${local.prefix}-db"
  description = "PostgreSQL: only reachable from inside the VPC"
  vpc_id      = aws_vpc.this.id
  tags        = local.tags
}

resource "aws_vpc_security_group_ingress_rule" "db_from_vpc" {
  security_group_id = aws_security_group.db.id
  description       = "PostgreSQL from workloads in this VPC"
  cidr_ipv4         = var.vpc_cidr
  ip_protocol       = "tcp"
  from_port         = local.db_port
  to_port           = local.db_port
}

# =============================== database ==================================
resource "random_password" "db" {
  length  = 32
  special = false # avoids characters RDS rejects and URL-escaping issues
}

resource "aws_db_subnet_group" "this" {
  name       = local.prefix
  subnet_ids = aws_subnet.private[*].id
  tags       = local.tags
}

resource "aws_db_instance" "this" {
  identifier     = local.prefix
  engine         = "postgres"
  engine_version = "16"
  instance_class = local.db_classes[var.db_size]

  allocated_storage = 20    # free tier: up to 20 GB
  storage_type      = "gp2" # free tier: General Purpose SSD
  storage_encrypted = true

  db_name  = local.db_name
  username = local.db_user
  password = random_password.db.result
  port     = local.db_port

  db_subnet_group_name   = aws_db_subnet_group.this.name
  vpc_security_group_ids = [aws_security_group.db.id]
  publicly_accessible    = false
  multi_az               = var.db_high_availability

  backup_retention_period    = 1
  auto_minor_version_upgrade = true
  apply_immediately          = true
  # Demo-friendly teardown. For real production: deletion_protection = true,
  # skip_final_snapshot = false.
  deletion_protection = false
  skip_final_snapshot = true

  tags = local.tags
}

# ======================== compute: k3s on one VM ==========================
resource "tls_private_key" "ssh" {
  count     = local.is_k3s ? 1 : 0
  algorithm = "ED25519"
}

resource "aws_key_pair" "this" {
  count      = local.is_k3s ? 1 : 0
  key_name   = local.prefix
  public_key = tls_private_key.ssh[0].public_key_openssh
  tags       = local.tags
}

data "aws_ami" "ubuntu" {
  most_recent = true
  owners      = ["099720108685", "099720109477"] # Canonical publisher accounts
  filter {
    name   = "name"
    values = ["ubuntu/images/hvm-ssd*/ubuntu-noble-24.04-amd64-server-*"] # matches hvm-ssd and hvm-ssd-gp3
  }
  filter {
    name   = "architecture"
    values = ["x86_64"]
  }
}

resource "aws_instance" "k3s" {
  count                  = local.is_k3s ? 1 : 0
  ami                    = data.aws_ami.ubuntu.id
  instance_type          = local.instance_types[var.node_size]
  subnet_id              = aws_subnet.public[0].id
  vpc_security_group_ids = [aws_security_group.node.id]
  key_name               = aws_key_pair.this[0].key_name

  user_data = templatefile("${path.module}/../shared/k3s-bootstrap.sh.tftpl", {
    # IMDSv2: token first, then the public IP.
    public_ip_cmd = "curl -s http://169.254.169.254/latest/meta-data/public-ipv4 -H \"X-aws-ec2-metadata-token: $(curl -s -X PUT http://169.254.169.254/latest/api/token -H 'X-aws-ec2-metadata-token-ttl-seconds: 60')\""
  })

  metadata_options {
    http_tokens = "required" # IMDSv2 only
  }

  # T3 defaults to "unlimited" CPU credits, which bills sustained CPU usage.
  # "standard" throttles instead - no surprise charges.
  credit_specification {
    cpu_credits = "standard"
  }

  root_block_device {
    volume_size = 30 # free tier: up to 30 GB
    volume_type = "gp2"
    encrypted   = true
  }

  tags = merge(local.tags, { Name = "${local.prefix}-k3s" })
}

# ===================== compute: managed EKS (optional) =====================
resource "aws_iam_role" "cluster" {
  count = local.is_k3s ? 0 : 1
  name  = "${local.prefix}-eks-cluster"
  assume_role_policy = jsonencode({
    Version   = "2012-10-17"
    Statement = [{ Effect = "Allow", Principal = { Service = "eks.amazonaws.com" }, Action = "sts:AssumeRole" }]
  })
  tags = local.tags
}

resource "aws_iam_role_policy_attachment" "cluster" {
  count      = local.is_k3s ? 0 : 1
  role       = aws_iam_role.cluster[0].name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSClusterPolicy"
}

resource "aws_iam_role" "node" {
  count = local.is_k3s ? 0 : 1
  name  = "${local.prefix}-eks-node"
  assume_role_policy = jsonencode({
    Version   = "2012-10-17"
    Statement = [{ Effect = "Allow", Principal = { Service = "ec2.amazonaws.com" }, Action = "sts:AssumeRole" }]
  })
  tags = local.tags
}

resource "aws_iam_role_policy_attachment" "node" {
  for_each = local.is_k3s ? toset([]) : toset([
    "arn:aws:iam::aws:policy/AmazonEKSWorkerNodePolicy",
    "arn:aws:iam::aws:policy/AmazonEKS_CNI_Policy",
    "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly",
  ])
  role       = aws_iam_role.node[0].name
  policy_arn = each.value
}

resource "aws_eks_cluster" "this" {
  count    = local.is_k3s ? 0 : 1
  name     = local.prefix
  role_arn = aws_iam_role.cluster[0].arn
  version  = var.kubernetes_version

  vpc_config {
    subnet_ids = aws_subnet.public[*].id
  }

  # Whoever runs `terraform apply` gets cluster-admin.
  access_config {
    authentication_mode                         = "API_AND_CONFIG_MAP"
    bootstrap_cluster_creator_admin_permissions = true
  }

  tags       = local.tags
  depends_on = [aws_iam_role_policy_attachment.cluster]
}

resource "aws_eks_node_group" "default" {
  count           = local.is_k3s ? 0 : 1
  cluster_name    = aws_eks_cluster.this[0].name
  node_group_name = "default"
  node_role_arn   = aws_iam_role.node[0].arn
  subnet_ids      = aws_subnet.public[*].id
  instance_types  = [local.instance_types[var.node_size]]

  scaling_config {
    desired_size = var.node_count
    min_size     = 1
    max_size     = var.node_count + 1
  }

  update_config {
    max_unavailable = 1
  }

  tags       = local.tags
  depends_on = [aws_iam_role_policy_attachment.node]
}
