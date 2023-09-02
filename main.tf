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

provider "aws" {
  region = "ap-southeast-3"
}


module "vpc" {
  name       = "am.apps-production-private-jakarta"
  source     = "aws-ia/vpc/aws"
  version    = "4.3.0"
  az_count   = 1
  cidr_block = "10.4.0.0/16"

  subnets = {
    netmask = 16

    public = {
      name_prefix               = "am.subnet-public-"
      nat_gateway_configuration = "single_az"
    }

    private = {
      name_prefix             = "am.subnet-private-"
      connect_to_public_natgw = true
    }
  }
}

module "eks_aws" {
  source  = "terraform-aws-modules/eks/aws"
  version = "19.16.0"

  cluster_version = "1.27"
  cluster_name    = "am.apps-production-jakarta"

  eks_managed_node_groups = {
    default = {
      instance_types = ["t4g.medium"]
      min_size       = 1
      max_size       = 3
      desired_size   = 2
    }
  }
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
  cert_manager_route53_hosted_zone_arns  = ["arn:aws:route53:::hostedzone/Z07520773HJ9V1D5F6XH7"]

  tags = {
    Environment = "production"
    Stack       = "terraform"
  }
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