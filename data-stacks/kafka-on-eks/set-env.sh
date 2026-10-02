export KUBECONFIG=$(pwd)/kubeconfig.yaml
export AWS_REGION=$(sed -nE 's/^[[:space:]]*region[[:space:]]*=[[:space:]]*"([^"]+)".*/\1/p' terraform/data-stack.tfvars)
