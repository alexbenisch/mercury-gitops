# mercury-gitops

Provisioning and Deployment of a Managed Kubernetes Cluster on Azure

## Overview

This repository implements a GitOps workflow for managing a Kubernetes cluster on Azure Kubernetes Service (AKS). It combines Infrastructure as Code (Terraform) with GitOps (Flux) to provide automated deployment of infrastructure and applications.

## Architecture

```
┌─────────────────────────────────────────────────────────────────┐
│                         GitHub Repository                        │
│  ┌──────────────┐  ┌─────────────────┐  ┌──────────────────┐   │
│  │  Terraform   │  │ Infrastructure  │  │  Applications    │   │
│  │   (main.tf)  │  │   (Flux sync)   │  │    (customer1)   │   │
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
│  Azure Key      │   │ Infrastructure │    │   Application    │
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
└── apps/                        # Applications (Flux-managed)
    ├── base/                    # Base Kubernetes manifests
    │   └── customer1/
    └── staging/                 # Environment-specific overlays
        └── customer1/
```

## Getting Started

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
    3. `apps` - Applications
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
main.tf → Flux Configuration
    ↓
1. infra-controllers (5 min sync)
   - Installs: Traefik, cert-manager, CloudNativePG
    ↓
2. infra-configs (5 min sync, depends on controllers)
   - Configures: Let's Encrypt ClusterIssuers
    ↓
3. apps (5 min sync, depends on configs)
   - Deploys: customer1 application stack
```

**Monitoring Flux:**
```bash
# Check all kustomizations
flux get kustomizations

# Force reconciliation
flux reconcile kustomization apps --with-source

# View logs
flux logs --all-namespaces --follow
```

## Application Stack

### Customer1 Deployment

The application stack includes:

- **Namespace**: `customer1`
- **PostgreSQL Database**: CloudNativePG cluster (3 instances)
- **n8n**: Workflow automation tool
- **Ingress**: Traefik with Let's Encrypt TLS
- **Secrets**: Azure Key Vault integration via CSI driver

**DNS**: `customer1.mercury.kubetest.uk`

### Components

1. **Database** (`apps/base/customer1/database.yaml`)
   - CloudNativePG Cluster
   - 3 PostgreSQL instances (1 primary, 2 replicas)
   - Persistent storage

2. **n8n Deployment** (`apps/base/customer1/deployment.yaml`)
   - n8n workflow automation
   - Connected to PostgreSQL
   - Persistent workflow storage

3. **Secrets** (`apps/base/customer1/secrets.yaml`)
   - Azure Key Vault SecretProviderClass
   - Mounts database credentials from Key Vault
   - Creates Kubernetes secrets for application use

4. **Ingress** (`apps/base/customer1/ingress.yaml`)
   - Traefik IngressRoute
   - Automatic TLS via cert-manager
   - Let's Encrypt certificate

## Common Operations

### Checking Deployment Status

```bash
# Check all pods
kubectl get pods -n customer1

# Check specific resources
kubectl get cluster -n customer1
kubectl get deployment -n customer1
kubectl get ingress -n customer1

# Describe a resource
kubectl describe pod <pod-name> -n customer1
```

### Viewing Logs

```bash
# Application logs
kubectl logs -n customer1 -l app=customer1-n8n

# Database logs
kubectl logs -n customer1 -l cnpg.io/cluster=customer1-db
```

### Troubleshooting

#### Pods Not Starting

```bash
# Check pod events
kubectl describe pod <pod-name> -n customer1

# Check secrets are mounted correctly
kubectl get secretproviderclass -n customer1
kubectl describe secretproviderclass customer1-secrets -n customer1
```

#### Database Connection Issues

```bash
# Check database status
kubectl get cluster -n customer1 customer1-db -o yaml

# Verify secrets exist
kubectl get secret -n customer1 customer1-db-credentials
```

#### Certificate Issues

```bash
# Check certificate status
kubectl get certificate -n customer1
kubectl describe certificate customer1-tls -n customer1

