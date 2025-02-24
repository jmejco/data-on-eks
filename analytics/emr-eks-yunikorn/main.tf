#---------------------------------------------------------------
# EKS Blueprints
#---------------------------------------------------------------
module "eks_blueprints" {
  source = "github.com/aws-ia/terraform-aws-eks-blueprints?ref=v4.12.2"

  cluster_name    = local.name
  cluster_version = var.eks_cluster_version

  vpc_id             = module.vpc.vpc_id
  private_subnet_ids = module.vpc.private_subnets

  cluster_endpoint_private_access = true # if true, Kubernetes API requests within your cluster's VPC (such as node to control plane communication) use the private VPC endpoint
  cluster_endpoint_public_access  = true # if true, Your cluster API server is accessible from the internet. You can, optionally, limit the CIDR blocks that can access the public endpoint.

  #---------------------------------------
  # Note: This can further restricted to specific required for each Add-on and your application
  #---------------------------------------
  node_security_group_additional_rules = {
    # Extend node-to-node security group rules. Recommended and required for the Add-ons
    ingress_self_all = {
      description = "Node to node all ports/protocols"
      protocol    = "-1"
      from_port   = 0
      to_port     = 0
      type        = "ingress"
      self        = true
    }
    # Recommended outbound traffic for Node groups
    egress_all = {
      description      = "Node all egress"
      protocol         = "-1"
      from_port        = 0
      to_port          = 0
      type             = "egress"
      cidr_blocks      = ["0.0.0.0/0"]
      ipv6_cidr_blocks = ["::/0"]
    }
    # Allows Control Plane Nodes to talk to Worker nodes on all ports. Added this to simplify the example and further avoid issues with Add-ons communication with Control plane.
    # This can be restricted further to specific port based on the requirement for each Add-on e.g., metrics-server 4443, analytics-operator 8080, karpenter 8443 etc.
    # Change this according to your security requirements if needed
    ingress_cluster_to_node_all_traffic = {
      description                   = "Cluster API to Nodegroup all traffic"
      protocol                      = "-1"
      from_port                     = 0
      to_port                       = 0
      type                          = "ingress"
      source_cluster_security_group = true
    }
  }

