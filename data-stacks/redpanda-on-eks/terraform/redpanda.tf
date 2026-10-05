#---------------------------------------------------------------
# Redpanda on EKS
#
# Redpanda Operator (redpanda/operator chart) deployed by ArgoCD; the Redpanda cluster,
# Console and Users are operator custom resources applied by Terraform from
# manifests/redpanda/ (same pattern as Strimzi in infra/terraform/kafka.tf).
# Production settings follow
# https://docs.redpanda.com/streaming/current/deploy/redpanda/kubernetes/k-production-deployment/
#---------------------------------------------------------------

locals {
  redpanda_superusers_secret_name = "redpanda-superusers"
  redpanda_license_secret_name    = "redpanda-license"
  redpanda_admin_password         = coalesce(var.redpanda_admin_password, random_password.redpanda_admin.result)

  # External listeners: container port and the NodePort clients connect to (advertised).
  # NodePorts must be in the Kubernetes range 30000-32767 (redpanda-external-access.tf).
  redpanda_external_ports = {
    kafka           = { port = 9094, node_port = 31092 }
    admin           = { port = 9645, node_port = 31644 }
    schema-registry = { port = 8084, node_port = 30081 }
    http-proxy      = { port = 8083, node_port = 30082 }
  }

  redpanda_operator_values = templatefile("${path.module}/helm-values/redpanda-operator.yaml", {
    license_enabled     = local.redpanda_license_enabled
    license_secret_name = local.redpanda_license_secret_name
    connect_controller  = local.redpanda_connect_mode == "pipeline"
  })

  redpanda_cluster_template_vars = {
    CLUSTER_NAME           = local.redpanda_cluster_name
    NAMESPACE              = local.redpanda_namespace
    REDPANDA_VERSION       = var.redpanda_version
    LICENSE_ENABLED        = local.redpanda_license_enabled
    LICENSE_SECRET_NAME    = local.redpanda_license_secret_name
    REPLICAS               = var.redpanda_broker_replicas
    CPU_CORES              = var.redpanda_broker_cpu_cores
    MEMORY                 = var.redpanda_broker_memory
    STORAGE_SIZE           = var.redpanda_broker_storage_size
    SUPERUSERS_SECRET_NAME = local.redpanda_superusers_secret_name
    EXTERNAL_DOMAIN        = var.redpanda_external_domain
    EXTERNAL_PORTS         = local.redpanda_external_ports
    # Broker IAM role (Route 53 records, Tiered Storage) and the zone the brokers write to
    BROKER_ROLE_ARN = module.redpanda_broker_irsa.arn
    DNS_ZONE_ID     = aws_route53_zone.redpanda.zone_id
    AWS_REGION      = local.region
    # Enterprise features (only with a license, see redpanda-enterprise.tf)
    TIERED_STORAGE_ENABLED       = local.redpanda_tiered_storage_enabled
    TIERED_STORAGE_BUCKET        = local.redpanda_tiered_storage_enabled ? aws_s3_bucket.redpanda_tiered_storage[0].bucket : ""
    TIERED_STORAGE_REGION        = local.region
    CONTINUOUS_BALANCING_ENABLED = local.redpanda_continuous_balancing_enabled
  }
}

#---------------------------------------------------------------
# Namespace
#---------------------------------------------------------------
resource "kubectl_manifest" "redpanda_namespace" {
  yaml_body = <<-YAML
    apiVersion: v1
    kind: Namespace
    metadata:
      name: ${local.redpanda_namespace}
      labels:
        name: ${local.redpanda_namespace}
  YAML

  depends_on = [module.eks]
}

#---------------------------------------------------------------
# Superuser credentials (users.txt: <user>:<password>:<mechanism>). The password comes
# from TF_VAR_redpanda_admin_password or is generated; it never lands in git or in the
# ArgoCD Application.
#---------------------------------------------------------------
resource "random_password" "redpanda_admin" {
  length  = 32
  special = false
}

resource "kubernetes_secret" "redpanda_superusers" {
  metadata {
    name      = local.redpanda_superusers_secret_name
    namespace = local.redpanda_namespace
  }

  data = {
    "users.txt" = "${var.redpanda_admin_username}:${local.redpanda_admin_password}:SCRAM-SHA-512"
  }

  depends_on = [kubectl_manifest.redpanda_namespace]
}

resource "kubernetes_secret" "redpanda_license" {
  count = local.redpanda_license_enabled ? 1 : 0

  metadata {
    name      = local.redpanda_license_secret_name
    namespace = local.redpanda_namespace
  }

  data = {
    license = var.redpanda_enterprise_license
  }

  depends_on = [kubectl_manifest.redpanda_namespace]
}

