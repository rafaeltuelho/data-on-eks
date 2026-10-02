# kafka-cluster

In this benchmark fork the Kafka cluster is managed by Terraform, so `./deploy.sh` creates it.
You no longer `kubectl apply` it by hand. The manifests live in `../terraform/manifests/`:

| Resource | File |
|---|---|
| `Kafka` (listeners, NLBs, authorization) | `terraform/manifests/kafka/kafka-cluster.yaml` |
| Broker / controller `KafkaNodePool`s | `terraform/manifests/kafka/node-pool-*.yaml` |
| `KafkaRebalance` | `terraform/manifests/kafka/rebalance.yaml` |
| `KafkaUser` (SCRAM) | `terraform/manifests/benchmark/kafka-user.yaml` |

See [BENCHMARK_CUSTOMIZATION.md](../../../BENCHMARK_CUSTOMIZATION.md).
