# Benchmark customization: Strimzi Kafka vs Redpanda BYOC Tier 1

This fork of [awslabs/data-on-eks](https://github.com/awslabs/data-on-eks) changes the
`kafka-on-eks` stack (`data-stacks/kafka-on-eks/`) so a Strimzi Kafka cluster can be
benchmarked fairly against a **Redpanda BYOC Tier 1** cluster. The two clusters get the same
broker hardware, the same AZ, the same client security and the same benchmark clients.

Most changes are overlay files in `data-stacks/kafka-on-eks/`, which `./deploy.sh` copies over the
base files when you deploy. The one exception is `infra/terraform/`, which gained `enable_*`
toggles for optional shared components. They default to `true`, so every other stack behaves
exactly as before. See [Base infrastructure changes](#base-infrastructure-changes).

## Contents

- [Target sizing](#target-sizing)
- [Versions](#versions)
- [Configuration (tfvars)](#configuration-tfvars)
- [Deploy](#deploy)
- [Change log](#change-log)
- [Network setup: VPC peering](#network-setup-vpc-peering)
- [Exposing Kafka outside EKS: internal NLBs](#exposing-kafka-outside-eks-internal-nlbs)
- [Connecting the benchmark clients](#connecting-the-benchmark-clients)
- [Monitoring (Prometheus + Grafana)](#monitoring-prometheus--grafana)
- [Benchmark fairness notes](#benchmark-fairness-notes)
- [Tuning guide](#tuning-guide)
- [Troubleshooting](#troubleshooting)
- [Cleanup](#cleanup)

## Target sizing

Redpanda BYOC Tier 1 is rated for 20 MB/s ingress, 60 MB/s egress, 2,000 partitions
(before replication) and 9,000 connections.

| Role | Redpanda BYOC Tier 1 (reference) | This Strimzi stack |
|---|---|---|
| Control plane | EKS standard | EKS standard |
| Brokers | 3× `m7gd.large` (Graviton3, 2 vCPU, 8 GiB, 118 GB NVMe), on-demand | 3× `m7gd.large`, on-demand, one broker per node |
| Broker storage | Local NVMe | Local NVMe (XFS), 100Gi PV per broker |
| Metadata | Built into the brokers (Raft) | 3× `m7g.large` dedicated KRaft controllers (Kafka-only overhead) |
| System / utility nodes | 2× `m5.large` | 3× `m5.large` (runs ArgoCD, Karpenter, Prometheus, Strimzi operator) |
| AZ | Single AZ | Single AZ (`benchmark_zone`) |
| Client access | Peered VPC, TLS + SASL/SCRAM | Peered VPC, internal NLBs, TLS + SASL/SCRAM-SHA-512 |

## Versions

| Component | Version | Where |
|---|---|---|
| Strimzi operator | **1.2.0** | `terraform/argocd-applications/strimzi-kafka-operator.yaml` (overrides base 0.47.0) |
| Apache Kafka | **4.3.1**, metadata `4.3-IV0` (KRaft) | `spec.kafka.version` in `terraform/manifests/kafka/kafka-cluster.yaml` |
| Strimzi CRD API | `kafka.strimzi.io/v1` | All Strimzi manifests. Strimzi 1.0 removed `v1beta2`. |

Strimzi 1.2.0 supports Kafka 4.2.0, 4.2.1, 4.3.0 and 4.3.1. The base stack (`infra/terraform`)
stays on Strimzi 0.47.0 / `v1beta2`, so other stacks are unaffected.

### Upgrading an existing cluster (0.47.0 / Kafka 3.9 → 1.2.0 / Kafka 4.3.1)

There's no supported in-place path that keeps the cluster. Strimzi 1.x serves only the `v1` API,
and CRDs that still list `v1beta2` as a stored version can't drop it without Strimzi's conversion
tooling (0.49–0.51). A benchmark cluster holds no data worth migrating, so redeploy from scratch:

```bash
cd data-stacks/kafka-on-eks && source set-env.sh
./cleanup.sh                                   # ~20+ min; removes everything, including the peering
read -rs TF_VAR_benchmark_kafka_admin_password && export TF_VAR_benchmark_kafka_admin_password
./deploy.sh                                    # ~30+ min
```

After the redeploy, the clients need updating. There's a **new cluster CA** and **new NLB
hostnames**: export `strimzi-ca.crt` again, and point the rpk profile at the new bootstrap address
(`rpk profile set brokers=<new-bootstrap-nlb>:9094`). The peering, user and password are recreated
from tfvars and `TF_VAR_benchmark_kafka_admin_password`.

Other changes that come with 1.x:

- **Entity operator metrics ports:** renamed to `healthcheck-to` and `healthcheck-uo` (Strimzi 1.1.0).
  `monitoring-manifests/podmonitor-entity-operator-metrics.yaml` scrapes both.
- **Security context:** the operator Helm chart defaults to the Restricted Pod Security Standard (1.2.0).
- **Kafka 4.x clients:** clients must be recent enough. Kafka 4.0 dropped very old client protocol
  versions, so use a current Kafka client library in OpenMessaging Benchmark.

## Configuration (tfvars)

Every environment-specific value is an input in `data-stacks/kafka-on-eks/terraform/data-stack.tfvars`.
The inputs are declared in `terraform/benchmark-variables.tf`.

| Variable | Default | Purpose |
|---|---|---|
| `region` | `us-east-2` | AWS region. `deploy.sh` and `set-env.sh` read it from tfvars. |
| `benchmark_zone` | `us-east-2a` | AZ for brokers, controllers and NLBs. Use the AZ of the Redpanda cluster and the benchmark clients, and check that it's the same physical AZ (same AZ ID). It must be one of the first 3 AZs in the region. |
| `benchmark_broker_instance_type` | `m7gd.large` | Broker instance type. It must have local NVMe. |
| `benchmark_controller_instance_type` | `m7g.large` | KRaft controller instance type. |
| `benchmark_peer_vpc_id` | `null` | VPC of the benchmark clients. `null` disables peering, and the NLBs then accept only this VPC's CIDR. |
| `benchmark_kafka_admin_username` | `admin` | SCRAM user for the external listener. |
| `benchmark_kafka_admin_password` | `null` | **Never put this in tfvars.** Export `TF_VAR_benchmark_kafka_admin_password`. When it's `null`, no user is created. |
| `managed_node_groups.core_node_group` | 3× `m5.large` | System node group. It replaces the base `core_node_group` entirely. |
| `enable_*` component toggles | base: `true`; this stack: `false` | Skip components Kafka doesn't need. See [Removed components](#removed-components). |

Terraform derives the remaining values:

- The NLB subnet: `<name>-private-secondary1-<benchmark_zone>`.
- The routed secondary CIDR: the entry of `secondary_cidrs` for `benchmark_zone`, `100.64.0.0/16` for the first AZ.
- The NLB source range: the peer VPC's CIDR.

## Deploy

```bash
cd data-stacks/kafka-on-eks
# 1. Edit terraform/data-stack.tfvars (region, benchmark_zone, benchmark_peer_vpc_id, ...)
# 2. Provide the Kafka user password (keep it out of git and shell history)
read -rs TF_VAR_benchmark_kafka_admin_password && export TF_VAR_benchmark_kafka_admin_password
# 3. Deploy (VPC -> EKS -> Karpenter -> everything else, ~30+ min)
./deploy.sh
source set-env.sh                        # KUBECONFIG + AWS_REGION
kubectl get nodes -L node.kubernetes.io/instance-type,topology.kubernetes.io/zone
kubectl get kafka,kafkanodepool,kafkauser -n kafka
```

Use `./deploy.sh` from the stack directory. Don't run `infra/terraform/install.sh` directly, and
don't follow the older AWS blog post (`streaming/kafka/install.sh`, a layout that no longer
exists). `deploy.sh` sets the stack, region and overlay before calling the shared installer.

**kubectl access:** `deploy.sh` writes `kubeconfig.yaml` in the stack directory, and
`source set-env.sh` points `KUBECONFIG` at it in the current shell. To add the cluster to
`~/.kube/config` instead, run `aws eks update-kubeconfig --name <name> --region <region>`.

The first run writes a random `deployment_id` into `data-stack.tfvars`. Keep it, because later
runs and `cleanup.sh` use it to find tagged resources. Don't commit it.

Terraform creates the Kafka cluster, its node pools and the SCRAM user. Nothing needs a manual
`kubectl apply`. To change the cluster, edit the files under `terraform/manifests/` and run
`./deploy.sh` again.

> **Turning components off in a running cluster:** ArgoCD Applications created before the
> `resources-finalizer` was added don't cascade-delete. Add the finalizer before running `./deploy.sh`:
> ```bash
> for a in cert-manager clickhouse-operator; do
>   kubectl patch application $a -n argocd --type merge \
>     -p '{"metadata":{"finalizers":["resources-finalizer.argocd.argoproj.io"]}}'
> done
> ```
> Run `terraform plan -var-file=../data-stack.tfvars` in `terraform/_local` first. Only the toggled
> components should show as destroyed.

> **Migrating a cluster deployed from an earlier commit of this branch:** at first the Kafka CR and
> the `admin` KafkaUser were applied by hand. When Terraform first manages them, it adopts the
> existing objects with `kubectl apply` semantics, and the rendered manifests produce no diff
> against them. Run `terraform plan` in `terraform/_local` first if you want to confirm.

## Change log

All paths are relative to `data-stacks/kafka-on-eks/`.

### Sizing and placement

| File | Change |
|---|---|
| `terraform/data-stack.tfvars` | Region `us-east-2`; JupyterHub and ingress-nginx disabled; core node group 3× `m5.large` with a 50 GiB root volume; benchmark inputs. |
| `terraform/manifests/karpenter/nodepool-kafka-benchmark-broker.yaml` | **New** NodePool `kafka-benchmark-broker`. Allows only `benchmark_broker_instance_type`, on-demand, in `benchmark_zone`. Tainted `benchmark/dedicated=kafka-broker:NoSchedule`. Nodes are never consolidated or expired (budget `0`, `expireAfter: Never`), because local NVMe data would be lost. `terminationGracePeriod: 4m` must stay below the 300s wait in `cleanup.sh`. |
| `terraform/manifests/karpenter/nodepool-kafka-benchmark-controller.yaml` | **New** NodePool `kafka-benchmark-controller`: `benchmark_controller_instance_type`, on-demand, `benchmark_zone`, taint `benchmark/dedicated=kafka-controller`. `m7g.medium` is too small because its 8-pod limit is filled by DaemonSets. |
| `terraform/manifests/karpenter/ec2nodeclass.yaml` | A copy of the base file plus the **new** `kafka-benchmark-broker-nvme` class. It has the same NVMe udev discovery as `ephemeral-nvme-local-provisioner`, but without the Spark-tuned `MemoryQoS`/`memoryThrottlingFactor`, which would throttle the broker cgroup. |
| `terraform/karpenter.tf` | A copy of the base file. The only change: the NodePool templates also receive `local.benchmark_template_vars`. |
| `terraform/helm-values/local-static-provisioner.yaml` | Tolerates the broker taint. NVMe devices are formatted as XFS (`volumeMode: Filesystem`, `fsType: xfs`). |
| `terraform/storage.tf` | A copy of the base file that adds the us-east-2 S3 Express One Zone AZ IDs (`use2-az1`, `use2-az2`). The base file fails to plan in us-east-2. |

### Kafka (Strimzi)

| File | Change |
|---|---|
| `terraform/argocd-applications/strimzi-kafka-operator.yaml` | A copy of the base file with `targetRevision: 1.2.0` instead of 0.47.0. |
| All Strimzi manifests | `apiVersion: kafka.strimzi.io/v1`. The obsolete `strimzi.io/kraft` / `strimzi.io/node-pools` annotations are removed. |
| `terraform/manifests/kafka/kafka-cluster.yaml` | Kafka `4.3.1`, metadata `4.3-IV0`. Moved from `kafka-cluster/` and now applied by Terraform as a template. Changes: resources, JVM options, storage and placement moved to the node pools; rack awareness removed (single AZ); `external` listener added (NLB, TLS, SCRAM-SHA-512); simple authorization with `ANONYMOUS` as a super user, so the in-cluster `plain`/`tls` listeners still work. |
| `terraform/manifests/kafka/node-pool-broker.yaml` | Per-broker NLB annotations (`template.perPodService`). 3 brokers. Requests 1 CPU / 5Gi, no limits (like Redpanda, the broker can use the whole node, including page cache). Heap `-Xms/-Xmx 2g`. 100Gi `local-storage` volume. Pinned to `kafka-benchmark-broker`, one per node. Pods carry `karpenter.sh/do-not-disrupt`. |
| `terraform/manifests/kafka/node-pool-controller.yaml` | 3 controllers. Requests 250m / 1536Mi, memory limit 2Gi, heap 768m. 20Gi gp3 volume. Pinned to `kafka-benchmark-controller`. |
| `terraform/manifests/kafka/rebalance.yaml` | `RackAwareGoal` removed, because one rack can't satisfy RF=3. |
| `terraform/kafka.tf` | A copy of the base file. The only change: Kafka manifests are rendered with `local.benchmark_template_vars`. |
| `terraform/manifests/benchmark/kafka-user.yaml` | **New** KafkaUser template: SCRAM-SHA-512, `All` on cluster, groups, topics and transactional IDs. Redpanda's Subject and Schema Registry ACLs have no Kafka equivalent. |
| `terraform/kafka-benchmark-user.tf` | **New.** When the password variable is set, creates the `<username>-password` Secret and the KafkaUser. |
| `kafka-cluster/` | Duplicate copies removed. Its README points to the Terraform-managed manifests. |

### Removed components

These components aren't deployed in this stack. Each one is switched off with an `enable_*`
toggle in `terraform/data-stack.tfvars`:

| Toggle (`= false`) | Component | Why it's not needed |
|---|---|---|
| `enable_event_logging` | ClickHouse operator, ClickHouse event-store + Keeper, event-collector Fluent Bit | Spark-oriented log and event store. It ran on an `r8g.4xlarge` (~$1.13/h). |
| `enable_aws_for_fluentbit` | aws-for-fluent-bit DaemonSet | It only tails system and Spark pod logs, never Kafka. |
| `enable_cert_manager` | cert-manager | Only the ClickHouse operator used it. Strimzi has its own CA. |
| `enable_keda` | KEDA | Only Trino and StarRocks use it. |
| `enable_data_teams` | Spark/Flink/Ray team namespaces, RBAC, Pod Identity roles | No data teams here. |
| `enable_trino` | Trino (+ S3 buckets, IAM) | Not used. |
| `enable_spark_operator`, `enable_spark_history_server` | Spark operator, Spark History Server | Not used. |
| `enable_flink_operator` | Flink operator | Not used. |
| `enable_argo_workflows`, `enable_argo_events` | Argo Workflows / Events | Not used. |
| `enable_yunikorn` | YuniKorn scheduler | Not used. |
| `enable_jupyterhub`, `enable_ingress_nginx` | JupyterHub, ingress-nginx | Not used (toggles that already existed). |

ArgoCD, Karpenter, the AWS Load Balancer Controller, local-static-provisioner, the EBS CSI driver
and kube-prometheus-stack stay: Kafka needs them. The S3 buckets and the Glue database stay too,
because other base files reference them and they cost almost nothing.

### Base infrastructure changes

`infra/terraform/` changes, shared by all stacks and backward compatible:

| File | Change |
|---|---|
| `variables.tf` | New toggles: `enable_event_logging`, `enable_aws_for_fluentbit`, `enable_cert_manager`, `enable_keda`, `enable_data_teams`, `enable_trino`, `enable_spark_operator`, `enable_spark_history_server`, `enable_flink_operator`, `enable_argo_workflows`, `enable_argo_events`, `enable_yunikorn`. All default to `true`. |
| `event-collector.tf`, `clickhouse.tf`, `aws-for-fluentbit.tf`, `cert-manager.tf`, `keda.tf`, `trino.tf`, `spark-operator.tf`, `spark-history-server.tf`, `argo-workflows.tf`, `argo-events.tf`, `k8s-scheduler.tf` | Resources gated by `count`/`for_each`. `moved` blocks keep existing state addresses, so stacks already deployed see no replacement. `random_password.clickhouse` stays unconditional, because the Grafana ClickHouse datasource references it. |
| `teams.tf` | Team Kubernetes objects and Pod Identity roles gated by `enable_data_teams`. The IAM policies stay, because JupyterHub and Karpenter reference them. |
| `flink.tf` | `count = enable_flink_operator && !enable_emr_on_eks`. |
| `polaris.tf` | The Trino-side Polaris resources also require `enable_trino`. |
| `install.sh` | When the state already contains Karpenter (an existing cluster), skip the staged `-target` applies and do one full apply. Targeted applies fail when the config contains `moved` blocks, and the stages are only needed on fresh installs. |
| `argocd-applications/{cert-manager,clickhouse-operator,flink-operator,argo-workflows,argo-events}.yaml` | Added ArgoCD's `resources-finalizer`, so deleting the Application also deletes its workloads instead of orphaning them. |

Toggle dependencies: `enable_raydata` requires `enable_data_teams`. Polaris's Trino integration
requires `enable_trino`. ClickHouse needs `enable_cert_manager` when `enable_event_logging` is on.

### Monitoring

| File | Change |
|---|---|
| `terraform/kafka-benchmark-monitoring.tf` | **New.** Applies `monitoring-manifests/` (PodMonitors + Strimzi Grafana dashboards). |
| `monitoring-manifests/grafana-strimzi-*.yaml` | Dashboard ConfigMaps moved to the `monitoring` namespace, where Grafana runs. |
| `monitoring-manifests/podmonitor-entity-operator-metrics.yaml` | Scrapes the Strimzi ≥ 1.1 port names `healthcheck-to` and `healthcheck-uo`. |

### Networking

| File | Change |
|---|---|
| `terraform/benchmark-variables.tf` | **New.** All benchmark inputs and derived values. |
| `terraform/vpc-peering-benchmark.tf` | **New.** VPC peering and routes to the benchmark client VPC (see below). |
| `deploy.sh`, `set-env.sh` | The region is read from tfvars. |

## Network setup: VPC peering

```
 benchmark client VPC (benchmark_peer_vpc_id)         Strimzi VPC (this stack)
 e.g. 10.100.0.0/16                                   10.0.0.0/16 + 100.64-66.0.0/16
 ┌─────────────────────────┐   VPC peering            ┌──────────────────────────────────┐
 │ OMB / rpk clients       │◄────────────────────────►│ 100.64.0.0/16 (benchmark_zone)   │
 │ route 100.64.0.0/16→pcx │                          │  internal NLBs → broker pod IPs  │
 │ route 10.0.0.0/16→BYOC  │  (existing peering to    │ private RTs: 10.100.0.0/16→pcx   │
 └─────────────────────────┘   Redpanda BYOC VPC)     └──────────────────────────────────┘
```

`terraform/vpc-peering-benchmark.tf` creates:

1. **`aws_vpc_peering_connection.benchmark_peer`**, from the Strimzi VPC to `benchmark_peer_vpc_id`.
   It is auto-accepted, which requires the same account and region.
2. **`aws_route.kafka_to_benchmark_peer`**: in every private route table of the Strimzi VPC,
   peer VPC CIDR → peering.
3. **`aws_route.benchmark_peer_to_kafka`**: in every route table of the peer VPC, the benchmark AZ's
   secondary CIDR → peering. Terraform adds this route to a VPC it doesn't otherwise manage,
   and removes it on destroy.

**Why only the secondary CIDR is routed.** The Redpanda BYOC VPC and this stack both use
`10.0.0.0/16`, and the client VPC already routes `10.0.0.0/16` to BYOC. A second route for
the same range isn't possible. The brokers' pod IPs and their NLBs live in the benchmark AZ's
secondary subnet (`100.64.0.0/16`), so that is the only range the clients need.

**Requirements:**
- The peer VPC's CIDR must not overlap any of this VPC's CIDRs (`vpc_cidr`, `secondary_cidrs`).
- Peering isn't transitive: hosts in the BYOC VPC can't reach Strimzi through the client VPC.

**Manual check:**
```bash
terraform -chdir=terraform/_local output benchmark_peering_connection_id
aws ec2 describe-route-tables --filters Name=vpc-id,Values=<peer-vpc-id> \
  --query 'RouteTables[].Routes[?VpcPeeringConnectionId!=`null`]'
```

## Exposing Kafka outside EKS: internal NLBs

The `external` listener in `terraform/manifests/kafka/kafka-cluster.yaml` is a Strimzi
`loadbalancer` listener on port **9094**:

- **Load balancers:** Strimzi creates one bootstrap Service and one Service per broker, all of type
  `LoadBalancer`. `configuration.class: service.k8s.aws/nlb` hands them to the AWS Load
  Balancer Controller, which creates **4 internal NLBs**.
- **NLB annotations:** `template.externalBootstrapService` in `kafka-cluster.yaml` for the bootstrap NLB,
  and `template.perPodService` in **`node-pool-broker.yaml`** for the per-broker NLBs. With node
  pools, Strimzi ignores `perPodService` in the Kafka CR. If it's set there, the broker NLBs fall
  back to controller defaults: instance targets, every AZ, `10.0.x` subnets. The annotations are
  `scheme: internal`, `nlb-target-type: ip` (traffic goes straight to broker pod IPs, not
  through NodePorts), `subnets: <name>-private-secondary1-<benchmark_zone>`, and cross-zone
  load balancing disabled.
- **Access control:** `loadBalancerSourceRanges` is set to the peer VPC CIDR and applied to the
  NLB security group.
- **Advertised addresses:** each broker advertises its own NLB hostname, and Strimzi adds those
  hostnames to the broker TLS certificates. The NLB DNS names are public and resolve to
  private `100.64.x.x` IPs.
- **Security:** TLS, using Strimzi's self-signed cluster CA, plus `authentication: scram-sha-512`.
  Strimzi doesn't support SCRAM-SHA-256.

Check:
```bash
kubectl get svc -n kafka | grep external        # 4 services with NLB hostnames
kubectl get kafka data-on-eks -n kafka \
  -o jsonpath='{.status.listeners[?(@.name=="external")].bootstrapServers}'
```

### Changing NLB settings

The AWS Load Balancer Controller can't change some settings, such as the scheme or subnets, on an
NLB that already exists. After you change the NLB annotations, check the controller logs
(`kubectl logs -n kube-system deploy/aws-load-balancer-controller`). If an NLB didn't update,
delete its Service. Strimzi recreates it, and the controller provisions a new NLB:
```bash
kubectl delete svc -n kafka data-on-eks-broker-0 data-on-eks-broker-1 data-on-eks-broker-2
```
New per-broker NLBs get new DNS names. Strimzi updates the advertised listeners and the broker
certificates with a rolling restart. Clients that bootstrap through the bootstrap NLB pick up the
new names automatically.

## Connecting the benchmark clients

### 1. Get the bootstrap address

```bash
cd data-stacks/kafka-on-eks && source set-env.sh
kubectl get kafka data-on-eks -n kafka \
  -o jsonpath='{.status.listeners[?(@.name=="external")].bootstrapServers}'
# -> k8s-kafka-dataonek-<id>.elb.<region>.amazonaws.com:9094
```

Clients need only this **one bootstrap address** as the seed. After the first metadata request,
they connect to each broker at its advertised address, which is that broker's own NLB. Don't use
a per-broker NLB as the seed: if that broker restarts, new clients can't bootstrap.

### 2. Export the cluster CA certificate

Clients trust the **cluster CA**, not individual broker certificates. Strimzi signs every broker
certificate with it.

```bash
kubectl get secret data-on-eks-cluster-ca-cert -n kafka \
  -o jsonpath='{.data.ca\.crt}' | base64 -d > strimzi-ca.crt
openssl x509 -in strimzi-ca.crt -noout -subject -enddate   # O=io.strimzi, CN=cluster-ca v0
scp strimzi-ca.crt <user>@<client-host>:~/                 # to every benchmark client
```

The CA certificate isn't secret, but it's specific to one deployment, so don't commit it.
Strimzi renews it after about a year.

Optional: from a client host, confirm that the broker certificate includes the NLB hostnames. You
should see `Verify return code: 0 (ok)`, and the SANs should list the bootstrap NLB plus the
broker's own NLB.
```bash
openssl s_client -connect <bootstrap-nlb-dns>:9094 -CAfile strimzi-ca.crt </dev/null 2>/dev/null \
  | openssl x509 -noout -ext subjectAltName
```

### 3. Create an rpk profile (on each client host)

```bash
rpk profile create strimzi \
  --set brokers=<bootstrap-nlb-dns>:9094 \
  --set tls.enabled=true \
  --set tls.ca=/home/<user>/strimzi-ca.crt \
  --set sasl.mechanism=SCRAM-SHA-512 \
  --set user=admin \
  --set pass='<password>' \
  --description "Strimzi benchmark cluster (TLS + SCRAM-SHA-512)"

rpk profile print            # check the brokers hostname carefully (starts with k8s-)
rpk cluster info             # lists 3 brokers, each advertised at its own NLB:9094
```

- **Fixing a value:** `rpk profile set brokers=<bootstrap-nlb-dns>:9094`.
- **Cert path:** use an absolute path for `tls.ca`. The profile stores it as written.
- **Password:** the profile keeps it in plain text in `~/.config/rpk/rpk.yaml`. To keep it out of
  the profile, leave out `pass` and run `export RPK_PASS='<password>'` instead.
- **Switching clusters:** `rpk profile use strimzi`, `rpk profile use <redpanda-profile>`, or
  one-off with `--profile strimzi`. `rpk profile list` shows all profiles.
- **Redpanda-only commands:** `rpk cluster health` and other Admin API commands (port 9644) don't
  work against Kafka. Use Kafka-protocol commands: `rpk cluster info`, `rpk topic`, `rpk group`,
  `rpk acl`.

### 4. Smoke test

```bash
rpk topic create smoke -p 3 -r 3 -c min.insync.replicas=2
echo hello | rpk topic produce smoke --acks=-1
rpk topic consume smoke -n 1
rpk topic delete smoke
```

### 5. Kafka client / OpenMessaging Benchmark driver properties

```properties
bootstrap.servers=<bootstrap-nlb-dns>:9094
security.protocol=SASL_SSL
sasl.mechanism=SCRAM-SHA-512
sasl.jaas.config=org.apache.kafka.common.security.scram.ScramLoginModule required username="admin" password="<password>";
ssl.truststore.type=PEM
ssl.truststore.location=/path/to/strimzi-ca.crt
```
The only difference from a Redpanda BYOC client config is `sasl.mechanism`.

### In-cluster access (without the NLBs)

The internal listeners need no auth and are only reachable inside the cluster:
`data-on-eks-kafka-bootstrap.kafka.svc:9092` (plain) and `:9093` (TLS). To get a throwaway client:
```bash
kubectl run kafka-client -n kafka -it --rm --restart=Never \
  --image=quay.io/strimzi/kafka:1.2.0-kafka-4.3.1 -- \
  bin/kafka-broker-api-versions.sh --bootstrap-server data-on-eks-kafka-bootstrap:9092
```
`kubectl port-forward` from a laptop doesn't work. The brokers advertise in-cluster or NLB
hostnames, and the laptop can't reach those.

## Monitoring (Prometheus + Grafana)

`terraform/kafka-benchmark-monitoring.tf` applies `monitoring-manifests/`:

- **PodMonitors** for the brokers, controllers, Kafka exporter, entity operator and cluster operator.
  Prometheus selects PodMonitors in all namespaces.
- **Grafana dashboards:** *Strimzi Kafka*, *Strimzi Exporter* (consumer lag, topic metrics) and
  *Strimzi Operators*. They're ConfigMaps in `monitoring`, labeled `grafana_dashboard: "1"`. The
  upstream files pointed at a nonexistent `kube-prometheus-stack` namespace; this fork fixes them.

### Accessing Grafana

Grafana isn't exposed outside the cluster. Its Service, `monitoring-grafana`, is `ClusterIP` with no
load balancer, so open it from your workstation with a port-forward. HTTP port-forwarding works
fine, unlike Kafka:

```bash
cd data-stacks/kafka-on-eks && source set-env.sh
kubectl port-forward -n monitoring svc/monitoring-grafana 3000:80
# open http://localhost:3000 in your browser; keep the command running while you use Grafana
```

**Login:** user `admin`. Terraform generates a random password when it deploys the stack
(`random_password.grafana` in the base `kube-prometheus-stack.tf`) and stores it in the
`grafana-admin-secret` Secret. A redeploy from scratch generates a new one, so read it from the
cluster rather than writing it down:

```bash
kubectl get secret grafana-admin-secret -n monitoring -o jsonpath='{.data.admin-user}' | base64 -d; echo
kubectl get secret grafana-admin-secret -n monitoring -o jsonpath='{.data.admin-password}' | base64 -d; echo
```

The Strimzi dashboards are under **Dashboards**: *Strimzi Kafka*, *Strimzi Exporter* and
*Strimzi Operators*.

> To reach Grafana without a port-forward, you'd add a separate `LoadBalancer` Service that selects
> the Grafana pods (`app.kubernetes.io/name=grafana`, `app.kubernetes.io/instance=monitoring`).
> From a laptop that means an internet-facing NLB, restricted with `loadBalancerSourceRanges` to
> your IP/32. That serves the admin login over plain HTTP, so this fork doesn't do it.


**Cruise Control isn't a console.** It's a REST service for load monitoring and rebalancing,
driven through `KafkaRebalance` resources (`terraform/manifests/kafka/rebalance.yaml`). Strimzi
doesn't ship its web UI, so it isn't exposed. For a Kafka UI (topics, groups, messages), any
Kafka console works against the `external` listener or the in-cluster listeners. For example,
Redpanda Console with the same SCRAM and CA settings as the clients.

## Benchmark fairness notes

- **Durability:** Redpanda fsyncs every `acks=all` write. By default Kafka acknowledges writes
  from the page cache. Report this difference rather than tuning it away.
- **NLB hop:** clients reach Kafka through an NLB. If your clients reach Redpanda brokers
  directly over peering, Kafka pays a small extra latency per request. A `nodeport` listener
  avoids the hop.
- **SCRAM mechanism:** SHA-512 (Kafka) vs SHA-256 (Redpanda). It only matters at connection
  setup, so it doesn't affect throughput or latency.
- **Retention:** there's no tiered storage. With RF=3 on 3 brokers, each broker stores all
  ingress: about 72 GB/hour at 20 MB/s, so 100Gi fills in about 80 minutes. Set the same
  `retention.bytes`/`retention.ms` on the benchmark topics in both systems.
- **Topic settings:** use identical topic settings in both systems (partitions, RF=3,
  `min.insync.replicas=2`, producer `acks=all`).
- **Controllers:** the 3 controller nodes are Kafka-only overhead. Report them alongside the results.
- **Logs:** no log shipper collects Kafka logs (aws-for-fluent-bit is disabled, and even when
  enabled it only tails system and Spark pods). Use `kubectl logs`.

## Tuning guide

| What | Where |
|---|---|
| Instance types, AZ, peer VPC, user | `terraform/data-stack.tfvars` |
| Broker CPU/memory/heap, storage size, replicas | `terraform/manifests/kafka/node-pool-broker.yaml` |
| Broker config (`num.io.threads`, etc.) | `spec.kafka.config` in `terraform/manifests/kafka/kafka-cluster.yaml` |
| Listener security / bootstrap NLB annotations | `terraform/manifests/kafka/kafka-cluster.yaml` |
| Per-broker NLB annotations | `template.perPodService` in `terraform/manifests/kafka/node-pool-broker.yaml` |
| User ACLs | `terraform/manifests/benchmark/kafka-user.yaml` |
| NVMe filesystem | `terraform/helm-values/local-static-provisioner.yaml` |
| Broker node kubelet / user data | the `kafka-benchmark-broker-nvme` class in `terraform/manifests/karpenter/ec2nodeclass.yaml` |

Constraints to keep in mind:

- **Storage:** KafkaNodePool storage can't change in place. To change `class` or `size`, recreate
  the node pool and its PVCs.
- **Broker size:** keep broker requests below the node's allocatable resources. On `m7gd.large` that
  is about 1.9 CPU and about 6.7Gi.
- **Base files:** `karpenter.tf`, `kafka.tf`, `storage.tf` and `ec2nodeclass.yaml` are full copies
  of base files. Upstream changes to those files won't reach this stack until you merge them by hand.

## Troubleshooting

| Symptom | Cause / fix |
|---|---|
| `Invalid index ... local.s3_express_azs is empty tuple` while planning `module.vpc` | The region has no S3 Express AZ IDs in the base list. Add them to `terraform/storage.tf`, as done for us-east-2. |
| `lookup k8s-...elb... : no such host` on a client | Typo in the broker address (for example a missing `k` in `k8s-`). Check `rpk profile print`. |
| Client connection hangs | Check that the client is in `benchmark_peer_vpc_id`, that the peering is active and that the peer route table has the secondary CIDR → `pcx-...`. Hosts in another VPC peered with the client VPC (e.g. a bastion in the Redpanda BYOC VPC) can't reach Strimzi, because peering isn't transitive and the BYOC VPC's CIDR overlaps. |
| Commands work but feel slow / sporadic timeouts | Check the per-broker NLBs: `aws elbv2 describe-load-balancers` should show a single subnet (`benchmark_zone`, `100.64.x`) and `ip` targets. If they span 3 AZs with `instance` targets, the `perPodService` annotations are missing. Their `10.0.x` IPs then route to the BYOC VPC from the client VPC, and traffic hops through NodePorts. See [Changing NLB settings](#changing-nlb-settings). |
| `rpk cluster health` hangs | It calls the Redpanda Admin API on port 9644. The NLBs only listen on 9094, so the connection silently times out. Expected with Kafka. |
| `Error: Moved resource instances excluded by targeting` during `./deploy.sh` | The deploy ran targeted applies over pending `moved` blocks. The fixed `install.sh` skips the targets on existing clusters. With an older copy, run once: `terraform -chdir=terraform/_local apply -var-file=../data-stack.tfvars`. |
| After switching a toggle off, the component's pods keep running | Its ArgoCD Application had no `resources-finalizer`, so the workloads were orphaned. Patch the finalizer onto it before the deploy (see below), or delete the leftover resources by hand. |
| Lists brokers, then hangs | That broker's NLB targets are still registering. Wait 1–2 minutes. `kubectl get svc -n kafka` shows all 4 `external` services with hostnames when they're ready. |
| `SASL authentication failed` | Check `user`, `pass` and `sasl.mechanism=SCRAM-SHA-512`. `kubectl get kafkauser admin -n kafka` must show `READY=True`, and Terraform must have run with `TF_VAR_benchmark_kafka_admin_password` set. |
| TLS `certificate signed by unknown authority` | `tls.ca` / `ssl.truststore.location` must point to the exported `strimzi-ca.crt`. |
| `unknown field ...` when applying a Strimzi resource | Check the field against the Strimzi 1.2.0 CRDs (`kafka.strimzi.io/v1`). For example, the load balancer class is `configuration.class`. `kubectl apply --dry-run=server -f <file>` validates without applying. |
| Brokers `Pending` | `kubectl get nodeclaims -o wide`, plus the logs of the `local-static-provisioner` pods in `kube-system` on the broker nodes. `kubectl get pv` should show one `local-storage` PV per broker node. |

## Cleanup

```bash
cd data-stacks/kafka-on-eks
kubectl delete kafka --all -n kafka   # optional: makes the node drain instant
./cleanup.sh
```

This also removes the peering and the route added to the peer VPC. Afterwards, check that no
instances tagged `karpenter.sh/nodepool=kafka-benchmark-*` remain in the region.
