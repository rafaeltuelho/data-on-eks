#---------------------------------------------------------------
# Benchmark flavor: SCRAM-SHA-512 Kafka user for the external listener
# Created only when TF_VAR_benchmark_kafka_admin_password is exported.
#---------------------------------------------------------------
locals {
  benchmark_kafka_admin_secret_name = "${var.benchmark_kafka_admin_username}-password"
  benchmark_kafka_admin_enabled     = var.benchmark_kafka_admin_password != null
}

resource "kubectl_manifest" "benchmark_kafka_admin_password" {
  count = local.benchmark_kafka_admin_enabled ? 1 : 0

  sensitive_fields = ["data"]
  yaml_body = yamlencode({
    apiVersion = "v1"
    kind       = "Secret"
    metadata = {
      name      = local.benchmark_kafka_admin_secret_name
      namespace = "kafka"
    }
    type = "Opaque"
    data = {
      password = base64encode(var.benchmark_kafka_admin_password)
    }
  })

  depends_on = [kubectl_manifest.kafka_namespace]
}

resource "kubectl_manifest" "benchmark_kafka_admin_user" {
  count = local.benchmark_kafka_admin_enabled ? 1 : 0

  yaml_body = templatefile("${path.module}/manifests/benchmark/kafka-user.yaml", {
    USERNAME             = var.benchmark_kafka_admin_username
    PASSWORD_SECRET_NAME = local.benchmark_kafka_admin_secret_name
  })

  depends_on = [
    kubectl_manifest.benchmark_kafka_admin_password,
    kubectl_manifest.kafka_manifests,
  ]
}
