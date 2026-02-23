# Mercury AKS Deployment Plan

## Overview
Deployment of n8n on Azure Kubernetes Service (AKS) broken into testable beads.

---

## Bead 0: Azure Foundation & Prerequisites

### Prerequisites
- Azure CLI installed and configured
- kubectl installed
- flux CLI installed
- cmctl (cert-manager CLI) installed
- CloudNativePG barman-cloud plugin installed
- GitHub SSH key for Flux GitOps

### 0.1 Azure Authentication
- [ ] Log into Azure CLI
- [ ] Set active subscription
- [ ] Verify permissions to create resources

**Test:**
```bash
az login
az account show
az account list-locations -o table

# Check your role assignments on the subscription
az role assignment list --assignee $(az ad signed-in-user show --query id -o tsv) --all

# Test specific resource creation permissions (dry-run style checks)

# Check Resource Group creation permission
az group create --name test-permission-check --location "North Europe" --dry-run 2>&1 | grep -i "authorization\|permission\|forbidden" || echo "✓ Resource Group: OK"

# Check AKS cluster permission (using az policy to check)
az provider show --namespace Microsoft.ContainerService --query "registrationState"

# Check Key Vault permission
az provider show --namespace Microsoft.KeyVault --query "registrationState"

# Check Storage Account permission
az provider show --namespace Microsoft.Storage --query "registrationState"

# Check Kubernetes Configuration (Flux) permission
az provider show --namespace Microsoft.KubernetesConfiguration --query "registrationState"

# List your effective permissions on the subscription
SUBSCRIPTION_ID=$(az account show --query id -o tsv)
az role assignment list --assignee $(az ad signed-in-user show --query id -o tsv) \
  --scope "/subscriptions/$SUBSCRIPTION_ID" \
  --query "[].{Role:roleDefinitionName, Scope:scope}" -o table

# Check if you have Contributor or Owner role (required for main.tf)
az role assignment list --assignee $(az ad signed-in-user show --query id -o tsv) \
  --query "[?roleDefinitionName=='Owner' || roleDefinitionName=='Contributor'].{Role:roleDefinitionName, Scope:scope}" -o table
```


### The key permissions you need are:
  - Contributor or Owner role on the subscription or resource group
  - Providers must be registered (should show "Registered"):
    - Microsoft.ContainerService
    - Microsoft.KeyVault
    - Microsoft.Storage
    - Microsoft.KubernetesConfiguration

### 0.2 SSH Key for Flux
- [ ] Generate or locate SSH key for GitHub access
- [ ] Add public key to GitHub repository deploy keys
- [ ] Verify SSH key path (~/.ssh/mercury)

**Test:**
```bash
ssh-keygen -t ed25519 -f ~/.ssh/mercury -C "flux@mercury-gitops"
cat ~/.ssh/mercury.pub
ssh -T git@github.com
```

---

## Bead 1: Core Infrastructure (Terraform)

### 1.1 Resource Group
- [ ] Create Azure resource group for AKS cluster
- [ ] Set location (e.g., westeurope)

**Terraform:**
```hcl
resource "azurerm_resource_group" "aks" {
  name     = "rg-cloud-course-aks"
  location = "westeurope"
}
```
**CLI:**
```
```
```bash 
az group create --name rg-cloud-course-aks --location westeurope
```
```
```

**Test:**
```bash
az group show --name rg-cloud-course-aks
```

### 1.2 Azure Key Vault
- [ ] Create Azure Key Vault instance
- [ ] Enable RBAC authorization
- [ ] Configure network access
- [ ] Enable purge protection

**Test:**
```bash
az keyvault show --name kv-mercury-staging
az keyvault secret list --vault-name kv-mercury-staging
```

### 1.3 Key Vault Secrets
- [ ] Create database username secret
- [ ] Create database password secret
- [ ] Create storage account name secret (for backups)
- [ ] Create blob SAS token secret (for backups)

**Test:**
```bash
az keyvault secret set --vault-name kv-mercury-staging --name customer1-db-user --value "postgres"
az keyvault secret set --vault-name kv-mercury-staging --name customer1-db-password --value "<secure-password>"
az keyvault secret show --vault-name kv-mercury-staging --name customer1-db-user
```

