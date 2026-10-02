locals {
  spark_operator_values = yamldecode(templatefile("${path.module}/helm-values/spark-operator.yaml", {
    enable_ipv6 = var.enable_ipv6
  }))
}

#---------------------------------------------------------------
# Spark Operator Application
#---------------------------------------------------------------
resource "kubectl_manifest" "spark_operator" {
  count = var.enable_spark_operator ? 1 : 0

  yaml_body = templatefile("${path.module}/argocd-applications/spark-operator.yaml", {
    user_values_yaml = indent(8, yamlencode(local.spark_operator_values))
  })

  depends_on = [
    helm_release.argocd,
    module.spark_history_server_irsa,
  ]
}

# Resources became optional (count); keep existing state addresses
moved {
  from = kubectl_manifest.spark_operator
  to   = kubectl_manifest.spark_operator[0]
}
