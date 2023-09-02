terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }

    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = ">= 2.23.0"
    }
  }
}

data "aws_availability_zones" "available" {}

provider "aws" {
  region = "ap-southeast-3"
}

locals {
  name   = basename(path.cwd)
  region = "ap-southeast-3"

  vpc_cidr = "10.4.0.0/16"
  azs      = slice(data.aws_availability_zones.available.names, 0, 2)

  tags = {
    Blueprint   = local.name
    Environment = "production"
    Stack       = "terraform"
  }
}


module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = ">= 5.1.0"

  name = local.name
  cidr = local.vpc_cidr

  azs             = local.azs
  public_subnets  = [for k, v in local.azs : cidrsubnet(local.vpc_cidr, 8, k)]
  private_subnets = [for k, v in local.azs : cidrsubnet(local.vpc_cidr, 8, k + 10)]

  enable_nat_gateway = true
  single_nat_gateway = true

  manage_default_network_acl = true
  default_network_acl_tags   = { Name = "${local.name}-default" }

  manage_default_route_table = true
  default_route_table_tags   = { Name = "${local.name}-default" }

  manage_default_security_group = true
  default_security_group_tags   = { Name = "${local.name}-default" }

  public_subnet_tags = {
    "kubernetes.io/role/elb" = 1
  }

  private_subnet_tags = {
    "kubernetes.io/role/internal-elb" = 1
  }

  tags = local.tags
}

module "eks_aws" {
  source  = "terraform-aws-modules/eks/aws"
  version = "19.16.0"

  cluster_version = "1.27"
  cluster_name    = "am-apps-production-jakarta"

  control_plane_subnet_ids = module.vpc.private_subnets
  subnet_ids               = module.vpc.public_subnets

  eks_managed_node_groups = {
    default = {
      instance_types = ["t4g.medium"]
      min_size       = 1
      max_size       = 3
      desired_size   = 2
    }
  }

  tags = local.tags
}

module "eks_blueprint_addons" {
  source  = "aws-ia/eks-blueprints-addons/aws"
  version = "~> 1.7.0"

  cluster_name      = module.eks_aws.cluster_name
  cluster_version   = module.eks_aws.cluster_version
  cluster_endpoint  = module.eks_aws.cluster_endpoint
  oidc_provider_arn = module.eks_aws.oidc_provider_arn

  eks_addons = {
    aws-ebs-csi-driver = {
      most_recent = true
    }
    coredns = {
      most_recent = true
    }
    vpc-cni = {
      most_recent = true
    }
    kube-proxy = {
      most_recent = true
    }
  }

  enable_cluster_autoscaler              = true
  enable_aws_load_balancer_controller    = true
  enable_cluster_proportional_autoscaler = true
  enable_kube_prometheus_stack           = true
  enable_metrics_server                  = true
  enable_external_dns                    = true
  enable_cert_manager                    = true
  cert_manager_route53_hosted_zone_arns  = ["arn:aws:route53:::hostedzone/Z10115252O1MXKVRS7C5Z"]

  tags = local.tags
}

provider "kubernetes" {
  host                   = module.eks_aws.cluster_endpoint
  cluster_ca_certificate = base64decode(module.eks_aws.cluster_certificate_authority_data)

  exec {
    api_version = "client.authentication.k8s.io/v1beta1"
    command     = "aws"
    # This requires the awscli to be installed locally where Terraform is executed
    args        = ["eks", "get-token", "--cluster-name", module.eks_aws.cluster_name]
  }
}

provider "helm" {
  kubernetes {
    host                   = module.eks_aws.cluster_endpoint
    cluster_ca_certificate = base64decode(module.eks_aws.cluster_certificate_authority_data)

    exec {
      api_version = "client.authentication.k8s.io/v1beta1"
      command     = "aws"
      # This requires the awscli to be installed locally where Terraform is executed
      args        = ["eks", "get-token", "--cluster-name", module.eks_aws.cluster_name]
    }
  }
}


resource "helm_release" "rancher" {
  name             = "rancher"
  chart            = "rancher"
  repository       = "https://releases.rancher.com/server-charts/stable"
  namespace        = "cattle-system"
  create_namespace = true

  set {
    name  = "hostname"
    value = "rancher-prod.aladinmall.id"
  }

  set {
    name  = "bootstrapPassword"
    value = "12345678"
  }

  set {
    name  = "letsEncrypt.ingress.class"
    value = "nginx"
  }

  set {
    name  = "letsEncrypt.email"
    value = "dev@aladinmall.id"
  }

  set {
    name  = "ingress.tls.source"
    value = "letsEncrypt"
  }

  depends_on = [
    module.eks_blueprint_addons
  ]
}

module "cert-manager" {
  source  = "terraform-iaac/cert-manager/kubernetes"
  version = "2.6.0"

  cluster_issuer_email = "admin@aladinmall.id"

  depends_on = [
    module.eks_blueprint_addons
  ]
}