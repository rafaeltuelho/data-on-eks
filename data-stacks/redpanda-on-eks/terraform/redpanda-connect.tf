#---------------------------------------------------------------
# Redpanda Connect (optional, var.enable_redpanda_connect)
#
# A sample pipeline that writes generated events to topic connect-demo, authenticated as
# an operator-managed User with ACLs scoped to that topic. local.redpanda_connect_mode:
#   helm      official redpanda/connect Helm chart deployed by ArgoCD
#             (helm-values/redpanda-connect.yaml); default without a license
#   pipeline  operator Pipeline resource (manifests/redpanda/pipeline-connect.yaml);
#             Enterprise, default with a license (beta in operator 26.2)
#---------------------------------------------------------------
locals {
  redpanda_connect_username             = "connect"
  redpanda_connect_password_secret_name = "redpanda-connect-password"
  redpanda_connect_topic                = "connect-demo"
}

resource "random_password" "redpanda_connect" {
  count = var.enable_redpanda_connect ? 1 : 0

  length  = 32
  special = false
}

resource "kubernetes_secret" "redpanda_connect_password" {
  count = var.enable_redpanda_connect ? 1 : 0

  metadata {
    name      = local.redpanda_connect_password_secret_name
    namespace = local.redpanda_namespace
  }

  data = {
    password = random_password.redpanda_connect[0].result
  }

  depends_on = [kubectl_manifest.redpanda_namespace]
}

resource "kubectl_manifest" "redpanda_connect_user" {
  count = var.enable_redpanda_connect ? 1 : 0

  yaml_body = templatefile("${path.module}/manifests/redpanda/user-connect.yaml", {
    USERNAME             = local.redpanda_connect_username
    NAMESPACE            = local.redpanda_namespace
    CLUSTER_NAME         = local.redpanda_cluster_name
    PASSWORD_SECRET_NAME = local.redpanda_connect_password_secret_name
    TOPIC_PREFIX         = local.redpanda_connect_topic
  })

  # Wait for the operator finalizer on destroy, before the operator itself is removed
  wait = true

  depends_on = [
    kubectl_manifest.redpanda_cluster,
    kubernetes_secret.redpanda_connect_password,
  ]
}

resource "kubectl_manifest" "redpanda_connect_topic" {
  count = var.enable_redpanda_connect ? 1 : 0

  yaml_body = templatefile("${path.module}/manifests/redpanda/topic-connect.yaml", {
    TOPIC        = local.redpanda_connect_topic
    NAMESPACE    = local.redpanda_namespace
    CLUSTER_NAME = local.redpanda_cluster_name
  })

  # Wait for the operator finalizer on destroy, before the operator itself is removed
  wait = true

  depends_on = [kubectl_manifest.redpanda_cluster]
}

resource "kubectl_manifest" "redpanda_connect" {
  count = local.redpanda_connect_mode == "helm" ? 1 : 0

  yaml_body = templatefile("${path.module}/argocd-applications/redpanda-connect.yaml", {
    chart_version = var.redpanda_connect_chart_version
    namespace     = local.redpanda_namespace
    user_values_yaml = indent(8, templatefile("${path.module}/helm-values/redpanda-connect.yaml", {
      password_secret_name = local.redpanda_connect_password_secret_name
      ca_secret_name       = "${local.redpanda_cluster_name}-default-root-certificate"
      seed_broker          = "${local.redpanda_cluster_name}.${local.redpanda_namespace}.svc.cluster.local:9093"
      topic                = local.redpanda_connect_topic
      username             = local.redpanda_connect_username
    }))
  })

  depends_on = [
    helm_release.argocd,
    kubectl_manifest.redpanda_connect_user,
    kubectl_manifest.redpanda_connect_topic,
  ]
}

resource "kubectl_manifest" "redpanda_connect_pipeline" {
  count = local.redpanda_connect_mode == "pipeline" ? 1 : 0

  yaml_body = templatefile("${path.module}/manifests/redpanda/pipeline-connect.yaml", {
    NAME         = "connect-demo"
    NAMESPACE    = local.redpanda_namespace
    CLUSTER_NAME = local.redpanda_cluster_name
    USERNAME     = local.redpanda_connect_username
    TOPIC        = local.redpanda_connect_topic
  })

  # Wait for the operator finalizer on destroy, before the operator itself is removed
  wait = true

  lifecycle {
    precondition {
      condition     = local.redpanda_license_enabled
      error_message = "redpanda_connect_deployment = \"pipeline\" needs TF_VAR_redpanda_enterprise_license (with the Redpanda Connect product)."
    }
  }

  depends_on = [
    kubectl_manifest.redpanda_operator,
    kubectl_manifest.redpanda_connect_user,
    kubectl_manifest.redpanda_connect_topic,
  ]
}
