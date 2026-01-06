# mercury-gitops

Provisioning and Deployment of a Managed Kubernetes Cluster on Azure

## Overview

This repository implements a complete GitOps workflow for managing a multi-tenant Kubernetes cluster on Azure Kubernetes Service (AKS). It combines Infrastructure as Code (Terraform) with GitOps (Flux) to provide automated customer provisioning and deployment.

## Architecture

```
┌─────────────────────────────────────────────────────────────────┐
│                         GitHub Repository                        │
│  ┌──────────────┐  ┌─────────────────┐  ┌──────────────────┐   │
│  │  Terraform   │  │ Infrastructure  │  │  Applications    │   │
│  │   (main.tf)  │  │   (Flux sync)   │  │  (Customer apps) │   │
│  └──────────────┘  └─────────────────┘  └──────────────────┘   │
└─────────────────────────────────────────────────────────────────┘
         │                      │                       │
         │                      ▼                       │
         │            ┌──────────────────┐              │
         │            │   Flux CD Agent  │              │
         │            │  (AKS Cluster)   │              │
         │            └──────────────────┘              │
         │                      │                       │
         ▼                      ▼                       ▼
┌─────────────────┐   ┌────────────────┐    ┌──────────────────┐
│  Azure Key      │   │ Infrastructure │    │  Customer Apps   │
│  Vault          │   │  - Traefik     │    │  - PostgreSQL    │
│  (Secrets)      │   │  - cert-mgr    │    │  - n8n           │
└─────────────────┘   │  - CNPG        │    │  - Ingress/TLS   │
                      └────────────────┘    └──────────────────┘
```

## Repository Structure

```
mercury-gitops/
├── main.tf                      # Terraform: AKS cluster, Flux, Key Vault
├── infrastructure/              # Infrastructure components (Flux-managed)
│   ├── controllers/             # Helm releases (Traefik, cert-manager, CNPG)
│   │   ├── base/
│   │   └── staging/
│   └── configs/                 # Infrastructure configs (ClusterIssuers, etc.)
│       ├── base/
│       └── staging/
├── apps/                        # Customer applications (Flux-managed)
│   ├── base/                    # Base Kubernetes manifests per customer
│   │   └── customer1/
│   └── staging/                 # Environment-specific overlays
│       └── customer1/
└── .github/
    ├── workflows/               # GitHub Actions workflows
    │   └── provision-customer.yml
    └── scripts/                 # Automation scripts
        ├── provision-customer.py
        ├── update-terraform.py
        └── templates/           # K8s manifest templates
```

## Workflows

### 1. Initial Infrastructure Setup (Terraform)

The `main.tf` file provisions the complete Azure infrastructure:

**Resources Created:**
- Azure Kubernetes Service (AKS) cluster
  - Kubernetes 1.32.0
  - 2-node pool (Standard_D2s_v3)
  - Cilium network plugin and policy
- Flux CD extension and configuration
  - Three Flux kustomizations with dependency chain:
    1. `infra-controllers` - Infrastructure Helm releases
    2. `infra-configs` - Infrastructure configurations
    3. `apps` - Customer applications
- Azure Key Vault for secrets management
  - RBAC-based access control
  - Integration with AKS CSI Secrets Store

**Deployment:**
```bash
terraform init
terraform plan
terraform apply
```

Flux automatically syncs every 5 minutes and applies changes from this repository to the cluster.

### 2. GitOps with Flux

Flux continuously monitors this repository and automatically deploys changes to the cluster:

**Sync Flow:**
```
main.tf:75-96 → Flux Configuration
    ↓
1. infra-controllers (5 min sync)
   - Installs: Traefik, cert-manager, CloudNativePG
    ↓
2. infra-configs (5 min sync, depends on controllers)
   - Configures: Let's Encrypt ClusterIssuers
    ↓
3. apps (5 min sync, depends on configs)
   - Deploys: All customer applications
```

