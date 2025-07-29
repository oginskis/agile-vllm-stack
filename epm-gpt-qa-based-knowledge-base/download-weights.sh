#!/bin/sh

# Download model weights to persistent storage

# Source .env file
# shellcheck disable=SC1091
. ./.env

export KUBECONFIG="${KUBE_CONFIG:-/path/to/your/kubeconfig}"
KUBE_CONTEXT="${KUBE_CONTEXT:-your-default-context}"
NAMESPACE="${NAMESPACE:-default}"


MODEL="${MODEL:-meta-llama/Llama-3.2-3B-Instruct}"
# MODEL="${MODEL:-Qwen/Qwen3-32B-AWQ}"

# Derive resource names from MODEL
MODEL_NAME=$(echo "${MODEL}" | tr '/' '-' | tr '[:upper:]' '[:lower:]')
PVC_NAME="${MODEL_NAME}-pvc"
JOB_NAME="download-${MODEL_NAME}"

kubectl config use-context "${KUBE_CONTEXT}"

echo "=============================================="
echo "vLLM Model Weight Download Script"
echo "=============================================="
echo "Purpose: Downloads model weights to persistent storage for vLLM deployment"
echo "This script creates PVCs, downloads models via Kubernetes job, and labels PVs for reuse"
echo ""
echo "Configuration:"
echo "  Model: ${MODEL}"
echo "  Namespace: ${NAMESPACE}"
echo "  Context: ${KUBE_CONTEXT}"
echo "  Derived name: ${MODEL_NAME}"
echo "=============================================="

# Check PVC and create if needed
echo "Checking for existing PVC: ${PVC_NAME}"
if kubectl get pvc "${PVC_NAME}" -n "${NAMESPACE}" 2>/dev/null | grep -q Bound; then
    echo "✓ PVC ${PVC_NAME} already exists and is bound"
else
    echo "Creating new PVC: ${PVC_NAME}"
    kubectl apply -f - <<EOF
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: ${PVC_NAME}
  namespace: ${NAMESPACE}
spec:
  accessModes:
    - ReadWriteOnce
  storageClassName: premium-rwo
  resources:
    requests:
      storage: 100Gi
EOF
fi

# Check if PV for this model already exists
echo "Checking for existing PV with model label: ${MODEL_NAME}"
PV_NAME=$(kubectl get pv -l model="${MODEL_NAME}" --no-headers 2>/dev/null | awk '{print $1}' | head -1)
if [ -n "${PV_NAME}" ]; then
    echo "✓ Model ${MODEL_NAME} already exists in PV: ${PV_NAME}"
    echo "✓ Model weights are ready for use"
else
    # Delete existing job if present
    echo "Cleaning up any existing download job: ${JOB_NAME}"
    kubectl delete job "${JOB_NAME}" -n "${NAMESPACE}" 2>/dev/null || true

    # Create and start download job
    echo "Creating download job for model: ${MODEL}"
    kubectl apply -f - <<EOF
apiVersion: batch/v1
kind: Job
metadata:
  name: ${JOB_NAME}
  namespace: ${NAMESPACE}
spec:
  template:
    spec:
      restartPolicy: OnFailure
      containers:
      - name: model-downloader
        image: python:3.11-slim
        command: ["/bin/sh", "-c"]
        args:
          - |
            pip install -U huggingface-hub
            export HF_HUB_CACHE=/models/cache
            mkdir -p \$HF_HUB_CACHE
            hf download ${MODEL} --cache-dir \$HF_HUB_CACHE --local-dir /models/${MODEL_NAME}
            echo "Download completed at \$(date)" > /models/${MODEL_NAME}/.download_complete
        env:
        - name: HF_TOKEN
          valueFrom:
            secretKeyRef:
              name: vllm-stack-secret
              key: HF_TOKEN
              optional: true
        volumeMounts:
        - name: model-storage
          mountPath: /models
        resources:
          requests:
            memory: "8Gi"
            cpu: "2"
          limits:
            memory: "12Gi"
            cpu: "4"
      volumes:
      - name: model-storage
        persistentVolumeClaim:
          claimName: ${PVC_NAME}
EOF

    # Wait for pod to start and tail logs
    echo "Waiting for download job pod to start..."
    kubectl wait --for=condition=ready pod -l job-name="${JOB_NAME}" -n "${NAMESPACE}" --timeout=300s

    # Tail logs while job runs
    echo "Streaming download logs..."
    kubectl logs -n "${NAMESPACE}" job/"${JOB_NAME}" -f &
    LOG_PID=$!

    # Wait for completion
    echo "Waiting for download to complete (timeout: 3600s)..."
    kubectl wait --for=condition=complete job/"${JOB_NAME}" -n "${NAMESPACE}" --timeout=3600s

    # Stop tailing logs
    kill "${LOG_PID}" 2>/dev/null || true

    # Get PV name and label it
    echo "Retrieving PV information and applying model label..."
    PV_NAME=$(kubectl get pvc "${PVC_NAME}" -n "${NAMESPACE}" -o jsonpath='{.spec.volumeName}')
    if [ -n "${PV_NAME}" ]; then
        kubectl label pv "${PV_NAME}" model="${MODEL_NAME}" --overwrite
        echo "✓ PV ${PV_NAME} labeled with model=${MODEL_NAME}"
    else
        echo "⚠ Warning: Could not find PV name from PVC"
    fi

    # Clean up job only
    echo "Cleaning up download job..."
    kubectl delete job "${JOB_NAME}" -n "${NAMESPACE}" 2>/dev/null || true
fi

# Create ReadOnlyMany PVC using volume cloning
READONLY_PVC_NAME="${MODEL_NAME}-readonly"
echo "Checking for existing ReadOnlyMany PVC: ${READONLY_PVC_NAME}"
if kubectl get pvc "${READONLY_PVC_NAME}" -n "${NAMESPACE}" 2>/dev/null | grep -q Bound; then
    echo "✓ ReadOnlyMany PVC ${READONLY_PVC_NAME} already exists and is bound"
else
    echo "Creating ReadOnlyMany PVC for model server replicas: ${READONLY_PVC_NAME}"
    kubectl apply -f - <<EOF
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: ${READONLY_PVC_NAME}
  namespace: ${NAMESPACE}
spec:
  accessModes:
    - ReadOnlyMany
  storageClassName: premium-rwo
  dataSource:
    kind: PersistentVolumeClaim
    name: ${PVC_NAME}
  resources:
    requests:
      storage: 100Gi
EOF

fi

echo "=============================================="
echo "Download Complete - Summary"
echo "=============================================="
echo "✓ Model weights stored in PV: ${PV_NAME}"
echo "✓ PV labeled with model: ${MODEL_NAME}"
echo "✓ Original PVC (ReadWriteOnce): ${PVC_NAME}"
echo "✓ ReadOnlyMany PVC for replicas: ${READONLY_PVC_NAME}"
echo "✓ Use modelURL: /models/${MODEL_NAME}"
echo "=============================================="
