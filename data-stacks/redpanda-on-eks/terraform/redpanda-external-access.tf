#---------------------------------------------------------------
# External access to the brokers: NodePort, no load balancer (like Redpanda BYOC over
# VPC peering, and the Redpanda chart's recommendation when latency matters)
#
#   client (this VPC, or a client network routed to the broker subnet)
#     -> redpanda-<n>.<domain>:31092   Route 53 private zone, A record = broker node IP
#     -> NodePort on the broker node   Service redpanda-external, externalTrafficPolicy: Local
#     -> broker pod redpanda-<n>       external listeners, TLS + SASL/SCRAM
#
# Node IPs are not known in advance (Karpenter), so each broker publishes its own records
# when it starts: an init container (route53-dns, see manifests/redpanda/redpanda-cluster.yaml)
# UPSERTs redpanda-<n>.<domain> and its entry in the multivalue bootstrap.<domain>, using
# the broker IAM role below. A broker only changes node when its node is replaced, and then
# it restarts and updates the records. The external TLS certificate covers <domain> and
# *.<domain>. No per-GB load balancer charges.
#---------------------------------------------------------------

#---------------------------------------------------------------
# Route 53 private hosted zone, associated with this VPC only. Client VPCs are associated
# from outside this project (aws_route53_zone_association in the client's peering module),
# so Terraform here ignores the zone's VPC associations after creation.
#---------------------------------------------------------------
resource "aws_route53_zone" "redpanda" {
  name    = var.redpanda_external_domain
  comment = "Redpanda external listeners (${local.name}); records written by the brokers"

  vpc {
    vpc_id = module.vpc.vpc_id
  }

  # The records are created by the brokers, not Terraform; delete them with the zone
  force_destroy = true

  lifecycle {
    # Keep the client VPC associations made by other projects
    ignore_changes = [vpc]
  }
}

#---------------------------------------------------------------
# Broker IAM role (IRSA on the chart's ServiceAccount "redpanda"): Route 53 records for
# the external listeners, plus the Tiered Storage bucket when enabled (redpanda-enterprise.tf)
#---------------------------------------------------------------
resource "aws_iam_policy" "redpanda_broker_dns" {
  name        = "${local.name}-redpanda-broker-dns"
  description = "Redpanda brokers publish their external DNS records"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["route53:ChangeResourceRecordSets", "route53:ListResourceRecordSets"]
        Resource = [aws_route53_zone.redpanda.arn]
      },
    ]
  })

  tags = {
    deployment_id = var.deployment_id
  }
}

module "redpanda_broker_irsa" {
  source  = "terraform-aws-modules/iam/aws//modules/iam-role-for-service-accounts"
  version = "~> 6.0"
  name    = "${module.eks.cluster_name}-redpanda-broker"

  policies = merge(
    { route53 = aws_iam_policy.redpanda_broker_dns.arn },
    local.redpanda_tiered_storage_enabled ? { s3_tiered_storage = aws_iam_policy.redpanda_tiered_storage_s3[0].arn } : {},
  )

  oidc_providers = {
    main = {
      provider_arn = module.eks.oidc_provider_arn
      # The chart's broker ServiceAccount is named after the Redpanda resource
      namespace_service_accounts = ["${local.redpanda_namespace}:${local.redpanda_cluster_name}"]
    }
  }
}

#---------------------------------------------------------------
# NodePorts: open the external listener ports on the node security group (the chart's
# NodePort Service; externalTrafficPolicy: Local keeps traffic on the broker's own node).
#   - this VPC's own CIDRs: one rule per port per CIDR
#   - client networks: one rule per port that references the redpanda-clients prefix list
#---------------------------------------------------------------
resource "aws_vpc_security_group_ingress_rule" "redpanda_external_nodeports" {
  for_each = {
    for pair in setproduct(keys(local.redpanda_external_ports), local.redpanda_vpc_cidrs) :
    "${pair[0]}-${pair[1]}" => { name = pair[0], cidr = pair[1] }
  }

  security_group_id = module.eks.node_security_group_id
  description       = "Redpanda external ${each.value.name} (NodePort)"
  ip_protocol       = "tcp"
  from_port         = local.redpanda_external_ports[each.value.name].node_port
  to_port           = local.redpanda_external_ports[each.value.name].node_port
  cidr_ipv4         = each.value.cidr
}

