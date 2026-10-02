#---------------------------------------------------------------
# Benchmark flavor: Strimzi metrics scraping and Grafana dashboards
# Applies data-stacks/kafka-on-eks/monitoring-manifests/ (PodMonitors + dashboard
# ConfigMaps). Prometheus selects PodMonitors in all namespaces, and the Grafana
# sidecar loads ConfigMaps labeled grafana_dashboard=1 from all namespaces.
#---------------------------------------------------------------
locals {
  # _local/ is two levels below the stack directory
  benchmark_monitoring_dir = "${path.module}/../../monitoring-manifests"
}

resource "kubectl_manifest" "benchmark_kafka_monitoring" {
  for_each = fileset(local.benchmark_monitoring_dir, "*.yaml")

  # file(), not templatefile(): the dashboards contain Grafana ${...} variables
  yaml_body = file("${local.benchmark_monitoring_dir}/${each.value}")

  depends_on = [
    kubectl_manifest.kube_prometheus_stack,
    kubectl_manifest.strimzi_kafka_operator,
    kubectl_manifest.kafka_namespace,
  ]
}
