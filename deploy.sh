#!/bin/sh
# filepath: /Users/oginskis/solana-2025/infra/deploy.sh
#
# Cloud Infrastructure Deployment Script
# This script performs idempotent deployment of the infrastructure stack on AWS EKS.
#

# --------------------------------------------------------------------------
# Color formatting and logging functions
# --------------------------------------------------------------------------
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

# --------------------------------------------------------------------------
# Cleanup and error handling
# --------------------------------------------------------------------------
cleanup() {
  # Add cleanup logic here if needed
  :
}

# Set up trap for error handling
trap cleanup EXIT

# --------------------------------------------------------------------------
# Environment setup and validation
# --------------------------------------------------------------------------
section "Environment Setup"

# Current directory for consistent path references
SCRIPT_DIR=$(pwd)

# Load environment variables from .env file
if [ -f .env ]; then
    info "Loading environment variables from .env file"
    # shellcheck disable=SC1091
    . ./.env
    info "Environment variables loaded"
else
    error "ERROR: .env file not found!"
    exit 1
fi

# Define critical paths
KUBECONFIG_PATH="${SCRIPT_DIR}/kubeconfig"
CLUSTER_DIR="${SCRIPT_DIR}/cluster"
CLUSTER_TEMPLATE="${CLUSTER_DIR}/cluster.yaml.template"
CLUSTER_FILE="${CLUSTER_DIR}/cluster.yaml"
CLUSTER_GPU_NODE_POOL_TEMPLATE="${CLUSTER_DIR}/gpu-node-pool.yaml.template"
CLUSTER_GPU_NODE_POOL_FILE="${CLUSTER_DIR}/gpu-node-pool.yaml"
CERT_MANAGER_DIR="${SCRIPT_DIR}/helm/cert-manager"
CLUSTER_ISSUER_TEMPLATE="${CERT_MANAGER_DIR}/cluster-issuer.yaml.template"
CLUSTER_ISSUER_FILE="${CERT_MANAGER_DIR}/cluster-issuer.yaml"
HELMFILE_PATH="${SCRIPT_DIR}/helmfile.yaml"

# Set default values for required variables
# DNS_ZONE_NAME is no longer given a default value, making it truly optional
CLUSTER_NAME="${CLUSTER_NAME:-eks-cluster}"
CLUSTER_REGION="${CLUSTER_REGION:-eu-north-1}"
GPU_NODE_FAMILIES="${GPU_NODE_FAMILIES:-'[\"g4dn\"]'}"

# Set INFERENCE_HOST only if DNS_ZONE_NAME is provided
if [ -n "${DNS_ZONE_NAME}" ]; then
  INFERENCE_HOST="${INFERENCE_HOST:-inference.${DNS_ZONE_NAME}}"
fi

