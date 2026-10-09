# Redpanda on EKS: what this branch adds

This branch of the fork adds a new data stack, **`redpanda-on-eks`**
(`data-stacks/redpanda-on-eks/`). It runs self-managed Redpanda on Amazon EKS with the
official Redpanda Operator, deployed through ArgoCD, and follows the Redpanda guide
[Deploy Redpanda for Production in Kubernetes](https://docs.redpanda.com/streaming/current/deploy/redpanda/kubernetes/k-production-deployment/).

This file only lists what the branch adds or changes compared with the original repo. Read the
stack's own **[README](data-stacks/redpanda-on-eks/README.md)** to deploy and use the stack. It
covers the architecture diagram, client connectivity, enterprise features, the cost estimate and
troubleshooting.

## Contents

- [Where the branch comes from](#where-the-branch-comes-from)
- [The new stack at a glance](#the-new-stack-at-a-glance)
- [Changes outside the stack directory](#changes-outside-the-stack-directory)
- [Base files the stack overrides](#base-files-the-stack-overrides)
- [Settings in data-stack.tfvars](#settings-in-data-stacktfvars)
- [Stack inputs](#stack-inputs)

## Where the branch comes from

`redpanda-on-eks` branches off `benchmark-against-redpanda-tier1`, which changed the
`kafka-on-eks` stack to benchmark Strimzi Kafka against Redpanda BYOC Tier 1. That work is
documented in
[BENCHMARK_CUSTOMIZATION.md](https://github.com/rafaeltuelho/data-on-eks/blob/benchmark-against-redpanda-tier1/BENCHMARK_CUSTOMIZATION.md)
on that branch. This branch inherits it unchanged, and the new stack depends on two of its
base infrastructure changes:

- **`enable_*` toggles for optional shared components** in `infra/terraform/variables.tf`. They
  default to `true`, so other stacks are unchanged. `redpanda-on-eks` uses them to skip
  ClickHouse, Fluent Bit, KEDA, Spark, Flink, Trino, Argo and YuniKorn.
- **The `install.sh` fix**: on an existing cluster it does one full `terraform apply` instead of the
  staged targeted applies. This keeps re-runs of `./deploy.sh` working, for example when you add
  client networks or expand the cluster.

## The new stack at a glance

| Area | What the stack does |
|---|---|
| Redpanda | Redpanda Operator `26.2.4` (ArgoCD) and Redpanda `v26.2.3`. 3 brokers, expandable through `redpanda_broker_replicas` |
| Brokers | One dedicated `m7gd.2xlarge` node per broker (Karpenter NodePool `redpanda-broker`), single AZ, local NVMe formatted XFS |
| Security | TLS (cert-manager) and SASL/SCRAM-SHA-512 on every listener, including the Admin API |
| Client access | NodePorts on the broker nodes with no load balancer, like Redpanda BYOC over VPC peering. Brokers publish their node IPs to a Route 53 private zone (`redpanda-<n>.redpanda.internal`, `bootstrap.redpanda.internal`) |
| Client networks | Managed by a separate client project (peering, routes, prefix list entries, zone associations). The stack exposes a prefix list for the NodePorts and its private zone, and never undoes those changes |
| Console and Connect | Redpanda Console (operator `Console` resource, port-forward by default). Optional Redpanda Connect (Helm chart, or the operator `Pipeline` resource with a license) |
| Monitoring | Chart ServiceMonitors and the official Grafana dashboards from `redpanda-data/observability` |
| Enterprise | The built-in 30-day trial (default on) enables Tiered Storage and Continuous Data Balancing. A license key also enables Console login/RBAC and Connect `Pipeline` |

## Changes outside the stack directory

The branch changes **nothing in `infra/terraform/`**. Everything stack-specific lives in
`data-stacks/redpanda-on-eks/`. The only other changes are:

| File | Change |
|---|---|
| `README.md` | The fork note at the top now describes this branch. |
| `REDPANDA_ON_EKS.md` | **New:** this file. |
| `BENCHMARK_CUSTOMIZATION.md` | **Removed** from this branch. It still lives on `benchmark-against-redpanda-tier1`. The `kafka-on-eks` files that referenced it now link to that branch. |
| `.gitignore` | Ignores `nohup.out` files. |
| `website/docs/datastacks/streaming/index.md` | New "Redpanda on EKS" tile in the Streaming section. |
| `website/docs/datastacks/streaming/redpanda-on-eks/` | **New** docs page (generated from the stack README) and the architecture diagram. |

## Base files the stack overrides

The deploy copies the stack's `terraform/` directory over `infra/terraform/` (the base + overlay
pattern), so these files replace their base versions **for this stack only**:

| Stack file | Base file | Why |
|---|---|---|
| `terraform/kafka.tf` | `infra/terraform/kafka.tf` | Removes Strimzi and the Kafka cluster, which the base always deploys. It keeps `kubectl_manifest.strimzi_kafka_operator` with `count = 0`, because `infra/terraform/datahub.tf` lists it in `depends_on`. |
| `terraform/karpenter.tf` | `infra/terraform/karpenter.tf` | Passes the Redpanda template variables to the NodePools, and also loads `ec2nodeclass-redpanda.yaml` next to the unchanged base `ec2nodeclass.yaml`. |
| `terraform/storage.tf` | `infra/terraform/storage.tf` | Adds the us-east-2 S3 Express One Zone AZ IDs. Without them, the base file fails to plan in us-east-2 (same fix as `kafka-on-eks`). |
| `terraform/helm-values/local-static-provisioner.yaml` | `infra/terraform/helm-values/local-static-provisioner.yaml` | Tolerates the broker taint and formats the NVMe disks XFS. |

These are full copies. Upstream changes to the base files don't reach this stack until you merge
them by hand.

## Settings in data-stack.tfvars

`data-stacks/redpanda-on-eks/terraform/data-stack.tfvars` sets these base variables. Other base
variables keep their defaults.

| Variable | Base default | `redpanda-on-eks` | Why |
|---|---|---|---|
| `name` | `data-on-eks` | `redpanda-on-eks` | Stack and cluster name. |
| `region` | `us-west-2` | `us-east-2` | Region of the reference Redpanda BYOC clusters. |
| `vpc_cidr` | `10.0.0.0/16` | `10.2.0.0/16` | Own VPC that doesn't clash with `kafka-on-eks` or the Redpanda BYOC networks a client VPC may already route. |
| `secondary_cidrs` | `100.64-66.0.0/16` | `100.80-82.0.0/16` | Same reason. The broker subnet (the `redpanda_zone` entry) is the only range a client network routes here. |
| `enable_amazon_prometheus` | `false` | `true` | Creates the AMP workspace (no samples are sent with the base Prometheus values). |
| `enable_cert_manager` | `true` | `true` | Kept on: the Redpanda chart issues its TLS certificates with cert-manager. |
| `enable_jupyterhub`, `enable_ingress_nginx` | `true` | `false` | Not used. |
| `enable_event_logging`, `enable_aws_for_fluentbit`, `enable_keda`, `enable_data_teams`, `enable_trino`, `enable_spark_operator`, `enable_spark_history_server`, `enable_flink_operator`, `enable_argo_workflows`, `enable_argo_events`, `enable_yunikorn` | `true` | `false` | Not needed by Redpanda (toggles from the benchmark branch). |
| `managed_node_groups.core_node_group` | 4× `m6a.xlarge`, 100 GiB | 3× `m5.large`, 50 GiB | Sized for the system add-ons (ArgoCD, Karpenter, Prometheus, cert-manager, operator, Console). Brokers never run there. |
| `deployment_id` | n/a | `DO-NOT-EDIT-AUTO-GENERATED` | `deploy.sh` replaces it on the first deploy. Keep that value locally, and don't commit it. |

## Stack inputs

The stack declares its own inputs in `terraform/redpanda-variables.tf`, with defaults set in
`data-stack.tfvars`. The [stack README](data-stacks/redpanda-on-eks/README.md) explains each one.

| Group | Variables |
|---|---|
| Versions | `redpanda_operator_chart_version`, `redpanda_version`, `redpanda_connect_chart_version` |
| Brokers | `redpanda_zone`, `redpanda_broker_replicas`, `redpanda_broker_instance_type`, `redpanda_broker_cpu_cores`, `redpanda_broker_memory`, `redpanda_broker_storage_size` |
| Client access | `redpanda_external_domain`, `redpanda_clients_prefix_list_max_entries` |
| Users | `redpanda_admin_username`, `redpanda_admin_password` (export `TF_VAR_...`; generated when unset) |
| Console and Connect | `enable_redpanda_console`, `redpanda_console_exposure`, `redpanda_console_allowed_cidrs`, `enable_redpanda_connect`, `redpanda_connect_deployment` |
| Enterprise | `redpanda_enterprise_license` (export `TF_VAR_...`), `redpanda_enterprise_builtin_trial`, `redpanda_enterprise_tiered_storage`, `redpanda_enterprise_continuous_balancing`, `redpanda_enterprise_console_auth` |

Secrets (the admin password and the license) are never set in tfvars: export them as `TF_VAR_...`
environment variables.