---

## Bead 2: AKS Cluster Deployment

### 2.1 AKS Cluster Core
- [ ] Deploy AKS cluster with Terraform
- [ ] Set Kubernetes version (1.32.0)
- [ ] Configure 2-node default pool (Standard_D2s_v3)
- [ ] Enable System Assigned Identity
- [ ] Enable Key Vault Secrets Provider addon

**Terraform:**
```hcl
resource "azurerm_kubernetes_cluster" "main" {
  name                = "mercury-staging"
  location            = azurerm_resource_group.aks.location
  resource_group_name = azurerm_resource_group.aks.name
  dns_prefix          = "staging"
  kubernetes_version  = "1.32.0"

  default_node_pool {
    name       = "default"
    node_count = 2
    vm_size    = "Standard_D2s_v3"
  }

  identity {
    type = "SystemAssigned"
  }

  key_vault_secrets_provider {
    secret_rotation_enabled = false
  }
}
```

**Test:**
```bash
az aks show --resource-group rg-cloud-course-aks --name mercury-staging
az aks get-credentials --resource-group rg-cloud-course-aks --name mercury-staging
kubectl get nodes
kubectl cluster-info
```

### 2.2 Network Configuration
- [ ] Configure Azure CNI
- [ ] Enable Cilium network plugin
- [ ] Enable Cilium network policy
- [ ] Configure Cilium data plane

**Test:**
```bash
kubectl get pods -n kube-system -l k8s-app=cilium
kubectl run test-pod --image=nginx --restart=Never
kubectl get pod test-pod -o wide
kubectl delete pod test-pod
```

### 2.3 Key Vault Integration
- [ ] Get AKS Key Vault Secrets Provider identity client ID
- [ ] Assign Key Vault Secrets User role to identity
- [ ] Verify access to Key Vault

**Test:**
```bash
# Get the identity client ID
az aks show --resource-group rg-cloud-course-aks --name mercury-staging \
  --query "addonProfiles.azureKeyvaultSecretsProvider.identity.clientId" -o tsv

# Assign RBAC role
KEYVAULT_SCOPE=$(az keyvault show --name kv-mercury-staging --query id -o tsv)
IDENTITY_CLIENT_ID="<client-id-from-above>"
az role assignment create --role "Key Vault Secrets User" \
  --assignee $IDENTITY_CLIENT_ID \
  --scope $KEYVAULT_SCOPE
```

---

## Bead 3: Flux CD Installation

### 3.1 Flux AKS Extension
- [ ] Install Flux as AKS cluster extension
- [ ] Configure extension name
- [ ] Verify Flux controllers deployed

**Terraform:**
```hcl
resource "azurerm_kubernetes_cluster_extension" "flux" {
  name           = "mercury-flux"
  cluster_id     = azurerm_kubernetes_cluster.main.id
  extension_type = "microsoft.flux"
}
```

**Test:**
```bash
az k8s-extension show --name mercury-flux \
  --cluster-name mercury-staging \
  --resource-group rg-cloud-course-aks \
  --cluster-type managedClusters

kubectl get pods -n flux-system
flux check
```

### 3.2 Flux Configuration
- [ ] Create Flux configuration for GitOps
- [ ] Configure Git repository URL
- [ ] Add SSH private key for authentication
- [ ] Configure three kustomizations with dependencies

**Terraform:**
```hcl
resource "azurerm_kubernetes_flux_configuration" "main" {
  name       = "mercury-system"
  cluster_id = azurerm_kubernetes_cluster.main.id
  namespace  = "flux-system"

  git_repository {
    url             = "ssh://git@github.com/alexbenisch/mercury-gitops"
    reference_type  = "branch"
    reference_value = "main"
    ssh_private_key_base64 = base64encode(file("~/.ssh/mercury"))
  }

  kustomizations {
    name = "infra-controllers"
    path = "./infrastructure/controllers/staging"
  }
  kustomizations {
    name       = "infra-configs"
    path       = "./infrastructure/configs/staging"
    depends_on = ["infra-controllers"]
  }
  kustomizations {
    name       = "apps"
    path       = "./apps/staging"
    depends_on = ["infra-configs"]
  }
}
```