  managed_node_groups = {
    # Core node group for deploying all the critical add-ons
    mng1 = {
      node_group_name = "core-node-grp"
      subnet_ids      = module.vpc.private_subnets

      instance_types = ["m5.xlarge"]
      ami_type       = "AL2_x86_64"
      capacity_type  = "ON_DEMAND"

      disk_size = 100
      disk_type = "gp3"

      max_size               = 9
      min_size               = 3
      desired_size           = 3
      create_launch_template = true
      launch_template_os     = "amazonlinux2eks"

      update_config = [{
        max_unavailable_percentage = 50
      }]

      k8s_labels = {
        Environment   = "preprod"
        Zone          = "test"
        WorkerType    = "ON_DEMAND"
        NodeGroupType = "core"
      }

      additional_tags = {
        Name                                                             = "core-node-grp"
        subnet_type                                                      = "private"
        "k8s.io/cluster-autoscaler/node-template/label/arch"             = "x86"
        "k8s.io/cluster-autoscaler/node-template/label/kubernetes.io/os" = "linux"
        "k8s.io/cluster-autoscaler/node-template/label/noderole"         = "core"
        "k8s.io/cluster-autoscaler/node-template/label/node-lifecycle"   = "on-demand"
        "k8s.io/cluster-autoscaler/experiments"                          = "owned"
        "k8s.io/cluster-autoscaler/enabled"                              = "true"
      }
    },
    #---------------------------------------
    # Note: This example only uses ON_DEMAND node group for both Spark Driver and Executors.
    #   If you want to leverage SPOT nodes for Spark executors then create ON_DEMAND node group for placing your driver pods and SPOT nodegroup for executors.
    #   Use NodeSelectors to place your driver/executor pods with the help of Pod Templates.
    #---------------------------------------
    mng2 = {
      node_group_name = "spark-driver-grp"
      subnet_ids      = [module.vpc.private_subnets[0]]
      instance_types  = ["r5d.4xlarge"] # YuniKorn Gangschueduling Pause pods are not supporting ARM64 instances
      ami_type        = "AL2_x86_64"    # Graviton AL2_ARM_64
      capacity_type   = "ON_DEMAND"
      # Enable this option only when you are using NVMe disks
      format_mount_nvme_disk = true # Mounts NVMe disks to /local1, /local2 etc. for multiple NVMe disks

      # RAID0 configuration is recommended for better performance when you use larger instances with multiple NVMe disks e.g., r5d.24xlarge
      # Permissions for hadoop user runs the analytics job. user > hadoop:x:999:1000::/home/hadoop:/bin/bash
      post_userdata = <<-EOT
        #!/bin/bash
        set -ex
        /usr/bin/chown -hR +999:+1000 /local*
      EOT

      disk_size = 200
      disk_type = "gp3"

      max_size     = 20 # Managed node group soft limit is 450; request AWS for limit increase
      min_size     = 1
      desired_size = 1

      create_launch_template = true
      launch_template_os     = "amazonlinux2eks"

      update_config = [{
        max_unavailable_percentage = 50
      }]

      additional_iam_policies = []
      k8s_taints              = []

      k8s_labels = {
        Environment   = "PREPROD"
        Zone          = "TEST"
        WorkerType    = "ON_DEMAND"
        NodeGroupType = "SPARK_DRIVER"
      }

      additional_tags = {
        Name                                                             = "spark-driver-grp"
        subnet_type                                                      = "private"
        "k8s.io/cluster-autoscaler/node-template/label/arch"             = "arm64"
        "k8s.io/cluster-autoscaler/node-template/label/kubernetes.io/os" = "linux"
        "k8s.io/cluster-autoscaler/node-template/label/noderole"         = "spark"
        "k8s.io/cluster-autoscaler/node-template/label/disk"             = "nvme"
        "k8s.io/cluster-autoscaler/node-template/label/node-lifecycle"   = "on-demand"
        "k8s.io/cluster-autoscaler/experiments"                          = "owned"
        "k8s.io/cluster-autoscaler/enabled"                              = "true"
      }
    },
    mng3 = {
      node_group_name = "spark-exec-spot"
      subnet_ids      = [module.vpc.private_subnets[0]]
      instance_types  = ["r5d.4xlarge", "r5d.8xlarge", "r5d.12xlarge"] # Graviton ["r6gd.4xlarge", "r6gd.8xlarge", "r6gd.12xlarge"]
      ami_type        = "AL2_x86_64"                                   # Graviton AL2_ARM_64
      capacity_type   = "SPOT"

      # Enable this option only when you are using NVMe disks
      format_mount_nvme_disk = true # Mounts NVMe disks to /local1, /local2 etc. for multiple NVMe disks

      # RAID0 configuration is recommended for better performance when you use larger instances with multiple NVMe disks e.g., r5d.24xlarge
      # Permissions for hadoop user runs the analytics job. user > hadoop:x:999:1000::/home/hadoop:/bin/bash
      post_userdata = <<-EOT
        #!/bin/bash
        set -ex
        /usr/bin/chown -hR +999:+1000 /local*
      EOT

      disk_size = 200
      disk_type = "gp3"

      max_size     = 50 # Managed node group soft limit is 450; request AWS for limit increase
      min_size     = 1
      desired_size = 1

      create_launch_template = true
      launch_template_os     = "amazonlinux2eks"

      update_config = [{
        max_unavailable_percentage = 50
      }]

      additional_iam_policies = []
      k8s_taints              = []

      k8s_labels = {
        Environment   = "PREPROD"
        Zone          = "TEST"
        WorkerType    = "SPOT"
        NodeGroupType = "SPARK_EXEC_SPOT"
      }

      additional_tags = {
        Name                                                             = "spark-exec-spot"
        subnet_type                                                      = "private"
        "k8s.io/cluster-autoscaler/node-template/label/arch"             = "arm64"
        "k8s.io/cluster-autoscaler/node-template/label/kubernetes.io/os" = "linux"
        "k8s.io/cluster-autoscaler/node-template/label/noderole"         = "spark"
        "k8s.io/cluster-autoscaler/node-template/label/disk"             = "nvme"
        "k8s.io/cluster-autoscaler/node-template/label/node-lifecycle"   = "spot"
        "k8s.io/cluster-autoscaler/experiments"                          = "owned"
        "k8s.io/cluster-autoscaler/enabled"                              = "true"
      }
    },
  }

  #---------------------------------------
  # ENABLE EMR ON EKS
  # 1. Creates namespace
  # 2. k8s role and role binding(emr-containers user) for the above namespace
  # 3. IAM role for the team execution role
  # 4. Update AWS_AUTH config map with  emr-containers user and AWSServiceRoleForAmazonEMRContainers role
  # 5. Create a trust relationship between the job execution role and the identity of the EMR managed service account
  #---------------------------------------
  enable_emr_on_eks = true
  emr_on_eks_teams  = local.emr_on_eks_teams

  tags = local.tags
}

#---------------------------------------------------------------
# Example IAM policies for EMR job execution
#---------------------------------------------------------------
resource "aws_iam_policy" "emr_data_team_a" {
  name        = format("%s-%s", local.name, "emr-data-team-a")
  description = "IAM policy for EMR on EKS Job execution"
  path        = "/"
  policy      = data.aws_iam_policy_document.emr_on_eks.json
}

resource "aws_iam_policy" "emr_data_team_b" {
  name        = format("%s-%s", local.name, "emr-data-team-b")
  description = "IAM policy for EMR on EKS Job execution"
  path        = "/"
  policy      = data.aws_iam_policy_document.emr_on_eks.json
}

#---------------------------------------------------------------
# Create EMR on EKS Virtual Cluster
#---------------------------------------------------------------

resource "aws_emrcontainers_virtual_cluster" "this" {
  for_each = local.emr_on_eks_teams

  name = format("%s-%s", module.eks_blueprints.eks_cluster_id, each.value.namespace)
  container_provider {
    id   = module.eks_blueprints.eks_cluster_id
    type = "EKS"

    info {
      eks_info {
        namespace = each.value.namespace
      }
    }
  }
}

#---------------------------------------------------------------
# Amazon Prometheus Workspace
#---------------------------------------------------------------
resource "aws_prometheus_workspace" "amp" {
  alias = format("%s-%s", "amp-ws", local.name)

  tags = local.tags
}