# Validate and set MODEL_SPEC_FILE path (ensure it's absolute)
MODEL_SPEC_FILE="${MODEL_SPEC_FILE:-${SCRIPT_DIR}/model-specs.yaml}"
case "${MODEL_SPEC_FILE}" in
  /*) : ;; # Path is already absolute
  *) MODEL_SPEC_FILE="${SCRIPT_DIR}/${MODEL_SPEC_FILE}" ;; # Make path absolute
esac

# Check if MODEL_SPEC_FILE exists
if [ ! -f "${MODEL_SPEC_FILE}" ]; then
  error "Model spec file not found at ${MODEL_SPEC_FILE}"
  exit 1
fi

# Check prerequisites
for cmd in kubectl eksctl aws helmfile helm; do
  if ! command -v "${cmd}" > /dev/null 2>&1; then
    error "Required command not found: ${cmd}"
    exit 1
  fi
done

# Check AWS CLI credentials
if ! aws sts get-caller-identity > /dev/null 2>&1; then
  error "AWS CLI not configured correctly. Please run 'aws configure'"
  exit 1
fi

# Export required variables for helm charts
export INFERENCE_HOST
export NGINX_INGRESS_NAMESPACE
export EXTERNAL_DNS_NAMESPACE
export CERT_MANAGER_NAMESPACE
export VLLM_STACK_NAMESPACE
export PROMETHEUS_NAMESPACE

export NGINX_INGRESS_VERSION
export EXTERNAL_DNS_VERSION
export CERT_MANAGER_VERSION
export VLLM_STACK_VERSION
export PROMETHEUS_STACK_VERSION
export PROMETHEUS_ADAPTER_VERSION
export GPU_EXPORTER_VERSION

export PROMETHEUS_HOST
export MONITORING_HOST
export MODEL_SPEC_FILE
export GRAFANA_PASSWORD
export HF_TOKEN

# --------------------------------------------------------------------------
# Configuration display
# --------------------------------------------------------------------------
section "Configuration"
info "Cluster name:         ${CLUSTER_NAME}"
info "Region:               ${CLUSTER_REGION}"
info "GPU nodes families:   ${GPU_NODE_FAMILIES}"
info "DNS zone:             ${DNS_ZONE_NAME}"
info "Model spec file:      ${MODEL_SPEC_FILE}"

# --------------------------------------------------------------------------
# Cluster configuration
# --------------------------------------------------------------------------
section "Cluster Configuration"

# Create cluster directory if it doesn't exist
if [ ! -d "${CLUSTER_DIR}" ]; then
  mkdir -p "${CLUSTER_DIR}"
fi

# Create cluster.yaml from template if it exists
if [ -f "${CLUSTER_TEMPLATE}" ]; then
  info "Generating cluster.yaml from template..."

  # Replace the placeholders with the actual values
  sed -e "s/CLUSTER_NAME_PLACEHOLDER/${CLUSTER_NAME}/g" \
      -e "s/CLUSTER_REGION_PLACEHOLDER/${CLUSTER_REGION}/g" \
      "${CLUSTER_TEMPLATE}" > "${CLUSTER_FILE}"

  success "Updated ${CLUSTER_FILE} with name: ${CLUSTER_NAME}, region: ${CLUSTER_REGION}"
else
  warning "Cluster template not found at ${CLUSTER_TEMPLATE}. Will continue with existing cluster."
fi

# --------------------------------------------------------------------------
# Cluster creation or validation
# --------------------------------------------------------------------------
section "Cluster Management"

# Check if the cluster already exists
info "Checking if cluster '${CLUSTER_NAME}' exists in region '${CLUSTER_REGION}'..."

if eksctl get cluster --name "${CLUSTER_NAME}" --region "${CLUSTER_REGION}" > /dev/null 2>&1; then
  success "Cluster '${CLUSTER_NAME}' already exists."
else
  warning "Cluster '${CLUSTER_NAME}' not found. Creating cluster..."

  # Validate cluster file exists before attempting to create
  if [ ! -f "${CLUSTER_FILE}" ]; then
    error "Cluster definition file ${CLUSTER_FILE} not found."
    exit 1
  fi

  # Create the cluster - one attempt only
  info "Creating cluster '${CLUSTER_NAME}' in region '${CLUSTER_REGION}'..."
  if eksctl create cluster -f "${CLUSTER_FILE}"; then
    success "Cluster '${CLUSTER_NAME}' created successfully."
  else
    error "Failed to create cluster '${CLUSTER_NAME}'. Please check logs for details."
    exit 1
  fi
fi

# --------------------------------------------------------------------------
# Kubernetes configuration
# --------------------------------------------------------------------------
section "Kubernetes Configuration"

# Update kubeconfig
info "Writing kubeconfig to ${KUBECONFIG_PATH}"
if ! aws eks update-kubeconfig --region "${CLUSTER_REGION}" --name "${CLUSTER_NAME}" --kubeconfig "${KUBECONFIG_PATH}"; then
  error "Failed to update kubeconfig"
  exit 1
fi

# Set KUBECONFIG environment variable
export KUBECONFIG="${KUBECONFIG_PATH}"

# Define kubectl with kubeconfig option for consistent usage
kubectl="kubectl --kubeconfig ${KUBECONFIG_PATH}"

# Check if ebs-storage-class.yaml exists before applying
if [ -f "${CLUSTER_DIR}/ebs-storage-class.yaml" ]; then
  # Apply storage class idempotently
  info "Applying EBS storage class configuration..."
  if ${kubectl} apply -f "${CLUSTER_DIR}/ebs-storage-class.yaml"; then
    success "EBS storage class configured"
  else
    error "Failed to apply EBS storage class configuration"
    exit 1
  fi
else
  warning "EBS storage class file not found. Skipping."
fi

# --------------------------------------------------------------------------
# GPU Node Pool Configuration
# --------------------------------------------------------------------------
section "GPU Node Pool Configuration"

# Generate and apply GPU node pool configuration
if [ -f "${CLUSTER_GPU_NODE_POOL_TEMPLATE}" ]; then
  info "Generating GPU node pool configuration from template..."

  # Ensure directory exists
  if [ ! -d "$(dirname "${CLUSTER_GPU_NODE_POOL_FILE}")" ]; then
    mkdir -p "$(dirname "${CLUSTER_GPU_NODE_POOL_FILE}")"
  fi

  # Generate GPU node pool file
  sed "s|\${GPU_NODE_FAMILIES}|${GPU_NODE_FAMILIES}|g" \
    "${CLUSTER_GPU_NODE_POOL_TEMPLATE}" > "${CLUSTER_GPU_NODE_POOL_FILE}"

  success "Created ${CLUSTER_GPU_NODE_POOL_FILE}"

  # Apply the GPU node pool to the cluster (idempotent operation)
  info "Applying GPU node pool to the cluster..."
  if ${kubectl} apply -f "${CLUSTER_GPU_NODE_POOL_FILE}"; then
    success "GPU node pool applied successfully"
  else
    warning "Failed to apply GPU node pool. Will continue deployment."
  fi
else
  warning "GPU node pool template not found at ${CLUSTER_GPU_NODE_POOL_TEMPLATE}, skipping"
fi

# --------------------------------------------------------------------------
# DNS Configuration
# --------------------------------------------------------------------------
section "DNS Configuration"

if [ -n "${DNS_ZONE_NAME}" ]; then
  # Discover Route53 hosted zone ID for the given domain
  info "Discovering Route53 hosted zone ID for ${DNS_ZONE_NAME}..."
  HOSTED_ZONE_ID=$(aws route53 list-hosted-zones-by-name \
    --dns-name "${DNS_ZONE_NAME}" \
    --query "HostedZones[?Name=='${DNS_ZONE_NAME}.'].Id" \
    --output text | cut -d'/' -f3)

  if [ -z "${HOSTED_ZONE_ID}" ]; then
    error "Could not find Route53 hosted zone ID for ${DNS_ZONE_NAME}"
    exit 1
  fi

  success "Found hosted zone ID: ${HOSTED_ZONE_ID}"
  export HOSTED_ZONE_ID

  # Create cert-manager directory if it doesn't exist
  if [ ! -d "${CERT_MANAGER_DIR}" ]; then
    mkdir -p "${CERT_MANAGER_DIR}"
  fi

  # Update the cluster-issuer.yaml template with the discovered ID
  if [ -f "${CLUSTER_ISSUER_TEMPLATE}" ]; then
    info "Generating cluster-issuer.yaml from template..."

    # Replace the placeholder with the actual hosted zone ID
    sed "s/HOSTED_ZONE_ID_PLACEHOLDER/${HOSTED_ZONE_ID}/g" \
      "${CLUSTER_ISSUER_TEMPLATE}" > "${CLUSTER_ISSUER_FILE}"

    success "Updated ${CLUSTER_ISSUER_FILE} with hosted zone ID: ${HOSTED_ZONE_ID}"
  else
    warning "Cluster issuer template not found at ${CLUSTER_ISSUER_TEMPLATE}"
  fi
else
  warning "DNS_ZONE_NAME not set. Skipping DNS configuration and related components (nginx, external-dns, cert-manager)."
fi

# --------------------------------------------------------------------------
# Helm Deployment
# --------------------------------------------------------------------------
section "Helm Deployment"

# Check if helmfile exists
if [ ! -f "${HELMFILE_PATH}" ]; then
  error "Helmfile not found at ${HELMFILE_PATH}"
  exit 1
fi

# Update helm repositories
info "Updating Helm repositories..."
if ! helm repo update; then
  warning "Failed to update Helm repositories. Continuing anyway..."
fi

# Apply Helm charts using helmfile
info "Applying Helm charts using helmfile..."
if helmfile sync --kubeconfig "${KUBECONFIG_PATH}" -f "${HELMFILE_PATH}"; then
  success "Deployment completed successfully"
else
  error "Helm deployment failed"
  exit 1
fi

# --------------------------------------------------------------------------
# Deployment validation
# --------------------------------------------------------------------------
section "Deployment Validation"

if [ -n "${DNS_ZONE_NAME}" ]; then
  # Wait for key services to be ready
  info "Waiting for ingress controller to be ready..."
  ${kubectl} wait --namespace "${NGINX_INGRESS_NAMESPACE:-ingress-nginx}" \
    --for=condition=ready pod \
    --selector=app.kubernetes.io/component=controller \
    --timeout=180s || warning "Timed out waiting for ingress controller"

  # Validate HTTPS endpoints
  info "You can manually verify services at:"
  info "- Inference API: https://${INFERENCE_HOST}"
  info "- Grafana: https://${MONITORING_HOST:-monitoring.${DNS_ZONE_NAME}}"
  info "- Prometheus: https://${PROMETHEUS_HOST:-prometheus.${DNS_ZONE_NAME}}"
else
  info "DNS_ZONE_NAME not set. No ingress or DNS endpoints were deployed."
  info "Access services using port-forwarding or cluster-internal endpoints."
fi

section "Deployment Complete"
success "Infrastructure has been deployed successfully!"
info "Use 'kubectl --kubeconfig ${KUBECONFIG_PATH} get pods -A' to check system status"
