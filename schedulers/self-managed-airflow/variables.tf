variable "name" {
  description = "Name of the VPC and EKS Cluster"
  type        = string
  default     = "self-managed-airflow"
}

variable "region" {
  description = "region"
  type        = string
  default     = "eu-west-1"
}

variable "eks_cluster_version" {
  description = "EKS Cluster version"
  type        = string
  default     = "1.23"
}

variable "vpc_cidr" {
  description = "VPC CIDR"
  type        = string
  default     = "10.0.0.0/16"
}
