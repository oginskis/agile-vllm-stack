# LLM Inference Stack

This repository contains infrastructure-as-code (IaC) for deploying and managing an end-to-end open source LLM serving solution on Kubernetes (currently EKS only). The setup provides a scalable environment optimized for deploying and running AI models with GPU support.

## Overview

This infrastructure stack uses:

- **Kubernetes** (currently AWS EKS only) for container orchestration
- **Karpenter** for node auto-provisioning and scaling
- **Helm** and **Helmfile** for application deployment
- **vLLM** for efficient large language model inference
- **Route53** for DNS management
- **cert-manager** for TLS certificate management
- **NGINX Ingress Controller** for traffic management

## Prerequisites

- AWS CLI configured with appropriate permissions
- `eksctl` command-line tool
- `kubectl` command-line tool
- `helm` command-line tool
- `helmfile` command-line tool
- A Route53 DNS zone (specified by `DNS_ZONE_NAME`) that you control
- Sufficient AWS GPU quota in your target region for GPU-enabled instances (g4dn, etc.)

## Configuration

Create a `.env` file in the root directory with the following parameters:

```bash
# Cluster configuration
CLUSTER_NAME=llm-cluster
CLUSTER_REGION=eu-north-1
DNS_ZONE_NAME=example.com

# GPU configuration
GPU_NODE_FAMILIES='["g6e"]'

# Inference configuration
INFERENCE_HOST=inference.example.com
MODEL_SPEC_FILE=./model_specs.yaml

# Authentication
HF_TOKEN=your_huggingface_token
```

### Environment Variables

| Variable | Description | Default |
|----------|-------------|---------|
| `CLUSTER_NAME` | Name of the EKS cluster | `llm-cluster` |
| `CLUSTER_REGION` | AWS region to deploy to | `eu-north-1` |
| `DNS_ZONE_NAME` | Route53 DNS zone name | `example.com` |
| `GPU_NODE_FAMILIES` | JSON array of GPU instance families | `["g4dn"]` |
| `INFERENCE_HOST` | Hostname for the inference endpoint | `inference.${DNS_ZONE_NAME}` |
| `MODEL_SPEC_FILE` | Path to model specifications file | `./model_specs.yaml` |
| `HF_TOKEN` | Hugging Face token for private model access | - |

## Directory Structure

```
infra/
├── cluster/              # Kubernetes cluster configuration
│   ├── cluster.template.yaml
│   ├── cluster.yaml      # Generated from template
│   ├── ebs-storage-class.yaml
│   ├── gpu-node-pool.yaml.template
│   └── gpu-node-pool.yaml # Generated from template
├── helm/                 # Helm chart configurations
│   ├── cert-manager/
│   │   ├── cluster-issuer.yaml.template
│   │   └── cluster-issuer.yaml # Generated from template
│   └── vllm-router/
│       └── values.yaml.gotmpl
├── deploy.sh             # Deployment script
├── undeploy.sh           # Clean-up script
├── helmfile.yaml         # Helmfile for chart deployments
├── kubeconfig            # Generated during deployment
└── model-specs.yaml      # LLM model specifications
```

## Model Configuration

The `model-specs.yaml` file defines the language models to be deployed:

```yaml
- name: llama3-8b
  repository: vllm/vllm-openai
  tag: v0.8.4
  modelURL: meta-llama/Llama-3.1-8B-Instruct
  replicaCount: 1
  requestCPU: 3
  requestMemory: 16Gi
  requestGPU: 1
  tolerations:
  - key: "nvidia.com/gpu"
    operator: "Exists"
    effect: "NoSchedule"
  pvcStorage: 50Gi
  storageClass: ebs-sc
  vllmConfig:
    enableChunkedPrefill: false
    enablePrefixCaching: false
    maxModelLen: 16384
    dtype: bfloat16
    extraArgs: ["--disable-log-requests", "--gpu-memory-utilization", "0.8"]
  hf_token: {{ env "HF_TOKEN" | default "" }}
```

## Deployment Process

### 1. Deploy the Infrastructure

Before running the deployment script, ensure you have an active AWS session:

```bash
# If using AWS SSO
aws sso login

# Or ensure your AWS credentials are properly configured
aws sts get-caller-identity
```

Then run the deployment script:

```bash
./deploy.sh
```

The deployment script performs the following steps:

1. Loads environment variables from `.env`
2. Renders templates (`cluster.yaml`, `gpu-node-pool.yaml`, `cluster-issuer.yaml`)
3. Creates an EKS cluster if it doesn't exist
4. Configures kubeconfig for cluster access
5. Sets up EBS storage class
6. Configures GPU node pools with Karpenter
7. Sets up Route53 DNS integration
8. Deploys Helm charts:
   - NGINX Ingress Controller
   - External DNS
   - cert-manager
   - vLLM Router

### 2. Access the Cluster

```bash
export KUBECONFIG="./kubeconfig"
kubectl get nodes
```

### 3. Undeploy the Infrastructure

```bash
./undeploy.sh
```

The undeployment script:

1. Removes all Helm releases
2. Deletes Karpenter node pools
3. Cleans up EBS storage and PVCs
4. Deletes the EKS cluster
5. Removes generated files

## Helm Charts

The infrastructure includes the following Helm chart deployments:

1. **NGINX Ingress Controller** - Provides L7 load balancing and routing
2. **External DNS** - Automatically manages DNS records in Route53
3. **cert-manager** - Manages TLS certificates for HTTPS
4. **vLLM Stack** - Deploys the vLLM inference server with OpenAI-compatible API

## Inference API

After deployment, models are accessible through the vLLM API endpoint:

```
https://{INFERENCE_HOST}/v1/chat/completions
```

Example curl command:

```bash
curl -X POST \
  https://{INFERENCE_HOST}/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{
    "model": "llama3-8b",
    "messages": [
      {"role": "user", "content": "Hello, how are you?"}
    ]
  }'
```

## Troubleshooting

### Common Issues

1. **DNS Resolution Problems**
   - Verify that the Route53 hosted zone exists
   - Check External DNS pod logs: `kubectl logs -n kube-system -l app.kubernetes.io/name=external-dns`

2. **Certificate Issues**
   - Check cert-manager logs: `kubectl logs -n cert-manager -l app=cert-manager`
   - Verify the ClusterIssuer: `kubectl get clusterissuer -o yaml`

3. **vLLM Deployment Issues**
   - Check pod status: `kubectl get pods -n vllm`
   - View pod logs: `kubectl logs -n vllm -l app=vllm`

## Security Notes

- The infrastructure uses IAM roles for service accounts (IRSA) for secure pod identity
- TLS certificates are automatically provisioned and renewed by cert-manager
- GPU nodes have specific security groups and IAM roles

## Contributing

When contributing to this repository, please follow these guidelines:

1. Update templates rather than generated files
2. Test changes in a separate environment before merging
3. Document significant changes in this README

## License

[Specify the appropriate license for your repository]