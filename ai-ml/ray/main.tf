
locals {
  name      = var.name
  region    = var.region
  namespace = "ray-cluster"

  vpc_cidr = var.vpc_cidr
  azs      = slice(data.aws_availability_zones.available.names, 0, 3)

  tags = {
    Blueprint  = local.name
    GithubRepo = "github.com/awslabs/data-on-eks"
  }
}

#---------------------------------------------------------------
# EKS Blueprints
#---------------------------------------------------------------
module "eks_blueprints" {
  source = "github.com/aws-ia/terraform-aws-eks-blueprints?ref=v4.12.2"

  cluster_name    = local.name
  cluster_version = var.eks_cluster_version

  vpc_id             = module.vpc.vpc_id
  private_subnet_ids = module.vpc.private_subnets

  #----------------------------------------------------------------------------------------------------------#
  # Security groups used in this module created by the upstream modules terraform-aws-eks (https://github.com/terraform-aws-modules/terraform-aws-eks).
  #   Upstream module implemented Security groups based on the best practices doc https://docs.aws.amazon.com/eks/latest/userguide/sec-group-reqs.html.
  #   So, by default the security groups are restrictive. Users needs to enable rules for specific ports required for App requirement or Add-ons
  #   See the notes below for each rule used in these examples
  #----------------------------------------------------------------------------------------------------------#
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
    mg_5 = {
      node_group_name = "managed-ondemand"
      instance_types  = ["m5.8xlarge"]
      min_size        = 3
      subnet_ids      = module.vpc.private_subnets
    }
  }

  tags = local.tags
}

#---------------------------------------------------------------
# Deploy Ray Cluster Resources
#---------------------------------------------------------------
resource "aws_kms_key" "objects" {
  enable_key_rotation     = true
  description             = "KMS key is used to encrypt bucket objects"
  deletion_window_in_days = 7
}

#tfsec:ignore:aws-s3-enable-bucket-logging tfsec:ignore:aws-s3-enable-versioning
module "s3_bucket" {
  source  = "terraform-aws-modules/s3-bucket/aws"
  version = "v3.3.0"

  bucket_prefix           = "ray-demo-models-"
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true

  server_side_encryption_configuration = {
    rule = {
      apply_server_side_encryption_by_default = {
        kms_master_key_id = aws_kms_key.objects.arn
        sse_algorithm     = "aws:kms"
      }
    }
  }
}

resource "aws_iam_policy" "irsa_policy" {
  description = "IAM Policy for IRSA"
  name_prefix = substr("${module.eks_blueprints.eks_cluster_id}-${local.namespace}-access", 0, 127)
  policy      = data.aws_iam_policy_document.irsa_policy.json
}

module "cluster_irsa" {
  source                     = "github.com/aws-ia/terraform-aws-eks-blueprints//modules/irsa"
  kubernetes_namespace       = local.namespace
  kubernetes_service_account = "${local.namespace}-sa"
  irsa_iam_policies          = [aws_iam_policy.irsa_policy.arn]
  eks_cluster_id             = module.eks_blueprints.eks_cluster_id
  eks_oidc_provider_arn      = module.eks_blueprints.eks_oidc_provider_arn

  depends_on = [module.s3_bucket]
}

resource "kubectl_manifest" "cluster_provisioner" {
  yaml_body = templatefile("ray-clusters/example-cluster.yaml", {
    namespace       = local.namespace
    hostname        = var.eks_cluster_domain == null ? "" : var.eks_cluster_domain
    account_id      = data.aws_caller_identity.current.account_id
    region          = local.region
    service_account = "${local.namespace}-sa"
  })

  depends_on = [
    module.cluster_irsa,
    module.eks_blueprints_kubernetes_addons
  ]
}

#---------------------------------------------------------------
# Monitoring
#---------------------------------------------------------------
resource "kubectl_manifest" "prometheus" {
  yaml_body = templatefile("monitoring/monitor.yaml", {
    namespace = local.namespace
  })

  depends_on = [
    module.eks_blueprints_kubernetes_addons,
    kubectl_manifest.cluster_provisioner
  ]
}

resource "random_password" "grafana" {
  length           = 16
  special          = true
  override_special = "!#$%&*()-_=+[]{}<>:?"
}

#tfsec:ignore:aws-ssm-secret-use-customer-key
resource "aws_secretsmanager_secret" "grafana" {
  name_prefix             = "grafana-"
  recovery_window_in_days = 0 # Set to zero for this example to force delete during Terraform destroy
}

resource "aws_secretsmanager_secret_version" "grafana" {
  secret_id     = aws_secretsmanager_secret.grafana.id
  secret_string = random_password.grafana.result
}

resource "grafana_folder" "ray" {
  title = "ray"

  depends_on = [
    module.eks_blueprints_kubernetes_addons
  ]
}

resource "grafana_dashboard" "ray" {
  for_each = fileset("${path.module}/monitoring", "*.json")

  config_json = file("${path.module}/monitoring/${each.value}")
  folder      = grafana_folder.ray.id
}
