#!/bin/sh

# Color codes for formatting output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
MAGENTA='\033[0;35m'
BOLD='\033[1m'
NC='\033[0m' # No Color

# Print formatted messages
info() {
  printf "%b[INFO]%b %s\n" "${BLUE}" "${NC}" "$1"
}

success() {
  printf "%b[SUCCESS]%b %s\n" "${GREEN}" "${NC}" "$1"
}

warning() {
  printf "%b[WARNING]%b %s\n" "${YELLOW}" "${NC}" "$1"
}

error() {
  printf "%b[ERROR]%b %s\n" "${RED}" "${NC}" "$1" >&2
}

section() {
  printf "\n%b%b===== %s =====%b\n\n" "${BOLD}" "${MAGENTA}" "$1" "${NC}"
}

# Load environment variables from .env file
if [ -f .env ]; then
    info "Loading environment variables from .env file"
    # shellcheck disable=SC1091
    . ./.env
else
    error "ERROR: .env file not found!"
    exit 1
fi

KUBECONFIG_PATH="./kubeconfig"

# Check if DNS_ZONE_NAME is set in .env, otherwise use default
DNS_ZONE_NAME="${DNS_ZONE_NAME:-superhub.clickwefwefwef}"

# Check if CLUSTER_NAME and CLUSTER_REGION are set, otherwise use defaults
CLUSTER_NAME="${CLUSTER_NAME:-solana-cluster}"
CLUSTER_REGION="${CLUSTER_REGION:-eu-north-1}"

# Set default GPU node types if not provided
if [ -z "${GPU_NODE_FAMILIES}" ]; then
  GPU_NODE_FAMILIES='["g4dn"]'
fi

# Set inference host for vllm if not already set
if [ -z "${INFERENCE_HOST}" ]; then
  INFERENCE_HOST="inference.${DNS_ZONE_NAME}"
fi
export INFERENCE_HOST

# Set model spec file path, ensure it's absolute
MODEL_SPEC_FILE="${MODEL_SPEC_FILE:-./model_spec.yaml}"
if [ -n "${MODEL_SPEC_FILE}" ] && [ "${MODEL_SPEC_FILE#/}" = "${MODEL_SPEC_FILE}" ]; then
  # If path doesn't start with '/', it's relative - make it absolute
  MODEL_SPEC_FILE="$(pwd)/${MODEL_SPEC_FILE}"
fi
export MODEL_SPEC_FILE

export HF_TOKEN

section "Configuration"
info "Cluster name:         ${CLUSTER_NAME}"
info "Region:               ${CLUSTER_REGION}"
info "GPU nodes families:   ${GPU_NODE_FAMILIES}"
info "DNS zone:             ${DNS_ZONE_NAME}"

# Render the cluster.yaml from template
CLUSTER_DIR="cluster"
CLUSTER_TEMPLATE="${CLUSTER_DIR}/cluster.yaml.template"
CLUSTER_FILE="${CLUSTER_DIR}/cluster.yaml"

if [ -f "${CLUSTER_TEMPLATE}" ]; then
  info "Generating cluster.yaml from template..."
  # Replace the placeholders with the actual values
  sed -e "s/CLUSTER_NAME_PLACEHOLDER/${CLUSTER_NAME}/g" \
      -e "s/CLUSTER_REGION_PLACEHOLDER/${CLUSTER_REGION}/g" \
      "${CLUSTER_TEMPLATE}" > "${CLUSTER_FILE}"
  success "Updated ${CLUSTER_FILE} with name: ${CLUSTER_NAME}, region: ${CLUSTER_REGION}"
fi

section "Cluster Management"
# Check if the cluster already exists
info "Checking if cluster '${CLUSTER_NAME}' exists in region '${CLUSTER_REGION}'..."
if ! eksctl get cluster --name "${CLUSTER_NAME}" --region "${CLUSTER_REGION}" > /dev/null 2>&1; then
    warning "Cluster '${CLUSTER_NAME}' not found. Creating cluster..."
    # Attempt to create the cluster and check for failure immediately
    if ! eksctl create cluster -f "${CLUSTER_FILE}"; then
        error "Failed to create cluster '${CLUSTER_NAME}'"
        exit 1
    fi
    success "Cluster '${CLUSTER_NAME}' created successfully."
else
    success "Cluster '${CLUSTER_NAME}' already exists."
fi

