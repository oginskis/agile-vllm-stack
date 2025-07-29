# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Repository Overview

This is an Infrastructure-as-Code (IaC) repository for deploying a production-ready open-source LLM serving solution on AWS EKS. It uses shell scripts to orchestrate the deployment of Kubernetes resources, Helm charts, and GPU-enabled nodes for running large language models.

## Common Development Commands

### Deployment Commands
```bash
# Deploy the entire infrastructure stack (idempotent - can run multiple times)
./deploy.sh

# Undeploy and clean up all resources
./undeploy.sh

# Check cluster status
kubectl --kubeconfig ./kubeconfig get nodes
kubectl --kubeconfig ./kubeconfig get pods -A
```

### Working with Models
```bash
# View deployed models
kubectl --kubeconfig ./kubeconfig get pods -n vllm

# Check model logs
kubectl --kubeconfig ./kubeconfig logs -n vllm -l app=vllm-<model-name>

# Test inference endpoint
curl -X POST https://${INFERENCE_HOST}/v1/chat/completions \
  -H "Content-Type: application/json" \
  -d '{"model": "llama3-8b", "messages": [{"role": "user", "content": "Hello"}]}'
```

### Monitoring and Debugging
```bash
# Port-forward to Grafana (if DNS not configured)
kubectl --kubeconfig ./kubeconfig port-forward -n monitoring svc/kube-prom-stack-grafana 3000:80

# Check ingress status
kubectl --kubeconfig ./kubeconfig get ingress -A

# View cert-manager certificates
kubectl --kubeconfig ./kubeconfig get certificates -A
```

### Configuration Validation
```bash
# Validate environment variables are loaded
source .env && env | grep -E "CLUSTER_NAME|DNS_ZONE"

# Check Helm releases
helmfile --kubeconfig ./kubeconfig -f helmfile.yaml list

# Sync Helm releases after model-specs.yaml changes
helmfile --kubeconfig ./kubeconfig -f helmfile.yaml sync
```

## High-Level Architecture

The infrastructure is built around these core components:

1. **Template-Based Configuration**: The system uses `.template` files that are rendered with environment variables from `.env` to generate the actual YAML configurations. This pattern is used for:
   - EKS cluster configuration (`cluster/cluster.yaml.template`)
   - GPU node pools (`cluster/gpu-node-pool.yaml.template`)
   - TLS certificate issuers (`helm/cert-manager/cluster-issuer.yaml.template`)

2. **Deployment Orchestration**: The `deploy.sh` script follows a specific order:
   - Environment validation and template rendering
   - EKS cluster creation/validation
   - Kubernetes resource setup (storage classes, node pools)
   - Helm chart deployment via Helmfile (with dependency management)

3. **Model Management**: Models are defined in `model-specs.yaml` and deployed through the vLLM Helm chart. The system supports:
   - Multiple concurrent model deployments
   - Per-model resource allocation and GPU assignment
   - Persistent storage via EBS volumes
   - OpenAI-compatible API endpoints

4. **Conditional Features**: The infrastructure adapts based on environment variables:
   - If `DNS_ZONE_NAME` is not set, DNS-related components (nginx-ingress, external-dns, cert-manager) are skipped
   - Monitoring endpoints are only exposed if `MONITORING_HOST` and `PROMETHEUS_HOST` are configured

5. **Helm Value Templating**: Uses Go template files (`.gotmpl`) for dynamic Helm values, allowing environment-specific configurations to be injected at deployment time.

## Key Design Patterns

- **Idempotent Operations**: Both `deploy.sh` and `undeploy.sh` check resource existence before acting
- **Error Resilience**: Scripts continue with warnings rather than failing on non-critical errors
- **Resource Cleanup**: The undeploy script reverses deployment order to ensure clean removal
- **GPU Optimization**: Uses Karpenter for dynamic GPU node provisioning based on workload demands