**Test:**
```bash
flux get sources git
flux get kustomizations
kubectl get gitrepository -n flux-system
```

---

## Bead 4: Infrastructure Controllers

### 4.1 Traefik Ingress Controller
- [ ] Create HelmRepository for Traefik
- [ ] Deploy HelmRelease for Traefik
- [ ] Configure Service type LoadBalancer
- [ ] Verify Azure Load Balancer created

**Manifests:** `infrastructure/controllers/base/traefik/`

**Test:**
```bash
kubectl get pods -n traefik
kubectl get svc -n traefik
kubectl get ingressclass
# Should see traefik-traefik IngressClass
```

### 4.2 cert-manager
- [ ] Create HelmRepository for cert-manager
- [ ] Deploy cert-manager with CRDs
- [ ] Verify webhook is ready
- [ ] Verify CRDs installed

**Manifests:** `infrastructure/controllers/base/cert-manager/`

**Test:**
```bash
kubectl get pods -n cert-manager
kubectl get crd | grep cert-manager
cmctl check api
```

### 4.3 CloudNativePG Operator
- [ ] Create HelmRepository for CNPG
- [ ] Deploy CNPG operator
- [ ] Deploy barman-cloud plugin
- [ ] Verify CRDs installed

**Manifests:** `infrastructure/controllers/base/cnpg/`

**Test:**
```bash
kubectl get pods -n cnpg-system
kubectl get crd | grep cnpg
kubectl api-resources | grep postgresql
```

---

## Bead 5: Infrastructure Configurations

### 5.1 Let's Encrypt ClusterIssuers
- [ ] Create staging ClusterIssuer
- [ ] Create production ClusterIssuer
- [ ] Configure ACME server URLs
- [ ] Configure private key secrets
- [ ] Set up HTTP-01 solver

**Manifests:** `infrastructure/configs/base/cert-manager/cluster-issuers.yaml`

**Test:**
```bash
kubectl get clusterissuer
kubectl describe clusterissuer letsencrypt-staging
kubectl describe clusterissuer letsencrypt-prod
```

---

## Bead 6: Backup Infrastructure

### 6.1 Azure Storage Account
- [ ] Create storage account for backups
- [ ] Create blob container for customer1
- [ ] Generate SAS token with 2-year expiration
- [ ] Configure read/write/list/delete permissions

**Terraform:** `phase-6-cnpg/backups.tf`

**Test:**
```bash
terraform -chdir=phase-6-cnpg init
terraform -chdir=phase-6-cnpg plan
terraform -chdir=phase-6-cnpg apply

# Verify storage account
az storage account show --name alexmercurybackupsstaging --resource-group rg-cloud-course-aks

# Verify container
az storage container list --account-name alexmercurybackupsstaging --query "[].name"
```

### 6.2 Key Vault Backup Secrets
- [ ] Store storage account name in Key Vault
- [ ] Store SAS token in Key Vault
- [ ] Verify secrets accessible

**Test:**
```bash
az keyvault secret show --vault-name kv-mercury-staging --name storage-account-name
az keyvault secret show --vault-name kv-mercury-staging --name customer1-blob-sas
```

---

## Bead 7: Customer1 Namespace

### 7.1 Namespace Creation
- [ ] Create customer1 namespace
- [ ] Apply labels for organization

**Manifests:** `apps/base/customer1/namespace.yaml`

**Test:**
```bash
kubectl get namespace customer1
kubectl describe namespace customer1
```

### 7.2 SecretProviderClass
- [ ] Create SecretProviderClass for Azure Key Vault
- [ ] Configure userAssignedIdentityID (from AKS addon)
- [ ] Configure tenantId
- [ ] Map database credentials
- [ ] Map backup credentials
- [ ] Configure secretObjects for K8s secret sync

**Manifests:** `apps/base/customer1/secrets.yaml`

**Critical values:**
- `userAssignedIdentityID`: From `az aks show --query "addonProfiles.azureKeyvaultSecretsProvider.identity.clientId"`
- `tenantId`: From `az account show --query tenantId`

