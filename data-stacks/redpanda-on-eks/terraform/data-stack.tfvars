name                     = "redpanda-on-eks"
region                   = "us-east-2"
enable_amazon_prometheus = true

# Unique ID used to tag all AWS resources for this deployment.
# Enables identification of orphaned resources and cleanup in case of Terraform state loss.
# Auto-generated on first deploy — do not edit manually.
deployment_id = "DO-NOT-EDIT-AUTO-GENERATED"

# Own VPC. Pick ranges that no client VPC (or anything it routes, e.g. Redpanda BYOC
# networks or kafka-on-eks: 10.0.0.0/16 + 100.64-66.0.0/16) already uses.
# Brokers run in the secondary subnet of redpanda_zone, the only range a client network
# needs to route to this VPC.
vpc_cidr        = "10.2.0.0/16"
secondary_cidrs = ["100.80.0.0/16", "100.81.0.0/16", "100.82.0.0/16"]

#---------------------------------------------------------------
# Redpanda cluster (see redpanda-variables.tf and README.md)
# Passwords and the license are NOT set here: export TF_VAR_redpanda_admin_password
# (optional, generated when unset) and TF_VAR_redpanda_enterprise_license (optional).
#---------------------------------------------------------------
# AZ for the brokers (one of the first 3 AZs of the region); put clients in the same AZ
redpanda_zone = "us-east-2a"

# Brokers: keep an odd number. To expand, raise this value and re-run ./deploy.sh
redpanda_broker_replicas = 3

# One dedicated node per broker with local NVMe (XFS). Production sizing from the
# Redpanda docs: >= 4 cores and >= 2 GiB per core. The m7gd.2xlarge (8 vCPU, 32 GiB,
# 474 GB NVMe) leaves room for the kubelet and DaemonSets.
redpanda_broker_instance_type = "m7gd.2xlarge"
redpanda_broker_cpu_cores     = 6
redpanda_broker_memory        = "24Gi"
redpanda_broker_storage_size  = "400Gi"

# Private DNS zone that the external listeners advertise (redpanda-<n>.<domain>)
redpanda_external_domain = "redpanda.internal"

# Client networks. The stack does not create VPC peering (like Redpanda BYOC): the client
# side peers with this VPC and routes. List the client CIDRs (firewall) and the client VPCs
# to associate with the private DNS zone. See "Connect a client VPC" in README.md.
# e.g. redpanda_client_cidrs = ["10.100.0.0/16"], redpanda_client_vpc_ids = ["vpc-0123456789abcdef0"]
redpanda_client_cidrs   = []
redpanda_client_vpc_ids = []

# SASL/SCRAM superuser for clients
redpanda_admin_username = "admin"

# Redpanda Console: always reachable with kubectl port-forward. Set to "internal" or
# "internet-facing" to also expose it through an NLB (restricted to redpanda_console_allowed_cidrs).
enable_redpanda_console   = true
redpanda_console_exposure = "none"

# Redpanda Connect sample pipeline: Helm chart without a license, operator Pipeline
# resource with one (redpanda_connect_deployment = "auto" | "helm" | "pipeline")
enable_redpanda_connect = false

# Built-in 30-day Enterprise trial (new clusters, no key): enables Tiered Storage and
# Continuous Data Balancing. After 30 days set a license or turn this off (README.md).
redpanda_enterprise_builtin_trial = true

# Enterprise features, applied with TF_VAR_redpanda_enterprise_license (or the trial above
# for the cluster-side ones; see "Enterprise features" in README.md). Set one to false to keep it off.
redpanda_enterprise_tiered_storage       = true
redpanda_enterprise_continuous_balancing = true
redpanda_enterprise_console_auth         = true

# Strimzi is deployed by the base infra/terraform/kafka.tf; this stack's kafka.tf removes it.
# Not needed for Redpanda (optional components, see infra/terraform/variables.tf)
enable_jupyterhub           = false
enable_ingress_nginx        = false
enable_event_logging        = false # ClickHouse operator + event-store + event-collector
enable_aws_for_fluentbit    = false
enable_cert_manager         = true # required: the Redpanda chart issues its TLS certificates with cert-manager
enable_keda                 = false
enable_data_teams           = false
enable_trino                = false
enable_spark_operator       = false
enable_spark_history_server = false
enable_flink_operator       = false
enable_argo_workflows       = false
enable_argo_events          = false
enable_yunikorn             = false

# Replaces the default core node group (same map key) to host the system add-ons
# (ArgoCD, Karpenter, kube-prometheus-stack, cert-manager, Redpanda Operator, Console).
# Core nodes never host brokers. subnet_ids is omitted on purpose: the node group
# falls back to the cluster's subnet_ids (the secondary 100.x private subnets).
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
      Blueprint  = "redpanda-on-eks"
      GithubRepo = "github.com/awslabs/data-on-eks"
    }
  }
}