# Client CIDRs allowed to reach the NodePorts. The list is created empty: client projects
# (e.g. the peering module) add their CIDRs as aws_ec2_managed_prefix_list_entry
# resources, so Terraform here ignores the entries.
resource "aws_ec2_managed_prefix_list" "redpanda_clients" {
  name           = "${local.name}-redpanda-clients"
  address_family = "IPv4"
  max_entries    = var.redpanda_clients_prefix_list_max_entries

  lifecycle {
    ignore_changes = [entry]

    # Every rule that references the list counts as max_entries rules against the
    # security group's inbound rules quota
    precondition {
      condition     = local.redpanda_node_sg_ingress_rules <= data.aws_servicequotas_service_quota.security_group_rules.value
      error_message = "The node security group would need ${local.redpanda_node_sg_ingress_rules} inbound rules, above the quota of ${data.aws_servicequotas_service_quota.security_group_rules.value}. Lower redpanda_clients_prefix_list_max_entries or raise the VPC quota L-0EA8095F."
    }
  }

  tags = {
    Name          = "${local.name}-redpanda-clients"
    deployment_id = var.deployment_id
  }
}

resource "aws_vpc_security_group_ingress_rule" "redpanda_external_nodeports_clients" {
  for_each = local.redpanda_external_ports

  security_group_id = module.eks.node_security_group_id
  description       = "Redpanda external ${each.key} (NodePort) from the client prefix list"
  ip_protocol       = "tcp"
  from_port         = each.value.node_port
  to_port           = each.value.node_port
  prefix_list_id    = aws_ec2_managed_prefix_list.redpanda_clients.id
}

# "Inbound or outbound rules per security group" (default 60)
data "aws_servicequotas_service_quota" "security_group_rules" {
  service_code = "vpc"
  quota_code   = "L-0EA8095F"
}

locals {
  # Inbound rules on the node security group: the EKS module's defaults and recommended
  # rules (10), the base eks.tf additions (2), this VPC's NodePort rules, and the
  # prefix list rules (max_entries each)
  redpanda_node_sg_ingress_rules = (
    12
    + length(local.redpanda_external_ports) * length(local.redpanda_vpc_cidrs)
    + length(local.redpanda_external_ports) * var.redpanda_clients_prefix_list_max_entries
  )
}

#---------------------------------------------------------------
# What a client project (e.g. the peering module) needs: peer with vpc_id, route
# routed_cidr to it and the client CIDR back through private_route_table_ids, add the
# client CIDR to the prefix list and associate the client VPC with the private zone
#---------------------------------------------------------------
output "redpanda_vpc_id" {
  description = "VPC of the Redpanda cluster (peer the client VPC with it)"
  value       = module.vpc.vpc_id
}

output "redpanda_clients_prefix_list_id" {
  description = "Managed prefix list allowed to reach the broker NodePorts (add client CIDRs as aws_ec2_managed_prefix_list_entry)"
  value       = aws_ec2_managed_prefix_list.redpanda_clients.id
}

output "redpanda_private_zone_id" {
  description = "Route 53 private zone of the broker names (associate client VPCs with aws_route53_zone_association)"
  value       = aws_route53_zone.redpanda.zone_id
}

output "redpanda_external_node_ports" {
  description = "NodePorts of the external listeners on the broker nodes"
  value       = { for name, p in local.redpanda_external_ports : name => p.node_port }
}

output "redpanda_client_connectivity" {
  description = "Everything a client project needs to connect a client network"
  value = {
    vpc_id                  = module.vpc.vpc_id
    vpc_cidrs               = concat([var.vpc_cidr], var.secondary_cidrs)
    routed_cidr             = local.redpanda_broker_subnet_cidr
    private_route_table_ids = module.vpc.private_route_table_ids
    prefix_list_id          = aws_ec2_managed_prefix_list.redpanda_clients.id
    dns_zone_id             = aws_route53_zone.redpanda.zone_id
    dns_zone_name           = var.redpanda_external_domain
    node_ports              = { for name, p in local.redpanda_external_ports : name => p.node_port }
  }
}
