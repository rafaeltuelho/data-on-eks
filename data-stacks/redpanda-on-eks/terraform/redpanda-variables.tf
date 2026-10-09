#---------------------------------------------------------------
# Redpanda on EKS — inputs and derived values
# Set environment-specific values in data-stack.tfvars. See ../README.md.
#---------------------------------------------------------------

variable "redpanda_operator_chart_version" {
  description = "Version of the redpanda/operator Helm chart (https://charts.redpanda.com)."
  type        = string
  default     = "26.2.4"
}

variable "redpanda_version" {
  description = "Redpanda broker image tag. Pin it, as the production docs recommend."
  type        = string
  default     = "v26.2.3"
}

variable "redpanda_zone" {
  description = "Availability Zone for the brokers. Must be one of the first 3 AZs of the region. Put clients in the same AZ to avoid cross-AZ transfer charges."
  type        = string
  default     = "us-east-2a"
}

variable "redpanda_broker_replicas" {
  description = "Number of Redpanda brokers. Use an odd number (3, 5, 7...). Raise it and re-apply to expand the cluster; scaling down needs a manual decommission first."
  type        = number
  default     = 3

  validation {
    condition     = var.redpanda_broker_replicas >= 3 && var.redpanda_broker_replicas <= 15 && var.redpanda_broker_replicas % 2 == 1
    error_message = "redpanda_broker_replicas must be an odd number between 3 and 15."
  }
}

variable "redpanda_broker_instance_type" {
  description = "EC2 instance type for the brokers (one broker per node). Must have local NVMe instance storage."
  type        = string
  default     = "m7gd.2xlarge"
}

variable "redpanda_broker_cpu_cores" {
  description = "Cores per broker (resources.cpu.cores, Redpanda --smp). Must fit the node's allocatable CPU."
  type        = number
  default     = 6
}

variable "redpanda_broker_memory" {
  description = "Container memory per broker (resources.memory.container.max). At least 2.5Gi per core."
  type        = string
  default     = "24Gi"
}

variable "redpanda_broker_storage_size" {
  description = "Size of each broker's local NVMe PersistentVolume claim. Must be below the instance store size."
  type        = string
  default     = "400Gi"
}

variable "redpanda_external_domain" {
  description = "Route 53 private hosted zone advertised by the external listeners: brokers are redpanda-<n>.<domain>, plus bootstrap.<domain>. Each broker keeps its own records pointing at its node IP."
  type        = string
  default     = "redpanda.internal"
}

# Client networks. Like Redpanda BYOC, the stack does not manage the client connectivity:
# a client project (e.g. a separate peering module) peers with this VPC, adds the routes,
# adds the client CIDRs to the redpanda-clients prefix list and associates the client VPC
# with the private zone. See "Connect a client VPC" in README.md.
variable "redpanda_clients_prefix_list_max_entries" {
  description = "Size of the redpanda-clients prefix list (client CIDRs). Each of the 4 NodePort rules that reference it counts as this many rules against the node security group's quota (60 inbound by default). It can be raised later in place."
  type        = number
  default     = 5

  validation {
    condition     = var.redpanda_clients_prefix_list_max_entries >= 1
    error_message = "redpanda_clients_prefix_list_max_entries must be at least 1."
  }
}

variable "redpanda_admin_username" {
  description = "SASL/SCRAM-SHA-512 superuser created for clients."
  type        = string
  default     = "admin"
}

variable "redpanda_admin_password" {
  description = "Password of the superuser. Do not put it in tfvars: export TF_VAR_redpanda_admin_password. null generates one."
  type        = string
  default     = null
  sensitive   = true
}

variable "redpanda_enterprise_license" {
  description = "Optional Redpanda Enterprise license. Export TF_VAR_redpanda_enterprise_license; null runs the Community features only. With a license, the redpanda_enterprise_* features below are enabled."
  type        = string
  default     = null
  sensitive   = true
}

variable "redpanda_enterprise_builtin_trial" {
  description = "Use the 30-day Enterprise trial that every new Redpanda cluster (24.3+) gets, without a license key: enables the cluster-side features (Tiered Storage, Continuous Data Balancing). After 30 days they enter a restricted state and upgrades are blocked until you set a license or turn this off. Console login and Connect Pipeline still need a key."
  type        = bool
  default     = true
}

# Enterprise features: applied when redpanda_enterprise_license is set (or, for the
# cluster-side ones, during the built-in trial). Set one to false to keep it off.
variable "redpanda_enterprise_tiered_storage" {
  description = "With a license: Tiered Storage to a dedicated S3 bucket (IRSA, no static keys)."
  type        = bool
  default     = true
}

variable "redpanda_enterprise_continuous_balancing" {
  description = "With a license: Continuous Data Balancing (partition_autobalancing_mode = continuous) instead of the Community node_add mode."
  type        = bool
  default     = true
}