section "Kubernetes Configuration"
info "Writing kubeconfig to ${KUBECONFIG_PATH}"
aws eks update-kubeconfig --region "${CLUSTER_REGION}" --name "${CLUSTER_NAME}" --kubeconfig "${KUBECONFIG_PATH}"
export KUBECONFIG="${KUBECONFIG_PATH}"

kubectl="kubectl --kubeconfig ${KUBECONFIG_PATH}"
${kubectl} apply -f cluster/ebs-storage-class.yaml

section "Cluster Autoscaler Configuration"
# Define template and output file paths
CLUSTER_GPU_NODE_POOL_TEMPLATE="${CLUSTER_DIR}/gpu-node-pool.yaml.template"
CLUSTER_GPU_NODE_POOL_FILE="${CLUSTER_DIR}/gpu-node-pool.yaml"

# Template and apply the GPU node pool
if [ -f "${CLUSTER_GPU_NODE_POOL_TEMPLATE}" ]; then
  info "Generating gpu-node-pool.yaml from template..."

  # Simply use sed to replace the placeholder with the GPU_NODE_TYPES value
  sed "s|\${GPU_NODE_FAMILIES}|${GPU_NODE_FAMILIES}|g" "${CLUSTER_GPU_NODE_POOL_TEMPLATE}" > "${CLUSTER_GPU_NODE_POOL_FILE}"

  success "Created ${CLUSTER_GPU_NODE_POOL_FILE}"

  # Apply the GPU node pool to the cluster
  info "Applying GPU node pool to the cluster..."
  if ${kubectl} apply -f "${CLUSTER_GPU_NODE_POOL_FILE}"; then
    success "GPU node pool applied successfully"
  else
    warning "Failed to apply GPU node pool. Will continue deployment."
  fi
else
  warning "GPU node pool template not found at ${CLUSTER_GPU_NODE_POOL_TEMPLATE}, skipping"
fi

section "DNS Configuration"
# Discover Route53 hosted zone ID for the given domain
info "Discovering Route53 hosted zone ID for ${DNS_ZONE_NAME}..."
HOSTED_ZONE_ID=$(aws route53 list-hosted-zones-by-name \
  --dns-name "${DNS_ZONE_NAME}" \
  --query "HostedZones[?Name=='${DNS_ZONE_NAME}.'].Id" \
  --output text | cut -d'/' -f3)

if [ -z "${HOSTED_ZONE_ID}" ]; then
  error "Could not find Route53 hosted zone ID for ${DNS_ZONE_NAME}"
  exit 1
else
  success "Found hosted zone ID: ${HOSTED_ZONE_ID}"
  # Export it for use in templates
  export HOSTED_ZONE_ID

  # Update the cluster-issuer.yaml template with the discovered ID
  CERT_MANAGER_DIR="helm/cert-manager"
  CLUSTER_ISSUER_TEMPLATE="${CERT_MANAGER_DIR}/cluster-issuer.yaml.template"
  CLUSTER_ISSUER_FILE="${CERT_MANAGER_DIR}/cluster-issuer.yaml"

  if [ -f "${CLUSTER_ISSUER_TEMPLATE}" ]; then
    info "Generating cluster-issuer.yaml from template..."
    # Replace the placeholder with the actual hosted zone ID
    sed "s/HOSTED_ZONE_ID_PLACEHOLDER/${HOSTED_ZONE_ID}/g" "${CLUSTER_ISSUER_TEMPLATE}" > "${CLUSTER_ISSUER_FILE}"
    success "Updated ${CLUSTER_ISSUER_FILE} with hosted zone ID: ${HOSTED_ZONE_ID}"
  fi
fi

section "Helm Deployment"
# Display which context we're using
if [ -n "${KUBE_CONTEXT}" ]; then
  info "Using Kubernetes context: ${KUBE_CONTEXT}"
fi

# Define helmfile path and check if it exists
HELMFILE_PATH="./helmfile.yaml"
if [ ! -f "${HELMFILE_PATH}" ]; then
  warning "Helmfile not found at ${HELMFILE_PATH}"
  error "Deployment cannot continue without helmfile.yaml"
  exit 1
fi

# Pass remaining arguments to helmfile, including context flag if set
info "Applying Helm charts using helmfile..."
if helmfile apply --kubeconfig "${KUBECONFIG_PATH}" -f "${HELMFILE_PATH}"; then
  success "Deployment completed successfully"
else
  error "Helm deployment failed"
  exit 1
fi