#---------------------------------------------------------------
# Redpanda Operator (ArgoCD)
#---------------------------------------------------------------
resource "kubectl_manifest" "redpanda_operator" {
  yaml_body = templatefile("${path.module}/argocd-applications/redpanda-operator.yaml", {
    chart_version    = var.redpanda_operator_chart_version
    namespace        = local.redpanda_namespace
    user_values_yaml = indent(8, local.redpanda_operator_values)
  })

  depends_on = [
    helm_release.argocd,
    kubectl_manifest.cert_manager,
    kubectl_manifest.redpanda_namespace,
    kubernetes_secret.redpanda_license,
  ]
}

#---------------------------------------------------------------
# Redpanda cluster (Redpanda resource)
#---------------------------------------------------------------
resource "kubectl_manifest" "redpanda_cluster" {
  yaml_body = templatefile("${path.module}/manifests/redpanda/redpanda-cluster.yaml", local.redpanda_cluster_template_vars)

  # Wait for the operator finalizer on destroy, before the operator itself is removed
  wait = true

  depends_on = [
    kubectl_manifest.redpanda_operator,
    module.redpanda_broker_irsa,
    kubectl_manifest.local_static_provisioner,
    kubectl_manifest.karpenter_resources,
    kubectl_manifest.ec2nodeclass,
    kubernetes_secret.redpanda_superusers,
    kubernetes_secret.redpanda_license,
  ]
}

#---------------------------------------------------------------
# Redpanda Console (Console resource)
#---------------------------------------------------------------
resource "kubectl_manifest" "redpanda_console" {
  count = var.enable_redpanda_console ? 1 : 0

  yaml_body = templatefile("${path.module}/manifests/redpanda/console.yaml", {
    CLUSTER_NAME  = local.redpanda_cluster_name
    NAMESPACE     = local.redpanda_namespace
    SERVICE_TYPE  = var.redpanda_console_exposure == "none" ? "ClusterIP" : "LoadBalancer"
    NLB_SCHEME    = var.redpanda_console_exposure
    NLB_SUBNET_ID = var.redpanda_console_exposure == "internal" ? local.redpanda_broker_subnet_id : "" # internet-facing: public subnets (auto-discovered)
    ALLOWED_CIDRS = join(",", local.redpanda_console_allowed_cidrs)
    AUTH_ENABLED  = local.redpanda_console_auth_enabled
    ADMIN_USER    = var.redpanda_admin_username
    # Console login (Enterprise): JWT signing key for the session cookies
    JWT_SIGNING_KEY = local.redpanda_console_auth_enabled ? random_password.redpanda_console_jwt[0].result : ""
    LICENSE         = local.redpanda_console_auth_enabled ? var.redpanda_enterprise_license : ""
  })
  sensitive_fields = ["spec.secret"]

  # Wait for the operator finalizer on destroy, before the operator itself is removed
  wait = true

  depends_on = [kubectl_manifest.redpanda_cluster]
}

#---------------------------------------------------------------
# Outputs
#---------------------------------------------------------------
output "redpanda_bootstrap_servers" {
  description = "Kafka API bootstrap address for clients in this VPC or the peered VPC (TLS + SASL/SCRAM-SHA-512)"
  value       = "bootstrap.${var.redpanda_external_domain}:${local.redpanda_external_ports["kafka"].node_port}"
}

output "redpanda_broker_addresses" {
  description = "Advertised external address of each broker"
  value       = [for i in range(var.redpanda_broker_replicas) : "${local.redpanda_cluster_name}-${i}.${var.redpanda_external_domain}:${local.redpanda_external_ports["kafka"].node_port}"]
}

output "redpanda_admin_api" {
  description = "Admin API address for rpk on clients (TLS + basic auth)"
  value       = "bootstrap.${var.redpanda_external_domain}:${local.redpanda_external_ports["admin"].node_port}"
}

output "redpanda_client_routed_cidr" {
  description = "Range a client network must route to this VPC (broker subnet); the stack adds it to the peered VPC's route tables"
  value       = local.redpanda_broker_subnet_cidr
}

output "redpanda_admin_username" {
  description = "SASL/SCRAM-SHA-512 superuser"
  value       = var.redpanda_admin_username
}

output "redpanda_admin_password" {
  description = "Password of the SASL/SCRAM superuser"
  value       = local.redpanda_admin_password
  sensitive   = true
}