variable "redpanda_enterprise_console_auth" {
  description = "With a license: Redpanda Console login (basic auth with Redpanda SASL users) and RBAC (admin role for redpanda_admin_username)."
  type        = bool
  default     = true
}

variable "enable_redpanda_console" {
  description = "Deploy Redpanda Console (operator Console resource)."
  type        = bool
  default     = true
}

variable "redpanda_console_exposure" {
  description = "How Console is exposed besides kubectl port-forward: none, internal (NLB in the broker subnet, reachable from the client networks) or internet-facing (NLB in the public subnets)."
  type        = string
  default     = "none"

  validation {
    condition     = contains(["none", "internal", "internet-facing"], var.redpanda_console_exposure)
    error_message = "redpanda_console_exposure must be none, internal or internet-facing."
  }
}

variable "redpanda_console_allowed_cidrs" {
  description = "CIDRs allowed to reach the Console NLB. Defaults to this VPC's CIDRs. Console has no login without an Enterprise license."
  type        = list(string)
  default     = []
}

variable "enable_redpanda_connect" {
  description = "Deploy Redpanda Connect (redpanda/connect Helm chart) with a sample pipeline."
  type        = bool
  default     = false
}

variable "redpanda_connect_deployment" {
  description = "How Redpanda Connect is deployed: auto (operator Pipeline resource with a license, Helm chart without), helm, or pipeline (needs a license that includes Redpanda Connect; beta in operator 26.2)."
  type        = string
  default     = "auto"

  validation {
    condition     = contains(["auto", "helm", "pipeline"], var.redpanda_connect_deployment)
    error_message = "redpanda_connect_deployment must be auto, helm or pipeline."
  }
}

variable "redpanda_connect_chart_version" {
  description = "Version of the redpanda/connect Helm chart."
  type        = string
  default     = "3.2.33"
}

locals {
  redpanda_namespace    = "redpanda"
  redpanda_cluster_name = "redpanda" # Redpanda resource name; brokers are redpanda-<n>

  # Brokers run in the secondary subnet of redpanda_zone (Karpenter selects the
  # private-secondary subnets; the NodePool pins the zone). This is the only range a client
  # network needs to route here. Subnets are created in local.azs order (vpc.tf).
  redpanda_zone_index         = index(local.azs, var.redpanda_zone)
  redpanda_broker_subnet_cidr = var.secondary_cidrs[local.redpanda_zone_index]
  redpanda_broker_subnet_id   = module.vpc.private_subnets[length(local.azs) + local.redpanda_zone_index]

  # This VPC's CIDRs, always allowed to reach the external listeners (NodePorts on the
  # broker nodes). Client networks are allowed through the redpanda-clients prefix list.
  redpanda_vpc_cidrs = distinct(concat([var.vpc_cidr], var.secondary_cidrs))

  # Enterprise license and the features it unlocks. nonsensitive(): only the presence of
  # the license drives count/templates, never its value.
  redpanda_license_enabled = nonsensitive(var.redpanda_enterprise_license != null)
  # Cluster-side features also run on the built-in 30-day trial (no key). Console login and
  # the operator Connect controller read a license key, so they stay key-only.
  redpanda_cluster_enterprise_enabled   = local.redpanda_license_enabled || var.redpanda_enterprise_builtin_trial
  redpanda_tiered_storage_enabled       = local.redpanda_cluster_enterprise_enabled && var.redpanda_enterprise_tiered_storage
  redpanda_continuous_balancing_enabled = local.redpanda_cluster_enterprise_enabled && var.redpanda_enterprise_continuous_balancing
  redpanda_console_auth_enabled         = local.redpanda_license_enabled && var.redpanda_enterprise_console_auth && var.enable_redpanda_console
  redpanda_connect_mode = (
    !var.enable_redpanda_connect ? "none" :
    var.redpanda_connect_deployment == "auto" ? (local.redpanda_license_enabled ? "pipeline" : "helm") :
    var.redpanda_connect_deployment
  )

  redpanda_console_allowed_cidrs = length(var.redpanda_console_allowed_cidrs) > 0 ? var.redpanda_console_allowed_cidrs : local.redpanda_vpc_cidrs

  # Variables available to the Karpenter templates (karpenter.tf)
  redpanda_karpenter_template_vars = {
    REDPANDA_ZONE                 = var.redpanda_zone
    REDPANDA_BROKER_INSTANCE_TYPE = var.redpanda_broker_instance_type
    # One node per broker plus one replacement node
    REDPANDA_NODEPOOL_CPU_LIMIT = data.aws_ec2_instance_type.redpanda_broker.default_vcpus * (var.redpanda_broker_replicas + 1)
  }
}

data "aws_ec2_instance_type" "redpanda_broker" {
  instance_type = var.redpanda_broker_instance_type

  lifecycle {
    postcondition {
      condition     = self.instance_storage_supported
      error_message = "redpanda_broker_instance_type must have local NVMe instance storage (e.g. m7gd, i4i, is4gen)."
    }
  }
}
