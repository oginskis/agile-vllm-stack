#!/bin/sh

# Source .env file
# shellcheck disable=SC1091
. ./.env

export KUBECONFIG="${KUBE_CONFIG:-/path/to/your/kubeconfig}"
KUBE_CONTEXT="${KUBE_CONTEXT:-your-default-context}"
NAMESPACE="${NAMESPACE:-default}"

echo "Undeploying vLLM stack from namespace: ${NAMESPACE}"

kubectl config use-context "${KUBE_CONTEXT}"

# Uninstall Helm release
helm uninstall vllm -n "${NAMESPACE}" 2>/dev/null || echo "vLLM release not found"

# Delete secret
kubectl delete secret vllm-stack-secret -n "${NAMESPACE}" 2>/dev/null || echo "Secret not found"

# Delete only vLLM-related PVCs
# kubectl delete pvc -n "${NAMESPACE}" -l app.kubernetes.io/instance=vllm 2>/dev/null || echo "No vLLM PVCs found"

echo "Undeployment complete"