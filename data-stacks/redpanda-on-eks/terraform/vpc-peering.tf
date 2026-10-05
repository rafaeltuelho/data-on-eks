#---------------------------------------------------------------
# Optional VPC peering to a client VPC (var.redpanda_peer_vpc_id, same account and region)
#
# Only the broker subnet (the secondary CIDR of var.redpanda_zone, where the broker nodes
# and their NodePorts live) is routed from the client VPC. Choose vpc_cidr and
# secondary_cidrs (data-stack.tfvars) that the client VPC does not already route
# elsewhere (e.g. Redpanda BYOC or kafka-on-eks networks). The Route 53 private zone is
# associated with the client VPC in redpanda-external-access.tf.
#---------------------------------------------------------------

data "aws_vpc" "redpanda_peer" {
  count = var.redpanda_peer_vpc_id == null ? 0 : 1
  id    = var.redpanda_peer_vpc_id
}

data "aws_route_tables" "redpanda_peer" {
  count  = var.redpanda_peer_vpc_id == null ? 0 : 1
  vpc_id = var.redpanda_peer_vpc_id
}

resource "aws_vpc_peering_connection" "redpanda_peer" {
  count       = var.redpanda_peer_vpc_id == null ? 0 : 1
  vpc_id      = module.vpc.vpc_id
  peer_vpc_id = var.redpanda_peer_vpc_id
  auto_accept = true # same account and region

  tags = {
    Name = "${local.name}-redpanda-clients"
  }
}

# This VPC -> client VPC (return traffic from the broker nodes)
resource "aws_route" "redpanda_to_peer" {
  count                     = var.redpanda_peer_vpc_id == null ? 0 : length(module.vpc.private_route_table_ids)
  route_table_id            = module.vpc.private_route_table_ids[count.index]
  destination_cidr_block    = data.aws_vpc.redpanda_peer[0].cidr_block
  vpc_peering_connection_id = aws_vpc_peering_connection.redpanda_peer[0].id
}

# Client VPC -> broker subnet only (removed again on destroy)
resource "aws_route" "peer_to_redpanda" {
  count                     = var.redpanda_peer_vpc_id == null ? 0 : length(data.aws_route_tables.redpanda_peer[0].ids)
  route_table_id            = data.aws_route_tables.redpanda_peer[0].ids[count.index]
  destination_cidr_block    = local.redpanda_broker_subnet_cidr
  vpc_peering_connection_id = aws_vpc_peering_connection.redpanda_peer[0].id
}

output "redpanda_peering_connection_id" {
  description = "VPC peering connection to the client VPC"
  value       = try(aws_vpc_peering_connection.redpanda_peer[0].id, null)
}
