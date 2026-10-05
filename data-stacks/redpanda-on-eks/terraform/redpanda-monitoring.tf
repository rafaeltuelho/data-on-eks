#---------------------------------------------------------------
# Redpanda monitoring: official Grafana dashboards
#
# Metrics: the Redpanda resource enables the chart's ServiceMonitor (monitoring.enabled,
# /public_metrics) and the operator chart its own; kube-prometheus-stack selects
# ServiceMonitors in all namespaces. Dashboards: ConfigMaps in monitoring-manifests/
# (from github.com/redpanda-data/observability), loaded by the Grafana sidecar
# (label grafana_dashboard=1).
# See https://docs.redpanda.com/streaming/current/manage/kubernetes/monitoring/k-monitor-redpanda/
#---------------------------------------------------------------
locals {
  # _local/ is two levels below the stack directory
  redpanda_monitoring_dir = "${path.module}/../../monitoring-manifests"
}

resource "kubectl_manifest" "redpanda_grafana_dashboards" {
  for_each = fileset(local.redpanda_monitoring_dir, "*.yaml")

  # file(), not templatefile(): the dashboards contain Grafana ${...} variables
  yaml_body = file("${local.redpanda_monitoring_dir}/${each.value}")

  depends_on = [
    kubectl_manifest.kube_prometheus_stack_namespace,
    kubectl_manifest.kube_prometheus_stack,
  ]
}
