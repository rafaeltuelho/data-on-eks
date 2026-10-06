#!/bin/bash

set -e

# --- Configuration ---
STACKS="redpanda-on-eks"
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

# --- Redpanda summary: brokers, TLS CA, SASL user, Console, Grafana ---
print_redpanda_summary() {
    local ns=redpanda cluster=redpanda ca_file="$PWD/redpanda-ca.crt"
    local ready="" bootstrap="" user="" grafana_user="" grafana_pass="" console_lb="" console_auth="" features=""

    bootstrap=$(terraform -chdir="$TERRAFORM_DIR/_local" output -raw redpanda_bootstrap_servers 2>/dev/null || true)
    user=$(terraform -chdir="$TERRAFORM_DIR/_local" output -raw redpanda_admin_username 2>/dev/null || true)
    features=$(terraform -chdir="$TERRAFORM_DIR/_local" output -json redpanda_enterprise_features 2>/dev/null | tr -d ' \n' || true)
    console_auth=$(echo "$features" | sed -nE 's/.*"console_auth":(true|false).*/\1/p')

    # On a fresh deploy the broker nodes, pods and certificates take a few minutes
    print_status "Waiting for the Redpanda cluster to be Ready, up to 15 minutes..."
    for _ in $(seq 1 60); do
        ready=$(kubectl get redpanda "$cluster" -n "$ns" \
            -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || true)
        [ "$ready" = "True" ] && break
        sleep 15
    done
    [ "$ready" = "True" ] || print_warning "Redpanda is not Ready yet. Check: kubectl get redpanda,pods -n $ns"

    # CA of the external listeners (NodePorts)
    if kubectl get secret "$cluster-external-root-certificate" -n "$ns" \
        -o jsonpath='{.data.ca\.crt}' 2>/dev/null | base64 -d > "$ca_file" 2>/dev/null && [ -s "$ca_file" ]; then
        print_status "Saved the Redpanda external CA to $ca_file"
    else
        rm -f "$ca_file"; ca_file=""
    fi

    grafana_user=$(kubectl get secret grafana-admin-secret -n monitoring -o jsonpath='{.data.admin-user}' 2>/dev/null | base64 -d 2>/dev/null || true)
    grafana_pass=$(kubectl get secret grafana-admin-secret -n monitoring -o jsonpath='{.data.admin-password}' 2>/dev/null | base64 -d 2>/dev/null || true)
    console_lb=$(kubectl get svc redpanda-console-console -n "$ns" -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null || true)

    local cluster_name
    cluster_name=$(terraform -chdir="$TERRAFORM_DIR/_local" output -raw cluster_name 2>/dev/null || echo "$STACKS")

    echo ""
    echo "========================================="
    echo "kubectl access (uses your AWS credentials, e.g. an SSO session)"
    echo "========================================="
    echo "Option 1, this shell only (kubeconfig created by the deploy):"
    echo "   export KUBECONFIG=$PWD/$KUBECONFIG_FILE"
    echo ""
    echo "Option 2, add it to ~/.kube/config as context $cluster_name:"
    echo "   aws eks update-kubeconfig --name $cluster_name --region $AWS_REGION --alias $cluster_name"
    echo "   kubectl config use-context $cluster_name"
    echo ""
    echo "Check: kubectl get redpanda,console -n $ns   (on Unauthorized/token errors: aws sso login)"

    echo ""
    echo "========================================="
    echo "Redpanda Access"
    echo "========================================="
    echo "1. Bootstrap address (TLS + SASL/SCRAM-SHA-512, this VPC or a connected client network):"
    echo "   ${bootstrap:-bootstrap.<domain>:31092}"
    echo "   Brokers: terraform -chdir=$TERRAFORM_DIR/_local output redpanda_broker_addresses"
    echo "   Client networks: peer/route to this VPC, see terraform -chdir=$TERRAFORM_DIR/_local output redpanda_client_connectivity"
    echo ""
    echo "2. External listener CA (clients must trust it):"
    if [ -n "$ca_file" ]; then
        echo "   $ca_file"
        echo "   Copy it to each client, e.g.: scp $ca_file <user>@<client>:~/redpanda-ca.crt"
    else
        print_warning "Not available yet. Export it later with:"
        echo "   kubectl get secret $cluster-external-root-certificate -n $ns -o jsonpath='{.data.ca\\.crt}' | base64 -d > redpanda-ca.crt"
    fi
    echo ""
    echo "3. SASL superuser (SCRAM-SHA-512):"
    echo "   Username: ${user:-admin}"
    echo "   Password: terraform -chdir=$TERRAFORM_DIR/_local output -raw redpanda_admin_password"
    echo ""
    echo "4. rpk profile on a client (CA copied to ~/redpanda-ca.crt):"
    echo "   rpk profile create redpanda-on-eks \\"
    echo "     --set brokers=${bootstrap:-<bootstrap-address>} \\"
    echo "     --set tls.enabled=true --set tls.ca=\$HOME/redpanda-ca.crt \\"
    echo "     --set admin.hosts=${bootstrap%:*}:31644 --set admin.tls.enabled=true --set admin.tls.ca=\$HOME/redpanda-ca.crt \\"
    echo "     --set sasl.mechanism=SCRAM-SHA-512 --set user=${user:-admin} --set pass='<password>'"
    echo "   rpk cluster info"
    echo ""
    echo "5. Redpanda Console:"
    echo "   kubectl port-forward -n $ns svc/redpanda-console-console 8080:8080"
    echo "   Open http://localhost:8080"
    if [ "$console_auth" = "true" ]; then
        echo "   Log in with a Redpanda SASL user, e.g. ${user:-admin} (Console admin role)"
    fi
    if [ -n "$console_lb" ]; then
        echo "   Also exposed through the NLB: http://$console_lb:8080"
        [ "$console_auth" = "true" ] || print_warning "Console has no login without an Enterprise license: keep the NLB CIDRs tight"
    fi
    echo ""
    echo "6. Enterprise features (TF_VAR_redpanda_enterprise_license):"
    echo "   ${features:-<terraform output redpanda_enterprise_features>}"
    echo ""
    echo "7. Grafana (Redpanda dashboards):"
    echo "   kubectl port-forward -n monitoring svc/monitoring-grafana 3000:80"
    echo "   Open http://localhost:3000"
    echo "   Username: ${grafana_user:-admin}"
    echo "   Password: ${grafana_pass:-<see kubectl get secret grafana-admin-secret -n monitoring>}"
    echo "========================================="
}

print_redpanda_summary
