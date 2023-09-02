output "eks_cluster_endpoint" {
  value       = module.eks_aws.cluster_endpoint
  description = "Cluster endpoint for eks aws"
}