locals {
  clickhouse_operator_values = templatefile("${path.module}/helm-values/clickhouse-operator.yaml", {})
}

resource "kubectl_manifest" "clickhouse_operator" {
  count = var.enable_event_logging ? 1 : 0

  yaml_body = templatefile("${path.module}/argocd-applications/clickhouse-operator.yaml", {
    user_values_yaml = indent(8, local.clickhouse_operator_values)
  })

  depends_on = [
    helm_release.argocd,
  ]
}

# Resources became optional (count); keep existing state addresses
moved {
  from = kubectl_manifest.clickhouse_operator
  to   = kubectl_manifest.clickhouse_operator[0]
}
