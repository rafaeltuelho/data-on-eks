#!/bin/bash
# Redpanda Helper Script for redpanda-on-eks
# Cluster management and validation commands. Run with KUBECONFIG pointing at the cluster:
#   export KUBECONFIG=$(pwd)/kubeconfig.yaml

NS=redpanda
CLUSTER=redpanda

# rpk inside a broker pod, authenticated as the superuser from Secret redpanda-superusers
rpk_exec() {
  local creds user pass
  creds=$(kubectl -n "$NS" get secret redpanda-superusers -o jsonpath='{.data.users\.txt}' | base64 -d | head -n1)
  user=$(echo "$creds" | cut -d: -f1)
  pass=$(echo "$creds" | cut -d: -f2)
  kubectl -n "$NS" exec -i "$CLUSTER-0" -c redpanda -- rpk "$@" \
    -X user="$user" -X pass="$pass" -X sasl.mechanism=SCRAM-SHA-512
}

case "$1" in
  get-redpanda-pods)
    kubectl get pods -n "$NS" -o wide
    ;;
  get-all-redpanda-namespace)
    kubectl get all -n "$NS"
    ;;
  describe-redpanda-cluster)
    kubectl describe redpanda "$CLUSTER" -n "$NS"
    ;;
  get-redpanda-resources)
    kubectl get redpanda,console,users.cluster.redpanda.com,topics.cluster.redpanda.com -n "$NS"
    ;;
  get-redpanda-nodes)
    kubectl get nodes -l karpenter.sh/nodepool=redpanda-broker -o wide
    ;;
  get-redpanda-operator)
    kubectl -n "$NS" get pods -l app.kubernetes.io/name=operator
    ;;
  get-external-services)
    kubectl -n "$NS" get svc "$CLUSTER-external" -o wide
    echo ""
    kubectl -n "$NS" get pods -l app.kubernetes.io/component=redpanda-statefulset \
      -o custom-columns=BROKER:.metadata.name,NODE:.spec.nodeName,NODE_IP:.status.hostIP
    echo ""
    echo "DNS records are published by each broker's route53-dns init container:"
    echo "  kubectl -n $NS logs $CLUSTER-0 -c route53-dns"
    ;;
  cluster-info)
    rpk_exec cluster info
    ;;
  cluster-health)
    rpk_exec cluster health
    ;;
  list-topics)
    rpk_exec topic list
    ;;
  create-topic)
    TOPIC=${2:-my-topic}
    rpk_exec topic create "$TOPIC" -p "${3:-3}" -r 3
    ;;
  describe-topic)
    TOPIC=${2:-my-topic}
    rpk_exec topic describe "$TOPIC"
    ;;
  consume-test)
    TOPIC=${2:-my-topic}
    rpk_exec topic consume "$TOPIC" -n "${3:-10}"
    ;;
  rpk)
    shift
    rpk_exec "$@"
    ;;
  export-ca)
    kubectl get secret "$CLUSTER-external-root-certificate" -n "$NS" -o jsonpath='{.data.ca\.crt}' | base64 -d > redpanda-ca.crt
    echo "Saved redpanda-ca.crt (CA of the external listeners)"
    ;;
  port-forward-console)
    kubectl port-forward -n "$NS" svc/redpanda-console-console 8080:8080
    ;;
  port-forward-grafana)
    kubectl port-forward -n monitoring svc/monitoring-grafana 3000:80
    ;;
  port-forward-argocd)
    kubectl port-forward -n argocd svc/argocd-server 8443:443
    ;;
  get-argocd-apps)
    kubectl -n argocd get applications
    ;;
  *)
    echo "Redpanda Helper Script - Cluster management and validation commands"
    echo ""
    echo "Usage: $0 {COMMAND}"
    echo ""
    echo "Redpanda Resources:"
    echo "  get-redpanda-pods                 - Get all pods in the redpanda namespace"
    echo "  get-all-redpanda-namespace        - Get all resources in the redpanda namespace"
    echo "  describe-redpanda-cluster         - Describe the Redpanda resource"
    echo "  get-redpanda-resources            - Get Redpanda, Console, User and Topic resources"
    echo "  get-redpanda-nodes                - Get the broker nodes (redpanda-broker NodePool)"
    echo "  get-redpanda-operator             - Get the Redpanda Operator pods"
    echo "  get-external-services             - Get the NodePort Service and the brokers' external DNS records"
    echo ""
    echo "rpk (in broker pod redpanda-0, as the SASL superuser):"
    echo "  cluster-info                      - rpk cluster info"
    echo "  cluster-health                    - rpk cluster health"
    echo "  list-topics                       - rpk topic list"
    echo "  create-topic [name] [partitions]  - rpk topic create (RF 3, default my-topic, 3 partitions)"
    echo "  describe-topic [name]             - rpk topic describe"
    echo "  consume-test [name] [count]       - rpk topic consume -n count (default 10)"
    echo "  rpk <args...>                     - Any rpk command, e.g. ./helper.sh rpk topic produce my-topic"
    echo ""
    echo "Access:"
    echo "  export-ca                         - Save the external listener CA to redpanda-ca.crt"
    echo "  port-forward-console              - Redpanda Console on http://localhost:8080"
    echo "  port-forward-grafana              - Grafana on http://localhost:3000"
    echo "  port-forward-argocd               - ArgoCD on https://localhost:8443"
    echo "  get-argocd-apps                   - Get ArgoCD applications"
    exit 1
esac