**Test:**
```bash
kubectl get secretproviderclass -n customer1
kubectl describe secretproviderclass customer1-secrets -n customer1
```

### 7.3 Secrets Validation
- [ ] Create test pod mounting secrets
- [ ] Verify secrets mounted correctly
- [ ] Verify K8s secrets synced

**Test:**
```bash
kubectl apply -f - <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: secrets-test
  namespace: customer1
spec:
  containers:
  - name: test
    image: busybox
    command: ["sleep", "3600"]
    volumeMounts:
    - name: secrets
      mountPath: /mnt/secrets
      readOnly: true
  volumes:
  - name: secrets
    csi:
      driver: secrets-store.csi.x-k8s.io
      readOnly: true
      volumeAttributes:
        secretProviderClass: customer1-secrets
EOF

kubectl wait --for=condition=Ready pod/secrets-test -n customer1 --timeout=60s
kubectl exec -n customer1 secrets-test -- ls -la /mnt/secrets
kubectl get secret customer1-db-credentials -n customer1
kubectl get secret customer1-n8n-env -n customer1
kubectl delete pod secrets-test -n customer1
```

---

## Bead 8: PostgreSQL Database

### 8.1 Database Cluster
- [ ] Create CloudNativePG Cluster resource
- [ ] Configure 3 instances (1 primary, 2 replicas)
- [ ] Set PostgreSQL version (16.6)
- [ ] Configure storage (10Gi)
- [ ] Reference database credentials secret
- [ ] Initialize database schema

**Manifests:** `apps/base/customer1/database.yaml`

**Test:**
```bash
kubectl get cluster -n customer1
kubectl get pods -n customer1 -l cnpg.io/cluster=customer1-db
kubectl cnpg status customer1-db -n customer1
kubectl logs -n customer1 customer1-db-1 -c postgres
```

### 8.2 Backup Configuration
- [ ] Configure barmanObjectStore
- [ ] Set Azure Blob destination path
- [ ] Configure Azure credentials from secrets
- [ ] Enable WAL compression (gzip)
- [ ] Set retention policy (30d)

**Test:**
```bash
# Check cluster backup configuration
kubectl get cluster customer1-db -n customer1 -o yaml | grep -A 10 backup

# Trigger manual backup
kubectl cnpg backup customer1-db -n customer1

# Verify backup created
kubectl get backup -n customer1
kubectl describe backup <backup-name> -n customer1

# Check Azure Blob Storage
az storage blob list \
  --account-name alexmercurybackupsstaging \
  --container-name customer1 \
  --output table
```

### 8.3 Scheduled Backups
- [ ] Create ScheduledBackup resource
- [ ] Configure daily backup at 2 AM
- [ ] Verify schedule created

**Manifests:** `apps/base/customer1/scheduled-backup.yaml`

**Test:**
```bash
kubectl get scheduledbackup -n customer1
kubectl describe scheduledbackup customer1-daily-backup -n customer1
```

### 8.4 Database Connectivity
- [ ] Verify database services created
- [ ] Test connection to database
- [ ] Verify replication working

**Test:**
```bash
kubectl get svc -n customer1 | grep customer1-db
kubectl cnpg psql customer1-db -n customer1 -- -c "SELECT version();"
kubectl cnpg psql customer1-db -n customer1 -- -c "SELECT * FROM pg_stat_replication;"
```

---

## Bead 9: n8n Application

### 9.1 n8n Deployment
- [ ] Create Deployment manifest
- [ ] Configure n8n image (docker.n8n.io/n8nio/n8n:1.123.3)
- [ ] Set environment variables from ConfigMap
- [ ] Set database credentials from secrets
- [ ] Mount SecretProviderClass volume
- [ ] Configure port 3008

**Manifests:** `apps/base/customer1/deployment.yaml`

**Test:**
```bash
kubectl get deployment -n customer1
kubectl get pods -n customer1 -l app=customer1-n8n
kubectl logs -n customer1 -l app=customer1-n8n --tail=50
```