# Check cert-manager logs
kubectl logs -n cert-manager -l app=cert-manager
```

## Azure Key Vault Integration

The application uses Azure Key Vault to store sensitive data:

**Secrets Stored:**
- `customer1-db-user`: Database username
- `customer1-db-password`: Database password

**Access Method:**
- AKS Managed Identity authenticates to Key Vault
- CSI Secrets Store driver mounts secrets as volumes
- Secrets are synced to Kubernetes Secret objects

**Checking Secrets:**
```bash
# List secrets in Key Vault
az keyvault secret list --vault-name kv-mercury-staging

# Get a secret value
az keyvault secret show --vault-name kv-mercury-staging --name customer1-db-user
```

## Making Changes

### Modifying Application Configuration

1. Edit files in `apps/base/customer1/` or `apps/staging/customer1/`
2. Commit and push changes
3. Flux will automatically sync (or force with `flux reconcile kustomization apps`)

### Updating Terraform Infrastructure

1. Modify `main.tf`
2. Run `terraform plan` to preview changes
3. Run `terraform apply` to apply changes

## Security Notes

- **Secrets**: Never commit secrets to git
- **Key Vault**: All sensitive data stored in Azure Key Vault
- **CSI Driver**: Secrets mounted at runtime via CSI driver
- **TLS**: Automatic Let's Encrypt certificates via cert-manager
- **RBAC**: Azure RBAC controls Key Vault access

## Useful Commands

```bash
# Get Traefik external IP
kubectl get svc -n traefik traefik

# Check Flux reconciliation
flux get sources git
flux get kustomizations

# Force Flux to sync immediately
flux reconcile source git flux-system
flux reconcile kustomization infra-controllers --with-source
flux reconcile kustomization infra-configs --with-source
flux reconcile kustomization apps --with-source

# View Flux logs
flux logs

# Suspend/resume a kustomization
flux suspend kustomization apps
flux resume kustomization apps
```

## Troubleshooting & Lessons Learned

This section documents real issues encountered during setup and how they were resolved.

### Issue 1: Pods Stuck in ContainerCreating - Azure Key Vault Authentication

**Symptoms:**
```bash
flux get kustomizations
# NAME                     READY    MESSAGE
# mercury-system-apps      False    health check failed: Deployment/customer1/customer1-n8n status: 'Failed'

kubectl get pods -n customer1
# customer1-n8n-xxx   0/1   ContainerCreating   0   26m
```

**Root Cause:**
Pods were failing to mount Azure Key Vault secrets via the CSI driver. The error message indicated:
```
ManagedIdentityCredential authentication failed. the requested identity isn't assigned to this resource
Identity not found
```

This occurred because:
1. The `userAssignedIdentityID` in `SecretProviderClass` was using an incorrect client ID
2. The `tenantId` was using the subscription ID instead of the actual Azure tenant ID

**Diagnosis Steps:**
```bash
# 1. Check pod status
kubectl describe pod <pod-name> -n customer1

# 2. Look for mount errors in events
kubectl get events -n customer1 --sort-by='.lastTimestamp'

# 3. Check SecretProviderClass configuration
kubectl get secretproviderclass customer1-secrets -n customer1 -o yaml

