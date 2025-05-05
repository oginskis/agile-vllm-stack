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
- **Prometheus & Grafana** for comprehensive monitoring and observability
- **Prometheus Adapter** for custom metrics and scaling

## Prerequisites

- AWS CLI configured with appropriate permissions
- `eksctl` command-line tool
- `kubectl` command-line tool
- `helm` command-line tool
- `helmfile` command-line tool
- A Route53 DNS zone (specified by `DNS_ZONE_NAME`) that you control (optional)
- Sufficient AWS GPU quota in your target region for GPU-enabled instances (g4dn, g6e, etc.)

> **Note:** If `DNS_ZONE_NAME` is not specified, the NGINX Ingress Controller, External-DNS, and cert-manager components will not be provisioned. This is useful if you don't have a Route53 zone under your control. In this case, you'll need to access your services through Kubernetes port-forwarding or another method.

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

# Monitoring configuration
PROMETHEUS_HOST=prometheus.example.com
MONITORING_HOST=monitoring.example.com
GRAFANA_PASSWORD=your_secure_password

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
| `PROMETHEUS_HOST` | Hostname for Prometheus access | `prometheus.${DNS_ZONE_NAME}` |
| `MONITORING_HOST` | Hostname for Grafana dashboards | `monitoring.${DNS_ZONE_NAME}` |
| `GRAFANA_PASSWORD` | Password for Grafana admin user | - |
| `PROMETHEUS_NAMESPACE` | Namespace for monitoring components | `monitoring` |
| `PROMETHEUS_STACK_VERSION` | Version of kube-prometheus-stack | `71.1.0` |
| `PROMETHEUS_ADAPTER_VERSION` | Version of prometheus-adapter | `4.14.1` |

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
│   ├── kube-prom-stack/
│   │   ├── values.yaml.gotmpl
│   │   └── dashboards/
│   │       └── vllm-dashboard.yaml
│   ├── prometheus-adapter/
│   │   └── values.yaml.gotmpl
│   └── vllm-router/
│       └── values.yaml.gotmpl
├── deploy.sh             # Deployment script
├── undeploy.sh           # Clean-up script
├── helmfile.yaml         # Helmfile for chart deployments
├── kubeconfig            # Generated during deployment
└── model-specs.yaml      # LLM model specifications
```

## Model Configuration

The `model-specs.yaml` file defines the language models to be deployed. Current models include:

- **Llama 3.1 8B Instruct** - Meta's latest 8B parameter instruction-tuned model
- **Mistral 7B Instruct v0.3** - Mistral AI's 7B parameter instruction-tuned model

Example model configuration:

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

The `deploy.sh` script is idempotent, which means you can modify the `model-specs.yaml` file to add new models or remove existing ones, then run `deploy.sh` again to apply those changes. Additional models will be deployed or removed based on your modifications without disrupting the overall infrastructure.

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
   - Prometheus Stack (kube-prometheus-stack)
   - Prometheus Adapter
   - Custom dashboards

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
5. **kube-prometheus-stack** - Comprehensive monitoring solution with Prometheus and Grafana
6. **prometheus-adapter** - Enables custom metrics for Kubernetes HPA

## Monitoring and Observability

The stack includes a comprehensive monitoring solution based on Prometheus and Grafana:

- **Prometheus** is deployed via kube-prometheus-stack and collects metrics from all components
- **Grafana** provides visualization of metrics with pre-configured dashboards
- **vLLM Dashboard** helps monitor inference performance, throughput, and GPU utilization
- **Prometheus Adapter** enables scaling based on custom metrics like inference latency or throughput

Access the monitoring interfaces at:
- Grafana: `https://{MONITORING_HOST}` (login with admin and your configured password)
- Prometheus: `https://{PROMETHEUS_HOST}`

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

## GPU Support

The infrastructure now supports the latest AWS GPU instances, including the g6e family which offers improved performance for LLM workloads. Configure your preferred GPU instance families in the `.env` file.

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

4. **Monitoring Issues**
   - Check Prometheus pods: `kubectl get pods -n monitoring`
   - Check Grafana access: `kubectl port-forward -n monitoring svc/kube-prom-stack-grafana 3000:80`

## Security Notes

- The infrastructure uses IAM roles for service accounts (IRSA) for secure pod identity
- TLS certificates are automatically provisioned and renewed by cert-manager
- GPU nodes have specific security groups and IAM roles
- Grafana access is password-protected

## Future Improvements

The following improvements are planned or can be implemented to enhance this stack:

| Improvement | Description | Status |
|-------------|-------------|--------|
| **Model storage on EFS/S3** | Store models on EFS or S3 instead of EBS for better scalability and performance | Planned |
| **Prometheus monitoring** | Add Prometheus-based observability for metrics collection and visualization | ✅ Implemented |
| **Model autoscaling** | Implement automatic scaling of model replicas based on traffic patterns | In Progress |
| **GPU utilization optimization** | Further optimization of GPU utilization for improved cost efficiency | Planned |

## Contributing

When contributing to this repository, please follow these guidelines:

1. Update templates rather than generated files
2. Test changes in a separate environment before merging
3. Document significant changes in this README

## License

[Specify the appropriate license for your repository]