### 9.2 n8n Service
- [ ] Create Service for n8n
- [ ] Configure port 3008
- [ ] Set selector for n8n pods

**Manifests:** `apps/base/customer1/service.yaml`

**Test:**
```bash
kubectl get svc -n customer1
kubectl get endpoints -n customer1
```

### 9.3 n8n ConfigMap
- [ ] Create ConfigMap for n8n environment
- [ ] Set database host (customer1-db-rw)
- [ ] Set database name
- [ ] Set database type (postgresdb)
- [ ] Set n8n host URL

**Manifests:** `apps/base/customer1/configmap.yaml`

**Test:**
```bash
kubectl get configmap -n customer1
kubectl describe configmap customer1-n8n-config -n customer1
```

---

## Bead 10: Ingress & TLS

### 10.1 Ingress Resource
- [ ] Create Ingress for n8n
- [ ] Configure IngressClass (traefik-traefik)
- [ ] Set host (customer1.mercury.kubetest.uk)
- [ ] Configure TLS secret
- [ ] Add cert-manager annotation for ClusterIssuer

**Manifests:** `apps/base/customer1/ingress.yaml`

**For initial testing (staging certificates):**
```yaml
annotations:
  cert-manager.io/cluster-issuer: letsencrypt-staging
spec:
  tls:
    - hosts:
        - customer1.mercury.kubetest.uk
      secretName: customer1-tls
```

**Test:**
```bash
kubectl get ingress -n customer1
kubectl describe ingress customer1-ingress -n customer1
```

### 10.2 Certificate Issuance
- [ ] Verify Certificate resource created
- [ ] Check certificate status
- [ ] Verify certificate issued successfully
- [ ] Verify TLS secret created

**Test:**
```bash
kubectl get certificate -n customer1
kubectl describe certificate customer1-tls -n customer1
kubectl get secret customer1-tls -n customer1

# Check certificate details
kubectl get certificate customer1-tls -n customer1 -o yaml
```

### 10.3 DNS Configuration
- [ ] Get Traefik LoadBalancer external IP
- [ ] Create DNS A record for customer1.mercury.kubetest.uk
- [ ] Verify DNS resolution

**Test:**
```bash
# Get external IP
kubectl get svc -n traefik traefik-traefik -o jsonpath='{.status.loadBalancer.ingress[0].ip}'

# Test DNS resolution
nslookup customer1.mercury.kubetest.uk
dig customer1.mercury.kubetest.uk
```

### 10.4 End-to-End Connectivity
- [ ] Test HTTPS access to n8n
- [ ] Verify certificate validity
- [ ] Test n8n application functionality

**Test:**
```bash
# Test HTTPS connection
curl -I https://customer1.mercury.kubetest.uk

# Verify certificate
openssl s_client -connect customer1.mercury.kubetest.uk:443 -servername customer1.mercury.kubetest.uk </dev/null 2>/dev/null | openssl x509 -noout -dates -subject -issuer

# Access in browser
# https://customer1.mercury.kubetest.uk
```

---

## Bead 11: Production Certificate

### 11.1 Switch to Production ClusterIssuer
- [ ] Update Ingress annotation to use letsencrypt-prod
- [ ] Update TLS secret name
- [ ] Delete staging certificate
- [ ] Wait for production certificate

**Update:** `apps/base/customer1/ingress.yaml`
```yaml
annotations:
  cert-manager.io/cluster-issuer: letsencrypt-prod
spec:
  tls:
    - hosts:
        - customer1.mercury.kubetest.uk
      secretName: customer1-tls-prod
```

**Test:**
```bash
# Delete old staging certificate
kubectl delete certificate customer1-tls -n customer1
kubectl delete secret customer1-tls -n customer1

# Wait for new certificate
kubectl get certificate -n customer1 --watch

# Verify production certificate
kubectl describe certificate customer1-tls-prod -n customer1
```

---

## Bead 12: Disaster Recovery Testing

### 12.1 Backup Validation
- [ ] Trigger manual backup
- [ ] Verify backup in Azure Blob Storage
- [ ] Check backup completeness

