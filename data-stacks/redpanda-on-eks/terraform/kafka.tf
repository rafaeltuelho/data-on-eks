#---------------------------------------------------------------
# Overrides infra/terraform/kafka.tf: this stack runs Redpanda, so the Strimzi operator
# and the Kafka cluster are not deployed. The resource is kept with count = 0 because
# infra/terraform/datahub.tf lists it in depends_on.
#---------------------------------------------------------------
resource "kubectl_manifest" "strimzi_kafka_operator" {
  count = 0

  yaml_body = ""
}
