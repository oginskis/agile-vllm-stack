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
DNS_ZONE_NAME="${DNS_ZONE_NAME:-superhub.click}"

# Check if CLUSTER_NAME and CLUSTER_REGION are set, otherwise use defaults
CLUSTER_NAME="${CLUSTER_NAME:-solana-cluster}"
CLUSTER_REGION="${CLUSTER_REGION:-eu-north-1}"

section "Configuration"
info "Cluster name:  ${CLUSTER_NAME}"
info "Region:        ${CLUSTER_REGION}"
info "DNS zone:      ${DNS_ZONE_NAME}"

# Setup kubeconfig if the cluster exists
if eksctl get cluster --name "${CLUSTER_NAME}" --region "${CLUSTER_REGION}" > /dev/null 2>&1; then
    info "Setting up kubeconfig for ${CLUSTER_NAME}"
    aws eks update-kubeconfig --region "${CLUSTER_REGION}" --name "${CLUSTER_NAME}" --kubeconfig "${KUBECONFIG_PATH}"
    export KUBECONFIG="${KUBECONFIG_PATH}"
    kubectl="kubectl --kubeconfig ${KUBECONFIG_PATH}"
else
    warning "Cluster ${CLUSTER_NAME} does not exist, skipping kubeconfig setup"
    kubectl="kubectl" # Set default kubectl command without kubeconfig
    # Don't exit, continue with the rest of the cleanup
fi

section "Helm Undeployment"
# Define helmfile path
HELMFILE_PATH="./helmfile.yaml"

# Check if helmfile exists before attempting to delete
if command -v helmfile > /dev/null 2>&1; then
    if [ -f "${HELMFILE_PATH}" ]; then
        info "Deleting Helm releases using helmfile..."
        # Add check if kubeconfig exists before using it
        if [ -f "${KUBECONFIG_PATH}" ]; then
            if helmfile destroy --kubeconfig "${KUBECONFIG_PATH}" -f "${HELMFILE_PATH}"; then
                success "Helm releases deleted successfully"
            else
                warning "Some helm releases may not have been deleted properly"
            fi
        else
            warning "Kubeconfig not found at ${KUBECONFIG_PATH}, skipping helm releases deletion"
        fi
    else
        warning "Helmfile not found at ${HELMFILE_PATH}, skipping helm releases deletion"
    fi
else
    warning "Helmfile command not found, skipping helm releases deletion"
fi

section "Cluster Deletion"
# Check if the cluster exists before attempting to delete resources within it
if eksctl get cluster --name "${CLUSTER_NAME}" --region "${CLUSTER_REGION}" > /dev/null 2>&1; then
    # Delete Karpenter node pools if they exist
    info "Checking for Karpenter node pools..."
    if ${kubectl} get nodepools gpu-node-pool > /dev/null 2>&1; then
        info "Deleting Karpenter NodePool 'gpu-node-pool'..."
        if ${kubectl} delete nodepool gpu-node-pool; then
            success "NodePool 'gpu-node-pool' deleted successfully"
        else
            warning "Failed to delete NodePool 'gpu-node-pool'"
        fi
    else
        info "NodePool 'gpu-node-pool' not found"
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

    # Check if there are any PVCs to clean up
    info "Checking for PersistentVolumeClaims..."
    if PVC_COUNT=$(${kubectl} get pvc --all-namespaces --no-headers 2>/dev/null | wc -l); then
        PVC_COUNT=$(echo "${PVC_COUNT}" | tr -d '[:space:]')
        if [ "${PVC_COUNT}" -gt 0 ]; then
            info "Found ${PVC_COUNT} PersistentVolumeClaims, attempting to delete..."

            # Get list of namespaces with PVCs using a POSIX-compatible approach
            ${kubectl} get pvc --all-namespaces --no-headers 2>/dev/null |
            while read -r line; do
                ns=$(echo "${line}" | awk '{print $1}')
                info "Deleting PersistentVolumeClaims in namespace ${ns}..."
                if ${kubectl} delete pvc --all -n "${ns}"; then
                    success "Deleted PVCs in namespace ${ns}"
                else
                    warning "Failed to delete some PVCs in namespace ${ns}"
                fi
            done
        else
            info "No PersistentVolumeClaims found, skipping deletion"
        fi
    else
        info "Error checking for PVCs, skipping PVC deletion"
    fi


    # Now delete the cluster
    info "Deleting cluster '${CLUSTER_NAME}'..."
    if eksctl delete cluster --name="${CLUSTER_NAME}" --region="${CLUSTER_REGION}"; then
        success "Cluster '${CLUSTER_NAME}' deleted successfully"
    else
        error "Failed to delete cluster '${CLUSTER_NAME}'"
    fi
else
    info "Cluster '${CLUSTER_NAME}' not found, skipping deletion"
fi

# Clean up local files
section "Local Cleanup"
info "Cleaning up generated files..."
FILES_TO_CLEAN="./kubeconfig ./cluster/gpu-node-pool.yaml ./helm/cert-manager/cluster-issuer.yaml"

for file in ${FILES_TO_CLEAN}; do
    if [ -f "${file}" ]; then
        info "Removing ${file}..."
        rm "${file}"
        success "Removed ${file}"
    fi
done

success "Undeployment completed"
