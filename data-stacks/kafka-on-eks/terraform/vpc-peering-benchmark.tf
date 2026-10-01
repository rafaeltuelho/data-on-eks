#---------------------------------------------------------------
# Benchmark flavor: VPC peering to the benchmark worker VPC
#
# The worker VPC is already peered with the Redpanda BYOC VPC, which uses the
# same 10.0.0.0/16 as this VPC's primary CIDR. To avoid a route conflict on the
# worker side, only this VPC's us-east-2a secondary CIDR (where the brokers and
# their internal NLBs live) is routed from the worker VPC.
#---------------------------------------------------------------

variable "benchmark_peer_vpc_id" {
  description = "VPC ID of the benchmark worker VPC to peer with. Set to null to disable peering."
  type        = string
  default     = null
}

variable "benchmark_routed_cidr" {
  description = "CIDR of this VPC routed from the worker VPC (must contain the Kafka NLBs and broker pods)"
  type        = string
  default     = "100.64.0.0/16"
}

data "aws_vpc" "benchmark_peer" {
  count = var.benchmark_peer_vpc_id == null ? 0 : 1
  id    = var.benchmark_peer_vpc_id
}

data "aws_route_tables" "benchmark_peer" {
  count  = var.benchmark_peer_vpc_id == null ? 0 : 1
  vpc_id = var.benchmark_peer_vpc_id
}

resource "aws_vpc_peering_connection" "benchmark_peer" {
  count       = var.benchmark_peer_vpc_id == null ? 0 : 1
  vpc_id      = module.vpc.vpc_id
  peer_vpc_id = var.benchmark_peer_vpc_id
  auto_accept = true # same account and region

  tags = {
    Name = "${local.name}-benchmark-workers"
  }
}

# This VPC -> worker VPC
resource "aws_route" "kafka_to_benchmark_peer" {
  count                     = var.benchmark_peer_vpc_id == null ? 0 : length(module.vpc.private_route_table_ids)
  route_table_id            = module.vpc.private_route_table_ids[count.index]
  destination_cidr_block    = data.aws_vpc.benchmark_peer[0].cidr_block
  vpc_peering_connection_id = aws_vpc_peering_connection.benchmark_peer[0].id
}

# Worker VPC -> this VPC (secondary CIDR only; removed again on destroy)
resource "aws_route" "benchmark_peer_to_kafka" {
  count                     = var.benchmark_peer_vpc_id == null ? 0 : length(data.aws_route_tables.benchmark_peer[0].ids)
  route_table_id            = data.aws_route_tables.benchmark_peer[0].ids[count.index]
  destination_cidr_block    = var.benchmark_routed_cidr
  vpc_peering_connection_id = aws_vpc_peering_connection.benchmark_peer[0].id
}

output "benchmark_peering_connection_id" {
  description = "VPC peering connection to the benchmark worker VPC"
  value       = try(aws_vpc_peering_connection.benchmark_peer[0].id, null)
}
