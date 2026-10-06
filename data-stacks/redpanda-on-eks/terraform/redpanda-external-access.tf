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
# Route 53 private hosted zone, associated with this VPC and var.redpanda_client_vpc_ids
#---------------------------------------------------------------
resource "aws_route53_zone" "redpanda" {
  name    = var.redpanda_external_domain
  comment = "Redpanda external listeners (${local.name}); records written by the brokers"

  vpc {
    vpc_id = module.vpc.vpc_id
  }

  dynamic "vpc" {
    for_each = toset(var.redpanda_client_vpc_ids)
    content {
      vpc_id = vpc.value
    }
  }

  # The records are created by the brokers, not Terraform; delete them with the zone
  force_destroy = true
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
# NodePorts: open the external listener ports on the node security group to the clients
# (the chart's NodePort Service; externalTrafficPolicy: Local keeps traffic on the
# broker's own node)
#---------------------------------------------------------------
resource "aws_vpc_security_group_ingress_rule" "redpanda_external_nodeports" {
  for_each = {
    for pair in setproduct(keys(local.redpanda_external_ports), local.redpanda_client_cidrs) :
    "${pair[0]}-${pair[1]}" => { name = pair[0], cidr = pair[1] }
  }

  security_group_id = module.eks.node_security_group_id
  description       = "Redpanda external ${each.value.name} (NodePort)"
  ip_protocol       = "tcp"
  from_port         = local.redpanda_external_ports[each.value.name].node_port
  to_port           = local.redpanda_external_ports[each.value.name].node_port
  cidr_ipv4         = each.value.cidr
}

#---------------------------------------------------------------
# What a client network needs to connect (peering / Transit Gateway set up by the client)
#---------------------------------------------------------------
output "redpanda_client_connectivity" {
  description = "Inputs for the client side: peer with vpc_id, route routed_cidr to it, and route the client CIDR back through private_route_table_ids"
  value = {
    vpc_id                  = module.vpc.vpc_id
    vpc_cidrs               = concat([var.vpc_cidr], var.secondary_cidrs)
    routed_cidr             = local.redpanda_broker_subnet_cidr
    private_route_table_ids = module.vpc.private_route_table_ids
    dns_zone_id             = aws_route53_zone.redpanda.zone_id
    dns_zone_name           = var.redpanda_external_domain
    allowed_client_cidrs    = local.redpanda_client_cidrs
  }
}
