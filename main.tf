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

  public_subnet_tags = {
    "kubernetes.io/role/elb" = 1
  }

  private_subnet_tags = {
    "kubernetes.io/role/internal-elb" = 1
  }

  tags = local.tags
}

module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "19.16.0"

  cluster_version = "1.27"
  cluster_name    = "am-apps-production-jakarta"

  vpc_id     = module.vpc.vpc_id
  subnet_ids = module.vpc.public_subnets

  eks_managed_node_groups = {
    default = {
      instance_types = ["t4.medium"]
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

  cluster_name      = module.eks.cluster_name
  cluster_version   = module.eks.cluster_version
  cluster_endpoint  = module.eks.cluster_endpoint
  oidc_provider_arn = module.eks.oidc_provider_arn

  eks_addons = {
    coredns    = {}
    vpc-cni    = {}
    kube-proxy = {}
  }

  enable_kube_prometheus_stack           = true
  enable_metrics_server                  = true
  enable_cert_manager                    = true
  cert_manager_route53_hosted_zone_arns  = ["arn:aws:route53:::hostedzone/Z10115252O1MXKVRS7C5Z"]

  tags = local.tags
}

provider "kubernetes" {
  host                   = module.eks.cluster_endpoint
  cluster_ca_certificate = base64decode(module.eks.cluster_certificate_authority_data)

  exec {
    api_version = "client.authentication.k8s.io/v1beta1"
    command     = "aws"
    # This requires the awscli to be installed locally where Terraform is executed
    args        = ["eks", "get-token", "--cluster-name", module.eks.cluster_name]
  }
}

provider "helm" {
  kubernetes {
    host                   = module.eks.cluster_endpoint
    cluster_ca_certificate = base64decode(module.eks.cluster_certificate_authority_data)

    exec {
      api_version = "client.authentication.k8s.io/v1beta1"
      command     = "aws"
      # This requires the awscli to be installed locally where Terraform is executed
      args        = ["eks", "get-token", "--cluster-name", module.eks.cluster_name]
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
    value = "rancher-prod.noxymon.web.id"
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