#!/bin/bash

set -e

# --- Configuration ---
STACKS="kafka-on-eks"
TERRAFORM_DIR="terraform"
# Region defaults to `region` in terraform/data-stack.tfvars
AWS_REGION="${AWS_REGION:-$(sed -nE 's/^[[:space:]]*region[[:space:]]*=[[:space:]]*"([^"]+)".*/\1/p' "$TERRAFORM_DIR/data-stack.tfvars")}"
KUBECONFIG_FILE="kubeconfig.yaml"


# --- Get Repo Root ---
REPO_PATH=$(git rev-parse --show-toplevel)

# --- Source and Execute the Main Deployment Engine ---
# The centralized install.sh handles all the heavy lifting.
source "$REPO_PATH/infra/terraform/install.sh"

# --- Post-Deployment Steps ---
# Steps specific to this stack can be added here.
print_status "Running stack-specific post-deployment steps..."

# Backup the state file from the _local directory
cp "$TERRAFORM_DIR/_local/terraform.tfstate" "$TERRAFORM_DIR/terraform.tfstate.bak"
print_status "Backed up terraform.tfstate."

# Setup kubeconfig
setup_kubeconfig

# Get ArgoCD admin password
export KUBECONFIG=$KUBECONFIG_FILE
ARGOCD_PASSWORD=$(kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" | base64 -d)

print_next_steps

# --- Benchmark summary: Kafka access, TLS CA, Grafana ---
print_kafka_benchmark_summary() {
    local ns=kafka cluster=data-on-eks ca_file="$PWD/strimzi-ca.crt"
    local bootstrap="" user="" kafka_pass="" grafana_user="" grafana_pass=""

    # On a fresh deploy the brokers and their NLBs take a few minutes to come up
    print_status "Waiting for the Kafka external listener (bootstrap NLB), up to 10 minutes..."
    for _ in $(seq 1 40); do
        bootstrap=$(kubectl get kafka "$cluster" -n "$ns" \
            -o jsonpath='{.status.listeners[?(@.name=="external")].bootstrapServers}' 2>/dev/null || true)
        [ -n "$bootstrap" ] && break
        sleep 15
    done

    if kubectl get secret "$cluster-cluster-ca-cert" -n "$ns" \
        -o jsonpath='{.data.ca\.crt}' 2>/dev/null | base64 -d > "$ca_file" 2>/dev/null && [ -s "$ca_file" ]; then
        print_status "Saved the Kafka cluster CA to $ca_file"
    else
        rm -f "$ca_file"; ca_file=""
    fi

    # SCRAM user created by kafka-benchmark-user.tf (needs TF_VAR_benchmark_kafka_admin_password)
    user=$(kubectl get kafkauser -n "$ns" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)
    if [ -n "$user" ]; then
        kafka_pass=$(kubectl get secret "$user" -n "$ns" -o jsonpath='{.data.password}' 2>/dev/null | base64 -d 2>/dev/null || true)
    fi

    grafana_user=$(kubectl get secret grafana-admin-secret -n monitoring -o jsonpath='{.data.admin-user}' 2>/dev/null | base64 -d 2>/dev/null || true)
    grafana_pass=$(kubectl get secret grafana-admin-secret -n monitoring -o jsonpath='{.data.admin-password}' 2>/dev/null | base64 -d 2>/dev/null || true)

    echo ""
    echo "========================================="
    echo "Kafka Benchmark (Strimzi) Access"
    echo "========================================="
    echo "1. Bootstrap address (external listener, TLS + SCRAM-SHA-512, peered client VPC only):"
    if [ -n "$bootstrap" ]; then
        echo "   $bootstrap"
    else
        print_warning "Not ready yet. Get it later with:"
        echo "   kubectl get kafka $cluster -n $ns -o jsonpath='{.status.listeners[?(@.name==\"external\")].bootstrapServers}'"
    fi
    echo ""
    echo "2. Kafka cluster CA (clients must trust it):"
    if [ -n "$ca_file" ]; then
        echo "   $ca_file"
        echo "   Copy it to each benchmark worker, e.g.: scp $ca_file <user>@<worker>:~/strimzi-ca.crt"
    else
        print_warning "Not available yet. Export it later with:"
        echo "   kubectl get secret $cluster-cluster-ca-cert -n $ns -o jsonpath='{.data.ca\\.crt}' | base64 -d > strimzi-ca.crt"
    fi
    echo ""
    echo "3. Kafka SASL credentials (SCRAM-SHA-512):"
    if [ -n "$user" ]; then
        echo "   Username: $user"
        echo "   Password: ${kafka_pass:-<see kubectl get secret $user -n $ns>}"
    else
        print_warning "No KafkaUser found. Export TF_VAR_benchmark_kafka_admin_password and re-run ./deploy.sh"
    fi
    echo ""
    echo "4. rpk profile on a benchmark worker (CA copied to ~/strimzi-ca.crt):"
    echo "   rpk profile create strimzi \\"
    echo "     --set brokers=${bootstrap:-<bootstrap-address>} \\"
    echo "     --set tls.enabled=true --set tls.ca=\$HOME/strimzi-ca.crt \\"
    echo "     --set sasl.mechanism=SCRAM-SHA-512 --set user=${user:-<user>} --set pass='<password>'"
    echo "   rpk cluster info"
    echo ""
    echo "5. Grafana (Strimzi dashboards):"
    echo "   kubectl port-forward -n monitoring svc/monitoring-grafana 3000:80"
    echo "   Open http://localhost:3000"
    echo "   Username: ${grafana_user:-admin}"
    echo "   Password: ${grafana_pass:-<see kubectl get secret grafana-admin-secret -n monitoring>}"
    echo "========================================="
}

print_kafka_benchmark_summary
