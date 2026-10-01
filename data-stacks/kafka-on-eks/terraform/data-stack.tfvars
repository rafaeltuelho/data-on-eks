name                     = "kafka-on-eks"
region                   = "us-east-2"
enable_amazon_prometheus = true

# Unique ID used to tag all AWS resources for this deployment.
# Enables identification of orphaned resources and cleanup in case of Terraform state loss.
# Auto-generated on first deploy — do not edit manually.
deployment_id = "DO-NOT-EDIT-AUTO-GENERATED"

#---------------------------------------------------------------
# Benchmark flavor: sized to compare against Redpanda BYOC Tier 1
# (3x m7gd.large brokers + 2x m5.large utility nodes, us-east-2a)
#---------------------------------------------------------------

# Not needed for the Kafka benchmark
enable_jupyterhub    = false
enable_ingress_nginx = false

# Replaces the default core node group (same map key). Redpanda BYOC Tier 1 uses
# 2x m5.large utility nodes; this stack runs more system add-ons (ArgoCD, Karpenter,
# kube-prometheus-stack, Strimzi operator), so one extra m5.large is added.
# Core nodes never host brokers, so this does not affect benchmark fairness.
# subnet_ids is omitted on purpose: the node group falls back to the cluster's
# subnet_ids (the same secondary 100.x private subnets used by the default).
managed_node_groups = {
  core_node_group = {
    name        = "core-node-group"
    description = "EKS Core node group for hosting system add-ons"

    ami_type     = "AL2023_x86_64_STANDARD"
    min_size     = 3
    max_size     = 4
    desired_size = 3

    instance_types = ["m5.large"]

    iam_role_additional_policies = {
      AmazonSSMManagedInstanceCore = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
    }

    ebs_optimized = true

    block_device_mappings = {
      xvda = {
        device_name = "/dev/xvda"
        ebs = {
          volume_size = 50
          volume_type = "gp3"
        }
      }
    }

    labels = {
      WorkerType    = "ON_DEMAND"
      NodeGroupType = "core"
    }

    # Literal copy of local.tags (DeploymentId can't be referenced from tfvars; the
    # provider default_tags still tag the node group itself)
    tags = {
      Name       = "core-node-grp"
      Blueprint  = "kafka-on-eks"
      GithubRepo = "github.com/awslabs/data-on-eks"
    }
  }
}
