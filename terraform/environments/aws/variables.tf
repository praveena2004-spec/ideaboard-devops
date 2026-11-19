variable "name" {
  type    = string
  default = "ideaboard"
}

variable "environment" {
  type = string
}

variable "region" {
  type    = string
  default = "us-east-1"
}

variable "node_count" {
  type    = number
  default = 2
}

variable "node_size" {
  type    = string
  default = "medium"
}

variable "kubernetes_version" {
  type    = string
  default = null
}