**Infrastructure Components:**
- **Traefik**: Ingress controller and load balancer
- **cert-manager**: Automatic TLS certificate management (Let's Encrypt)
- **CloudNativePG (CNPG)**: PostgreSQL operator for database clusters

**Monitoring Flux:**
```bash
# Check Flux status
flux get kustomizations

# Force reconciliation
flux reconcile kustomization apps --with-source

# View logs
flux logs --level=info
```

### 3. Automated Customer Provisioning

The repository includes a GitHub Actions workflow that automates the complete customer onboarding process.

**Workflow: `.github/workflows/provision-customer.yml`**

**Trigger:** Manual workflow dispatch from GitHub Actions UI

**Inputs:**
- `customer_name`: Customer identifier (format: `customer2`, `customer3`, etc.)
- `traefik_ip`: External IP of Traefik LoadBalancer
- `aks_identity_client_id`: AKS Key Vault Secrets Provider Client ID (optional)
- `azure_tenant_id`: Azure Tenant ID (optional)

**What It Does:**

1. **DNS Setup** (`.github/workflows/provision-customer.yml:52-134`)
   - Creates/updates Cloudflare DNS A record
   - Maps `customerN.mercury.kubetest.uk` to Traefik IP
   - Uses Cloudflare API with token from GitHub Secrets

2. **Generate Kubernetes Manifests** (`.github/scripts/provision-customer.py`)
   - Creates namespace and resources from templates
   - Generates for each customer:
     - Namespace
     - PostgreSQL cluster (3-instance HA setup via CNPG)
     - Azure Key Vault SecretProviderClass
     - n8n deployment (workflow automation)
     - Service and Ingress with TLS
     - ConfigMaps and storage

3. **Update Terraform** (`.github/scripts/update-terraform.py`)
   - Adds customer database credentials to `main.tf`
   - Generates secure random passwords
   - Configures Key Vault secrets

4. **Create Pull Request**
   - Automated PR with all generated resources
   - Includes detailed deployment instructions
   - Labels: `provisioning`, `automated`

**Running the Workflow:**

1. Navigate to **Actions** → **Provision New Customer**
2. Click **Run workflow**
3. Fill in:
   - Customer name: `customer2`
   - Traefik IP: Get via `kubectl get svc -n traefik traefik -o jsonpath='{.status.loadBalancer.ingress[0].ip}'`
4. Review and merge the generated PR
5. Apply Terraform changes: `terraform apply`
6. Wait for Flux to sync (auto, or `flux reconcile kustomization apps`)

**Result:**
- DNS: `https://customer2.mercury.kubetest.uk`
- Namespace: `customer2`
- Database: PostgreSQL 3-node cluster
- Application: n8n with TLS certificate
- Secrets: Managed via Azure Key Vault

## Security

**Secrets Management:**
- All secrets stored in Azure Key Vault (never in Git)
- CSI Secrets Store driver mounts secrets at runtime
- Automatic rotation support
- RBAC-based access control

**TLS/SSL:**
- Automatic Let's Encrypt certificates via cert-manager
- HTTP to HTTPS redirect via Traefik
- Per-customer certificate management

**Network Security:**
- Cilium network policy enforcement
- Namespace isolation per customer
- Azure CNI with network policies

## Common Operations

### Deploy a New Customer

Use the GitHub Actions workflow (see Automated Customer Provisioning above)

### View Customer Resources

```bash
# List all customer namespaces
kubectl get namespaces | grep customer

# View customer pods
kubectl get pods -n customer1

# Check database cluster
kubectl get cluster -n customer1

# View ingress
kubectl get ingress -n customer1
```

### Update Customer Configuration

1. Edit manifests in `apps/base/customerN/` or `apps/staging/customerN/`
2. Commit and push changes
3. Flux automatically syncs within 5 minutes

### Access Customer Application

Each customer gets a dedicated subdomain:
- URL: `https://customerN.mercury.kubetest.uk`
- TLS certificate: Automatically issued by Let's Encrypt
- Backend: n8n workflow automation platform

### Troubleshooting

**Check Flux sync status:**
```bash
flux get all -A
```

**View Flux logs:**
```bash
flux logs
```

**Check certificate status:**
```bash
kubectl describe certificate -n customerN
```

**Database connectivity:**
```bash
kubectl logs -n customerN <pod-name>
kubectl describe secretproviderclass -n customerN
```

**Force sync:**
```bash
flux reconcile kustomization apps --with-source
```

## Prerequisites

**Required:**
- Azure subscription
- Azure CLI (`az`) authenticated
- Terraform >= 1.0
- kubectl
- flux CLI
- SSH key for GitHub repository access (`~/.ssh/mercury`)

**GitHub Secrets:**
- `CLOUDFLARE_DNS_KUBETEST_UK`: For DNS management

## Development

**Local Testing:**
```bash
# Validate Terraform
terraform validate

# Plan changes
terraform plan

# Test Flux kustomizations locally
flux build kustomization apps --path ./apps/staging

# Dry-run customer provisioning
python3 .github/scripts/provision-customer.py customer-test --dry-run
```

## Future Enhancements

- Automated Terraform apply after PR merge
- Customer deletion workflow
- Multiple environments (production, dev)
- Resource quotas per customer
- Monitoring and alerting setup
- Backup and disaster recovery

## Documentation

- Customer provisioning scripts: `.github/scripts/README.md`
- Terraform outputs: `terraform output`
- Flux documentation: https://fluxcd.io/flux/

## License

[Add your license here]
