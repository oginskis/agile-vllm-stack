#!/bin/sh

# Source .env file
# shellcheck disable=SC1091
. ./.env

export KUBECONFIG="${KUBE_CONFIG:-/path/to/your/kubeconfig}"
KUBE_CONTEXT="${KUBE_CONTEXT:-your-default-context}"

kubectl config use-context "${KUBE_CONTEXT}"

# Set the namespace variable, or read from .env if defined there
NAMESPACE="${NAMESPACE:-default}"
HF_TOKEN="${HF_TOKEN:-}"

echo "Using namespace: ${NAMESPACE}"
echo "Using kubeconfig: ${KUBECONFIG}"
echo "Using kube context: ${KUBE_CONTEXT}"

kubectl create secret generic vllm-stack-secret --from-literal=HF_TOKEN="${HF_TOKEN}" -n "${NAMESPACE}" --dry-run=client -o yaml | kubectl -n "${NAMESPACE}" apply -f -

helm repo add vllm https://vllm-project.github.io/production-stack
# helm repo update
helm upgrade --install vllm vllm/vllm-stack -f helm/vllm-router/values.yaml -n "${NAMESPACE}"
