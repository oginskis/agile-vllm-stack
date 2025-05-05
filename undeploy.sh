#!/bin/sh
# Cloud Infrastructure Undeployment Script
# This script performs undeploy operations in the reverse order of deployment
# to ensure clean removal of all resources.
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
CLUSTER_GPU_NODE_POOL_FILE="${CLUSTER_DIR}/gpu-node-pool.yaml"
CERT_MANAGER_DIR="${SCRIPT_DIR}/helm/cert-manager"
CLUSTER_ISSUER_FILE="${CERT_MANAGER_DIR}/cluster-issuer.yaml"
HELMFILE_PATH="${SCRIPT_DIR}/helmfile.yaml"

# Set default values for required variables
DNS_ZONE_NAME="${DNS_ZONE_NAME:-superhub.click}"
CLUSTER_NAME="${CLUSTER_NAME:-eks-cluster}"
CLUSTER_REGION="${CLUSTER_REGION:-eu-north-1}"

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

# --------------------------------------------------------------------------
# Configuration display
# --------------------------------------------------------------------------
section "Configuration"
info "Cluster name:         ${CLUSTER_NAME}"
info "Region:               ${CLUSTER_REGION}"
info "DNS zone:             ${DNS_ZONE_NAME}"

# --------------------------------------------------------------------------
# 1. First, setup kubeconfig (required for accessing the cluster)
# --------------------------------------------------------------------------
section "Kubernetes Configuration"

# Check if the cluster exists before attempting to set up kubeconfig
if eksctl get cluster --name "${CLUSTER_NAME}" --region "${CLUSTER_REGION}" > /dev/null 2>&1; then
  info "Setting up kubeconfig for ${CLUSTER_NAME}"
  aws eks update-kubeconfig --region "${CLUSTER_REGION}" --name "${CLUSTER_NAME}" --kubeconfig "${KUBECONFIG_PATH}"
  export KUBECONFIG="${KUBECONFIG_PATH}"
  kubectl="kubectl --kubeconfig ${KUBECONFIG_PATH}"
  success "Kubeconfig updated for cluster ${CLUSTER_NAME}"
else
  warning "Cluster ${CLUSTER_NAME} does not exist, skipping kubeconfig setup"
  kubectl="kubectl" # Set default kubectl command without kubeconfig
  # Don't exit, continue with the rest of the cleanup
fi

# --------------------------------------------------------------------------
# 2. Undeployment of Helm charts (reverse order from deployment)
# --------------------------------------------------------------------------
section "Helm Undeployment"

# Check if helmfile exists
if [ -f "${HELMFILE_PATH}" ]; then
  info "Deleting Helm releases using helmfile..."
  # Add check if kubeconfig exists before using it
  if [ -f "${KUBECONFIG_PATH}" ]; then
    if helmfile destroy --kubeconfig "${KUBECONFIG_PATH}" -f "${HELMFILE_PATH}"; then
      success "Helm releases deleted successfully"
    else
      warning "Some Helm releases may not have been deleted properly"
      # Continue anyway, as we want to clean up as much as possible
    fi
  else
    warning "Kubeconfig not found at ${KUBECONFIG_PATH}, skipping Helm releases deletion"
  fi
else
  warning "Helmfile not found at ${HELMFILE_PATH}, skipping Helm releases deletion"
fi

# --------------------------------------------------------------------------
# 3. Remove cluster resources (GPU node pool, storage class)
# --------------------------------------------------------------------------
section "Cluster Resources Cleanup"

# Check if the cluster exists before attempting to delete resources
if eksctl get cluster --name "${CLUSTER_NAME}" --region "${CLUSTER_REGION}" > /dev/null 2>&1; then
  # Delete GPU node pool if it exists
  if ${kubectl} get nodepools gpu-node-pool > /dev/null 2>&1; then
    info "Deleting Karpenter NodePool 'gpu-node-pool'..."
    if ${kubectl} delete nodepool gpu-node-pool; then
      success "NodePool 'gpu-node-pool' deleted successfully"
    else
      warning "Failed to delete NodePool 'gpu-node-pool'"
    fi
  else
    info "NodePool 'gpu-node-pool' not found, skipping"
  fi

  # Delete EBS storage class
  if ${kubectl} get storageclass ebs-sc > /dev/null 2>&1; then
    info "Deleting EBS storage class..."
    if ${kubectl} delete storageclass ebs-sc; then
      success "EBS storage class deleted successfully"
    else
      warning "Failed to delete EBS storage class"
    fi
  else
    info "EBS storage class not found, skipping deletion"
  fi

  # Check for and delete any PVCs
  info "Checking for PersistentVolumeClaims..."
  PVC_COUNT=$(${kubectl} get pvc --all-namespaces --no-headers 2>/dev/null | wc -l | tr -d '[:space:]')
  if [ "${PVC_COUNT}" -gt 0 ] 2>/dev/null; then
    info "Found ${PVC_COUNT} PersistentVolumeClaims, attempting to delete..."

    # Get list of namespaces with PVCs
    ${kubectl} get pvc --all-namespaces --no-headers 2>/dev/null |
    while read -r line; do
      ns=$(echo "${line}" | awk '{print $1}')
      pvc=$(echo "${line}" | awk '{print $2}')
      info "Deleting PVC ${pvc} in namespace ${ns}..."
      if ${kubectl} delete pvc "${pvc}" -n "${ns}" --timeout=60s; then
        success "Deleted PVC ${pvc} in namespace ${ns}"
      else
        warning "Failed to delete PVC ${pvc} in namespace ${ns}"
      fi
    done
  else
    info "No PersistentVolumeClaims found, skipping deletion"
  fi
fi

# --------------------------------------------------------------------------
# 4. Delete the cluster (last deployed, first removed)
# --------------------------------------------------------------------------
section "Cluster Deletion"

# Check if the cluster exists before attempting to delete
if eksctl get cluster --name "${CLUSTER_NAME}" --region "${CLUSTER_REGION}" > /dev/null 2>&1; then
  info "Deleting cluster '${CLUSTER_NAME}'..."
  if eksctl delete cluster --name="${CLUSTER_NAME}" --region="${CLUSTER_REGION}"; then
    success "Cluster '${CLUSTER_NAME}' deleted successfully"
  else
    error "Failed to delete cluster '${CLUSTER_NAME}'"
    # Don't exit, continue with local cleanup
  fi
else
  info "Cluster '${CLUSTER_NAME}' not found, skipping deletion"
fi

# --------------------------------------------------------------------------
# 5. Clean up local files
# --------------------------------------------------------------------------
section "Local Cleanup"

info "Cleaning up generated files..."
FILES_TO_CLEAN="${KUBECONFIG_PATH} ${CLUSTER_GPU_NODE_POOL_FILE} ${CLUSTER_ISSUER_FILE}"

for file in ${FILES_TO_CLEAN}; do
  if [ -f "${file}" ]; then
    info "Removing ${file}..."
    rm "${file}"
    success "Removed ${file}"
  else
    info "File ${file} not found, skipping"
  fi
done

section "Undeployment Complete"
success "Infrastructure has been successfully undeployed!"