# 4. Get correct values from Terraform
terraform output aks_keyvault_secrets_provider_client_id
terraform state show data.azurerm_client_config.current | grep tenant_id
```

**Solution:**
1. Updated `apps/staging/customer1/kustomization.yaml` with correct values:
   ```yaml
   patches:
     - target:
         kind: SecretProviderClass
         name: customer1-secrets
       patch: |-
         - op: replace
           path: /spec/parameters/userAssignedIdentityID
           value: "48603787-7f9f-4c17-9071-677bcae61660"  # From terraform output
         - op: replace
           path: /spec/parameters/tenantId
           value: "36e054ee-92ea-404f-97ee-2859b2462cd6"  # From terraform state
   ```

2. Deleted the pod to force recreation with correct configuration:
   ```bash
   kubectl delete pod -n customer1 -l app=customer1-n8n
   ```

**Key Learnings:**
- Always verify Azure identity client IDs and tenant IDs match what Terraform outputs
- The AKS Key Vault Secrets Provider creates a managed identity - get its client ID from `terraform output`
- Subscription ID ≠ Tenant ID (common mistake)
- Pods don't automatically restart when SecretProviderClass is updated - manual restart required

### Issue 2: Application Not Reachable - Wrong IngressClass Name

**Symptoms:**
```bash
curl -I https://customer1.mercury.kubetest.uk
# HTTP/2 404
# content-type: text/plain; charset=utf-8
```

The connection reached Traefik (getting HTTP response), but returned 404.

**Root Cause:**
The Ingress resource was configured with `ingressClassName: traefik`, but the actual IngressClass created by the Traefik Helm chart was named `traefik-traefik`.

When Helm releases create IngressClasses, they follow the naming pattern: `{release-name}-traefik`

**Diagnosis Steps:**
```bash
# 1. Verify DNS resolves correctly
nslookup customer1.mercury.kubetest.uk
# Should return Traefik LoadBalancer IP

# 2. Check Traefik is running and has external IP
kubectl get svc -n traefik

# 3. Test the pod directly (should work)
kubectl exec -n customer1 <pod-name> -- wget -O- http://localhost:3008

# 4. Check actual IngressClass names in cluster
kubectl get ingressclass
# NAME              CONTROLLER
# traefik-traefik   traefik.io/ingress-controller   <- Note the name!

# 5. Compare with Ingress configuration
kubectl describe ingress customer1-ingress -n customer1
# Ingress Class:    traefik  <- Mismatch!
```

**Solution:**
Updated `apps/base/customer1/ingress.yaml`:
```yaml
spec:
  ingressClassName: traefik-traefik  # Changed from 'traefik'
```

**Key Learnings:**
- Helm chart release names affect IngressClass naming
- Always check actual IngressClass names: `kubectl get ingressclass`
- A 404 from Traefik means it received the request but couldn't route it (vs connection refused = Traefik not running)
- Test the pod directly first to isolate networking vs application issues
- IngressClass mismatch is a common issue when using Helm charts

### Common Debugging Workflow

When troubleshooting Kubernetes applications, follow this sequence:

1. **Check Flux sync status**
   ```bash
   flux get kustomizations
   ```

2. **Check pod status**
   ```bash
   kubectl get pods -n <namespace>
   kubectl describe pod <pod-name> -n <namespace>
   ```

3. **Check pod logs**
   ```bash
   kubectl logs -n <namespace> <pod-name>
   ```

4. **Check events**
   ```bash
   kubectl get events -n <namespace> --sort-by='.lastTimestamp'
   ```

5. **Verify services and endpoints**
   ```bash
   kubectl get svc -n <namespace>
   kubectl get endpoints -n <namespace>
   ```

6. **Test connectivity**
   ```bash
   # From within the cluster
   kubectl exec -n <namespace> <pod-name> -- wget -O- http://service:port

   # From outside
   curl -I https://your-domain.com
   ```

7. **Check ingress/routing**
   ```bash
   kubectl get ingress -n <namespace>
   kubectl get ingressclass
   kubectl describe ingress <name> -n <namespace>
   ```

8. **Check Traefik logs** (if using Traefik)
   ```bash
   kubectl logs -n traefik -l app.kubernetes.io/name=traefik
   ```

## Learning Resources

- [Flux Documentation](https://fluxcd.io/docs/)
- [CloudNativePG Documentation](https://cloudnative-pg.io/)
- [Deploy highly available PostgreSQL on AKS with CloudNativePG](https://learn.microsoft.com/en-us/azure/aks/create-postgresql-ha) - Microsoft Learn guide
- [Traefik Documentation](https://doc.traefik.io/traefik/)
- [cert-manager Documentation](https://cert-manager.io/docs/)
- [Azure Key Vault CSI Driver](https://github.com/Azure/secrets-store-csi-driver-provider-azure)
