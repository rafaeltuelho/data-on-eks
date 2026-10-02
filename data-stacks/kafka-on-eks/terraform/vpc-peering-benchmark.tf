#---------------------------------------------------------------
# Benchmark flavor: VPC peering to the benchmark client (worker) VPC
#
# The worker VPC may already be peered with the Redpanda BYOC VPC, which can use
# the same 10.0.0.0/16 as this VPC's primary CIDR. To avoid a route conflict on
# the worker side, only the benchmark AZ's secondary CIDR (where the brokers and
# their internal NLBs live) is routed from the worker VPC.
# Inputs: var.benchmark_peer_vpc_id, var.benchmark_zone (benchmark-variables.tf)
#---------------------------------------------------------------

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

# Worker VPC -> this VPC (benchmark AZ secondary CIDR only; removed again on destroy)
resource "aws_route" "benchmark_peer_to_kafka" {
  count                     = var.benchmark_peer_vpc_id == null ? 0 : length(data.aws_route_tables.benchmark_peer[0].ids)
  route_table_id            = data.aws_route_tables.benchmark_peer[0].ids[count.index]
  destination_cidr_block    = local.benchmark_secondary_cidr
  vpc_peering_connection_id = aws_vpc_peering_connection.benchmark_peer[0].id
}

output "benchmark_peering_connection_id" {
  description = "VPC peering connection to the benchmark worker VPC"
  value       = try(aws_vpc_peering_connection.benchmark_peer[0].id, null)
}
