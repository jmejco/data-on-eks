variable "name" {
  description = "Name of the VPC and EKS Cluster"
  default     = "emr-eks-karpenter"
  type        = string
}

variable "region" {
  description = "region"
  type        = string
  default     = "eu-west-1"
}

variable "eks_cluster_version" {
  description = "EKS Cluster version"
  default     = "1.23"
  type        = string
}

variable "tags" {
  description = "Default tags"
  default     = {}
  type        = map(string)
}

variable "vpc_cidr" {
  description = "VPC CIDR"
  default     = "10.1.0.0/16"
  type        = string
}