**Test:**
```bash
kubectl cnpg backup customer1-db -n customer1
kubectl get backup -n customer1 --watch
az storage blob list --account-name alexmercurybackupsstaging --container-name customer1 --output table
```

### 12.2 Restore Test
- [ ] Create test data in database
- [ ] Perform backup
- [ ] Create new cluster from backup
- [ ] Verify data restored

**Test:**
```bash
# Create test data
kubectl cnpg psql customer1-db -n customer1 -- -c "CREATE TABLE test_restore(id serial, data text); INSERT INTO test_restore(data) VALUES('test1'),('test2');"

# Backup
kubectl cnpg backup customer1-db -n customer1

# Create restore cluster (modify database.yaml with bootstrap section)
# Verify data exists
kubectl cnpg psql customer1-db2 -n customer1 -- -c "SELECT * FROM test_restore;"
```

---

## Execution Order Summary

| Bead | Dependencies | Description |
|------|--------------|-------------|
| 0 | None | Prerequisites & Auth |
| 1 | Bead 0 | Core infrastructure (RG, Key Vault) |
| 2 | Bead 1 | AKS cluster deployment |
| 3 | Bead 2 | Flux CD installation |
| 4 | Bead 3 | Infrastructure controllers |
| 5 | Bead 4 | Infrastructure configs |
| 6 | Bead 1 | Backup infrastructure |
| 7 | Bead 2, 4 | Customer1 namespace & secrets |
| 8 | Bead 6, 7 | PostgreSQL database |
| 9 | Bead 8 | n8n application |
| 10 | Bead 4, 5, 9 | Ingress & TLS |
| 11 | Bead 10 | Production certificate |
| 12 | Bead 8 | DR testing |

---

## Rollback Procedures

Each bead can be rolled back independently:

- **Terraform resources:** `terraform destroy -target=<resource>`
- **Flux resources:** `flux delete kustomization <name>` or `flux suspend kustomization <name>`
- **Helm releases:** Managed by Flux - edit/delete HelmRelease manifest
- **K8s resources:** `kubectl delete -f <manifest>`

---

## Critical Configuration Values

These values must be correct or deployment will fail:

### From Azure
```bash
# Get these values and record them
az aks show --resource-group rg-cloud-course-aks --name mercury-staging \
  --query "addonProfiles.azureKeyvaultSecretsProvider.identity.clientId" -o tsv

az account show --query tenantId -o tsv

az keyvault show --name kv-mercury-staging --query name -o tsv
```

### In manifests
- `apps/staging/customer1/kustomization.yaml`: userAssignedIdentityID
- `apps/staging/customer1/kustomization.yaml`: tenantId
- `apps/base/customer1/secrets.yaml`: keyvaultName
- `apps/base/customer1/database.yaml`: destinationPath for backups
- `apps/base/customer1/ingress.yaml`: host, ingressClassName

---

## Common Issues & Solutions

### Issue: Pods stuck in ContainerCreating
**Cause:** SecretProviderClass has wrong userAssignedIdentityID or tenantId
**Solution:** Verify values match output from Azure CLI commands above

### Issue: Ingress returns 404
**Cause:** Wrong ingressClassName (should be `traefik-traefik`, not `traefik`)
**Solution:** Check `kubectl get ingressclass` and update Ingress manifest

### Issue: Database backup fails
**Cause:** Missing barman-cloud plugin or wrong Azure credentials
**Solution:** Deploy plugin-barman-cloud HelmRelease, verify SAS token in Key Vault

### Issue: Flux kustomization fails
**Cause:** CRD referenced before controller installed
**Solution:** Ensure dependency chain: controllers → configs → apps

### Issue: Certificate not issued
**Cause:** DNS challenge fails or rate limiting
**Solution:** Use letsencrypt-staging first, verify DNS working, check cert-manager logs

---

## Notes

- Always test in staging/dev before production
- Keep Terraform state backed up
- Document any deviations from plan
- Each bead should be fully tested before proceeding to the next
- Use letsencrypt-staging for initial testing to avoid rate limits
- Flux sync interval is 5 minutes - be patient or force reconcile
- Database cluster startup takes 2-3 minutes
