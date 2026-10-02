#---------------------------------------------------------------
# Benchmark flavor (Redpanda BYOC Tier 1) — inputs and derived values
# Set environment-specific values in data-stack.tfvars. See BENCHMARK_CUSTOMIZATION.md.
#---------------------------------------------------------------

variable "benchmark_zone" {
  description = "Availability Zone for Kafka brokers, controllers and NLBs. Use the same AZ as the Redpanda cluster and benchmark clients. Must be one of the first 3 AZs of the region."
  type        = string
  default     = "us-east-2a"
}

variable "benchmark_broker_instance_type" {
  description = "EC2 instance type for Kafka brokers. Must have local NVMe instance storage (e.g. m7gd.large, the Redpanda BYOC Tier 1 broker type)."
  type        = string
  default     = "m7gd.large"
}

variable "benchmark_controller_instance_type" {
  description = "EC2 instance type for the dedicated KRaft controllers."
  type        = string
  default     = "m7g.large"
}

variable "benchmark_peer_vpc_id" {
  description = "VPC ID of the benchmark client (worker) VPC to peer with. null disables peering and restricts the external listener to this VPC's CIDR."
  type        = string
  default     = null
}

variable "benchmark_kafka_admin_username" {
  description = "SCRAM-SHA-512 user created for the external listener."
  type        = string
  default     = "admin"
}

variable "benchmark_kafka_admin_password" {
  description = "Password for the benchmark Kafka user. Do not put it in tfvars: export TF_VAR_benchmark_kafka_admin_password. null skips creating the user."
  type        = string
  default     = null
  sensitive   = true
}

locals {
  # Secondary subnets are created one per AZ, in local.azs order (see vpc.tf)
  benchmark_zone_index     = index(local.azs, var.benchmark_zone)
  benchmark_secondary_cidr = var.secondary_cidrs[local.benchmark_zone_index]

  # NLBs live in the benchmark AZ's secondary subnet: the only range routed from the peer VPC
  benchmark_nlb_subnet_name = "${local.name}-private-secondary1-${var.benchmark_zone}"

  # Clients allowed to reach the external listener NLBs
  benchmark_client_cidrs = var.benchmark_peer_vpc_id == null ? [var.vpc_cidr] : [data.aws_vpc.benchmark_peer[0].cidr_block]

  # Variables available to the benchmark-templated manifests
  benchmark_template_vars = {
    BENCHMARK_ZONE                     = var.benchmark_zone
    BENCHMARK_BROKER_INSTANCE_TYPE     = var.benchmark_broker_instance_type
    BENCHMARK_CONTROLLER_INSTANCE_TYPE = var.benchmark_controller_instance_type
    BENCHMARK_NLB_SUBNET_NAME          = local.benchmark_nlb_subnet_name
    BENCHMARK_CLIENT_CIDRS_JSON        = jsonencode(local.benchmark_client_cidrs)
  }
}
