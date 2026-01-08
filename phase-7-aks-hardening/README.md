# Phase 7: AKS Best Practices

This phase implements Microsoft's AKS best practices for node pools, upgrades, and maintenance windows.

**References**:

[AKS Best Practices](https://learn.microsoft.com/en-us/azure/aks/best-practices)

[AKS Architecture Best Practices](https://learn.microsoft.com/en-us/azure/well-architected/service-guides/azure-kubernetes-service)

## What's New in Phase 7

| Feature | Phase 6 | Phase 7 |
|---------|---------|---------|
| Authentication | `local k8s RBAC` | `Entra ID + k8s RBAC` |
| Node pool name | `default` | `system` |
| Node pool taint | none | `CriticalAddonsOnly` |
| User node pool | none | separate `user` pool |
| Upgrade channel | manual | `patch` (automatic) |
| Node OS upgrades | manual | `NodeImage` (automatic) |
| Maintenance window | none | Sunday 02:00 UTC |
| Max surge | not set | 33% |

## Authentication

<https://learn.microsoft.com/en-us/azure/aks/operator-best-practices-identity>

Up until phase 6 we were using Local Kubernetes RBAC Only.

According to the best practices we will authenticate towards the cluster using Entra ID.

Cluster RBAC is still kept to Kubernetes RBAC instead of Azure RBAC.

## Node Pool Separation

<https://learn.microsoft.com/en-us/azure/aks/best-practices-app-cluster-reliability#use-dedicated-system-node-pools>

<https://learn.microsoft.com/en-us/azure/well-architected/service-guides/azure-kubernetes-service>

### System Node Pool

Runs only critical Kubernetes components (has `CriticalAddonsOnly` taint):

- CoreDNS
- kube-proxy
- Cilium
- metrics-server
- CSI drivers

### User Node Pool

Runs everything else (no taint needed):

- Flux controllers
- Traefik
- CNPG operator
- Customer databases
- n8n pods

## Why Cluster Recreation is Required

The node pool changes are **destructive**:

1. **Renaming `default` to `agentpool`** - AKS doesn't support renaming node pools
2. **Adding `only_critical_addons_enabled`** - Can only be set at creation time

Terraform will destroy and recreate the entire cluster. In production, you would:

- Create a new cluster with the correct configuration
- Migrate workloads
- Decommission the old cluster

## Scheduled Maintenance and Node Image Upgrades

We've implemented a maintenance window and node image upgrades.

<https://learn.microsoft.com/en-us/azure/aks/operator-best-practices-cluster-security?tabs=azure-cli#node-image-upgrades>

## Deployment Steps

### 1. Destroy Phase 6 Cluster

```bash
cd ../phase-6-cnpg
terraform destroy
```

### 2. Deploy Phase 7

```bash
cd ../phase-7-aks-dns
terraform init
terraform apply
```

### 3. Get Credentials and Verify

```bash

use new command

# Watch pods come up
kubectl get pods -A -w

# Verify node pools
kubectl get nodes
```

### 4. Verify Node Taints

```bash
# System nodes should have CriticalAddonsOnly taint
kubectl describe node -l agentpool=system | grep Taints

# User nodes should have no taints
kubectl describe node -l agentpool=user | grep Taints
```

### 5. Update SecretProviderClass Client ID

The new cluster has a new managed identity. Get the new client ID:

```bash
terraform output aks_keyvault_secrets_provider_client_id
```

Update the patch in `mercury-gitops/apps/staging/customer1/kustomization.yaml`.

### 6. Update DNS Record

Get Traefik's LoadBalancer IP and update your DNS provider (Cloudflare, Route53, etc.):

```bash
# Get the LoadBalancer IP
kubectl get svc -n traefik traefik -o jsonpath='{.status.loadBalancer.ingress[0].ip}'
```

Create/update an A record in your DNS provider pointing to this IP.

**Note**: The IP changes when you recreate the cluster, so you'll need to update DNS after each recreation.

## Important: Flux Extension Race Condition

When creating a fresh cluster with a tainted system pool, the Flux extension must wait for the user node pool to be ready. This is handled by the `depends_on` in `main.tf`:

```hcl
resource "azurerm_kubernetes_cluster_extension" "flux" {
  # ...
  depends_on = [azurerm_kubernetes_cluster_node_pool.user]
}
```

Without this, the Flux extension's managed identity fails to authenticate because it can't be properly assigned to the VMSS until the user node pool exists.

## File Structure

```
phase-7-aks-dns/
├── main.tf          # AKS cluster, node pools, Flux, Key Vault
├── backups.tf       # Storage account for CNPG backups
├── outputs.tf       # Key Vault and storage outputs
└── README.md        # This file
```

## Outputs

```bash
terraform output key_vault_name
terraform output aks_keyvault_secrets_provider_client_id
terraform output storage_account_name
```
