output "eks_cluster_endpoint" {
  value       = module.eks.cluster_endpoint
  description = "Cluster endpoint for eks aws"
}