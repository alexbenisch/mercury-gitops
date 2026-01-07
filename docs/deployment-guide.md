# Mercury AKS Cluster Deployment Guide

**Date**: 2026-01-06
**Purpose**: Step-by-step deployment guide incorporating lessons learned from 2026-01-05 troubleshooting

---

## Pre-Flight Checks (Critical - Do First!)

### 1. Cloudflare API Token Validation

**Why**: Invalid tokens caused multiple deployment failures. Both cert-manager and external-dns need working tokens.

```bash
# Set your environment variables
export ZONE_ID="0586507fe8e0c8bef795eb0d82b77cde"
export ACCOUNT_ID="884dbb82ad9c5e7acfa3bb414b808eb9"
export CF_TOKEN="your-cloudflare-token-here"

# Verify token is valid
curl -X GET "https://api.cloudflare.com/client/v4/accounts/${ACCOUNT_ID}/tokens/verify" \
  -H "Authorization: Bearer ${CF_TOKEN}"
# Expected: {"success": true, "result": {"status": "active"}}

# Verify zone access
curl -X GET "https://api.cloudflare.com/client/v4/zones?name=kubetest.uk" \
  -H "Authorization: Bearer ${CF_TOKEN}"
# Expected: Should return zone details with zone_id
```

**If token is invalid:**
1. Go to Cloudflare Dashboard → Profile → API Tokens
2. Create new token with:
   - **Permission 1**: Zone → Zone → Read
   - **Permission 2**: Zone → DNS → Edit
   - **Zone Resources**: Include → Specific zone → kubetest.uk
3. Save token immediately (can't view again!)
4. Re-run validation commands above

**Critical**: You need BOTH "Zone:Read" AND "DNS:Edit" permissions!

---

### 2. Azure Resource Verification

**Why**: Wrong Key Vault names and identity IDs caused configuration failures.

```bash
# Get AKS cluster info
az aks show --resource-group rg-cloud-course-aks --name mercury-staging \
  --query "[name,location,nodeResourceGroup]" -o table

# Get Key Vault name (verify it matches your configs)
az keyvault list --resource-group rg-cloud-course-aks \
  --query "[].name" -o tsv
# Expected output: kv-mercury-staging

# Get AKS CSI driver identity (for SecretProviderClass)
az aks show --resource-group rg-cloud-course-aks --name mercury-staging \
  --query "addonProfiles.azureKeyvaultSecretsProvider.identity.clientId" -o tsv
# Expected output: c15a54fe-c369-4aac-a46f-97bba232caae
```

**Record these values** - you'll need them for configuration files.

---

### 3. Key Vault Setup

```bash
# Store Cloudflare token in Azure Key Vault
az keyvault secret set \
  --vault-name kv-mercury-staging \
  --name cloudflare-dns-api-token \
  --value "${CF_TOKEN}"

# Verify secret was stored
az keyvault secret show \
  --vault-name kv-mercury-staging \
  --name cloudflare-dns-api-token \
  --query "value" -o tsv
# Should return your token (keep it secure!)
```

---

## Infrastructure Deployment

### Step 1: Terraform Infrastructure

```bash
# Navigate to terraform directory
cd terraform

# Initialize and validate
terraform init
terraform validate

# Plan and review changes
terraform plan -out=tfplan

# Apply infrastructure
terraform apply tfplan

# Get kubeconfig
az aks get-credentials \
  --resource-group rg-cloud-course-aks \
  --name mercury-staging \
  --overwrite-existing

# Verify cluster access
kubectl get nodes
```

**Expected**: 2 nodes with status "Ready"

---

### Step 2: Create Kubernetes Secrets (Before Flux!)

**Why**: Cert-manager and external-dns need these secrets immediately after deployment.

```bash
# Create external-dns namespace and secret
kubectl create namespace external-dns
kubectl create secret generic cloudflare-api-token \
  --namespace external-dns \
  --from-literal=api-token="${CF_TOKEN}"

# Create cert-manager namespace and secret
kubectl create namespace cert-manager
kubectl create secret generic cloudflare-api-token \
  --namespace cert-manager \
  --from-literal=api-token="${CF_TOKEN}"

# Verify secrets created
kubectl get secret cloudflare-api-token -n external-dns
kubectl get secret cloudflare-api-token -n cert-manager
```

**Critical**: Both namespaces need their own secret! Don't skip this step.

---

### Step 3: Verify Configuration Files

**Before pushing to Git**, verify these critical configurations:

#### A. External-DNS Domain Filters

```bash
# Check infrastructure/controllers/external-dns/release.yaml
cat infrastructure/controllers/external-dns/release.yaml | grep -A 2 "domainFilters"
```

**Must be**:
```yaml
domainFilters:
  - kubetest.uk  # Base zone name, NOT subdomains!
```

**Wrong examples to avoid**:
- `mercury.kubetest.uk` (subdomain)
- `customer1.mercury.kubetest.uk` (subdomain)

**Why**: External-DNS matches Cloudflare zone name (`kubetest.uk`) against this filter. Subdomains won't match.

#### B. SecretProviderClass

```bash
# Check apps/base/n8n/secret-provider-class.yaml
grep -A 5 "keyvaultName\|clientID" apps/base/n8n/secret-provider-class.yaml
```

**Must match**:
- `keyvaultName: kv-mercury-staging`
- `clientID: c15a54fe-c369-4aac-a46f-97bba232caae` (from Step 2.2 above)

#### C. Ingress Configuration

```bash
# Check apps/overlays/production/ingress.yaml
grep -A 3 "cert-manager.io\|host:" apps/overlays/production/ingress.yaml
```

**For initial testing** (use staging certificates):
```yaml
metadata:
  annotations:
    cert-manager.io/cluster-issuer: letsencrypt-staging
spec:
  tls:
    - hosts:
        - customer1.mercury.kubetest.uk
      secretName: n8n-tls-staging
  rules:
    - host: customer1.mercury.kubetest.uk  # Must match your DNS zone!
```

**After DNS works** (switch to production certificates):
```yaml
metadata:
  annotations:
    cert-manager.io/cluster-issuer: letsencrypt-prod
spec:
  tls:
    - secretName: n8n-tls-prod
```

#### D. Flux RBAC

```bash
# Check infrastructure/controllers/external-dns/rbac.yaml exists
ls -l infrastructure/controllers/external-dns/rbac.yaml
```

**Must contain**:
```yaml
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: flux-applier-external-dns
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: cluster-admin
subjects:
- kind: ServiceAccount
  name: flux-applier
  namespace: external-dns
```

**Why**: Flux service account needs cluster-admin to create CRDs.

---

### Step 4: Deploy with Flux

```bash
# Commit and push all changes
git add .
git commit -m "Deploy mercury cluster with validated config"
git push origin main

# Wait for Flux to sync (or force reconciliation)
flux reconcile source git mercury-system --with-source

# Monitor Flux reconciliation
watch flux get all -A
```

**Expected timeline**:
- GitRepository syncs: ~10 seconds
- Kustomization reconciles: ~30 seconds
- HelmReleases deploy: 1-3 minutes

---

### Step 5: Verify Infrastructure Controllers

#### A. Check External-DNS

```bash
# Check pod status
kubectl get pods -n external-dns
# Expected: external-dns-xxxxx  1/1  Running

# Check logs (most important!)
kubectl logs -n external-dns -l app.kubernetes.io/name=external-dns --tail=50
```

**Look for these SUCCESS indicators**:
```
level=info msg="Instantiating new Kubernetes client"
level=info msg="Using inCluster-config based on serviceaccount-token"
level=info msg="Created Kubernetes client"
level=info msg="Applying provider record filter for domains: [kubetest.uk]"
```

**BAD signs to watch for**:
- `level=debug msg="zone kubetest.uk not in domain filter"` → Fix domainFilters!
- `Error: 1000: Invalid API Token` → Fix Cloudflare token!
- `Error: 9109: Invalid access token` → Fix Cloudflare token permissions!

#### B. Check Cert-Manager

```bash
# Check all cert-manager pods
kubectl get pods -n cert-manager
# Expected: All 3 pods Running (cert-manager, webhook, cainjector)

# Check logs
kubectl logs -n cert-manager -l app=cert-manager --tail=30
```

---

### Step 6: Deploy Application and Verify DNS

```bash
# Check N8N deployment
kubectl get pods -n n8n
# Expected: n8n-xxxxx  1/1  Running

# Check ingress created
kubectl get ingress -n n8n
# Expected: NAME         CLASS   HOSTS                            ADDRESS          PORTS
#           n8n-ingress  nginx   customer1.mercury.kubetest.uk   48.209.187.37   80, 443

# Wait 1-2 minutes for external-dns to create records, then verify
kubectl logs -n external-dns -l app.kubernetes.io/name=external-dns --tail=20 | grep -i "create\|change"
```

**Expected log output**:
```
level=info msg="Desired change: CREATE customer1.mercury.kubetest.uk A [Id: /hostedzone/xxx]"
level=info msg="3 record(s) in zone kubetest.uk were successfully updated"
```

---

### Step 7: Verify DNS Records in Cloudflare

```bash
# List all DNS records in zone
curl -X GET "https://api.cloudflare.com/client/v4/zones/${ZONE_ID}/dns_records" \
  -H "Authorization: Bearer ${CF_TOKEN}" | \
  jq -r '.result[] | "\(.type)\t\(.name) -> \(.content)"'
```

**Expected output**:
```
A       customer1.mercury.kubetest.uk -> 48.209.187.37
TXT     ext-dns-customer1.mercury.kubetest.uk -> "heritage=external-dns,..."
TXT     ext-dns-a-customer1.mercury.kubetest.uk -> "heritage=external-dns,..."
```

**Test DNS resolution**:
```bash
nslookup customer1.mercury.kubetest.uk
# Should return the ingress IP address
```

---

### Step 8: Certificate Management

#### A. Monitor Certificate Creation (Staging First!)

```bash
# Watch certificate status
kubectl get certificate -n n8n -w
# NAME              READY   SECRET            AGE
# n8n-tls-staging   False   n8n-tls-staging   10s  <- Wait for True

# Check certificate details
kubectl describe certificate n8n-tls-staging -n n8n

# Check challenges (DNS-01 challenge creates TXT record)
kubectl get challenges -n n8n
# Should show challenge completing within 1-2 minutes
```

**Monitor cert-manager logs during challenge**:
```bash
kubectl logs -n cert-manager -l app=cert-manager --tail=50 -f
```

**Look for**:
- `Successfully created TXT record`
- `Certificate issued successfully`

#### B. Verify Staging Certificate Works

```bash
# Test HTTPS (will show certificate warning - expected for staging!)
curl -I https://customer1.mercury.kubetest.uk
# Should return HTTP 200 (ignore SSL warning)

# Check certificate issuer
echo | openssl s_client -connect customer1.mercury.kubetest.uk:443 \
  -servername customer1.mercury.kubetest.uk 2>/dev/null | \
  openssl x509 -noout -issuer
# Expected: issuer=CN = Fake LE Intermediate X1
```

#### C. Switch to Production Certificates

**Only after staging certificates work!**

```bash
# Edit ingress file
vi apps/overlays/production/ingress.yaml
```

**Change**:
```yaml
metadata:
  annotations:
    cert-manager.io/cluster-issuer: letsencrypt-prod  # Changed from staging
spec:
  tls:
    - hosts:
        - customer1.mercury.kubetest.uk
      secretName: n8n-tls-prod  # Changed from staging
```

**Deploy production certificate**:
```bash
git add apps/overlays/production/ingress.yaml
git commit -m "Switch n8n ingress to Let's Encrypt production certificates"
git push

# Reconcile with source
flux reconcile kustomization mercury-system-apps --with-source

# Monitor new certificate
kubectl get certificate -n n8n -w
```

**Wait for certificate to be Ready (1-2 minutes)**, then verify:
```bash
# Test HTTPS (should work without warnings now!)
curl -I https://customer1.mercury.kubetest.uk
# Expected: HTTP/2 200

# Verify production certificate
echo | openssl s_client -connect customer1.mercury.kubetest.uk:443 \
  -servername customer1.mercury.kubetest.uk 2>/dev/null | \
  openssl x509 -noout -issuer -subject -dates
# Expected issuer: CN = R12 or R11 (Let's Encrypt production)
```

---

## Making Changes via Git (Proper Flux Workflow)

### The Right Way

When you make changes to configuration files and push to Git:

```bash
# Make your changes
vi infrastructure/controllers/external-dns/release.yaml

# Commit and push
git add .
git commit -m "Update external-dns configuration"
git push

# Reconcile with --with-source flag (CRITICAL!)
flux reconcile kustomization mercury-system-infra-controllers --with-source
```

**Why `--with-source` matters**: This tells Flux to:
1. Pull latest Git revision
2. Apply new manifests from Git
3. Update the HelmRelease

### Alternative: Layer-by-Layer Reconciliation

```bash
# Step 1: Fetch latest from Git
flux reconcile source git mercury-system

# Step 2: Apply infrastructure controllers
flux reconcile kustomization mercury-system-infra-controllers

# Step 3: Reconcile specific HelmRelease
flux reconcile helmrelease external-dns -n external-dns
```

### Wrong Way (Don't Do This!)

```bash
# This ONLY reconciles the HelmRelease, doesn't fetch new Git changes!
flux reconcile helmrelease external-dns -n external-dns
# Result: Uses old cached revision, your changes won't apply
```

---

## Troubleshooting Quick Reference

### Issue: External-DNS Not Creating Records

**Check 1**: Verify domainFilters
```bash
kubectl get helmrelease external-dns -n external-dns -o yaml | grep -A 2 domainFilters
# Must show: - kubetest.uk (base zone, not subdomain!)
```

**Check 2**: Verify Cloudflare token
```bash
kubectl logs -n external-dns -l app.kubernetes.io/name=external-dns --tail=50 | grep -i error
# Look for: "Invalid API Token" or "zone X not in domain filter"
```

**Fix**: Update token or domainFilters, then reconcile with `--with-source`

---

### Issue: Certificate Not Issuing

**Check 1**: Cert-manager logs
```bash
kubectl logs -n cert-manager -l app=cert-manager --tail=50 | grep -i error
# Look for: "Invalid access token", "authentication failures"
```

**Check 2**: Certificate status
```bash
kubectl describe certificate n8n-tls-prod -n n8n
# Look at "Events" section for errors
```

**Check 3**: Challenge status
```bash
kubectl get challenges -n n8n
kubectl describe challenge <challenge-name> -n n8n
```

**Fix**: Update Cloudflare token in cert-manager namespace, restart cert-manager:
```bash
kubectl create secret generic cloudflare-api-token \
  --namespace cert-manager \
  --from-literal=api-token="${NEW_TOKEN}" \
  --dry-run=client -o yaml | kubectl apply -f -

kubectl rollout restart deployment cert-manager -n cert-manager
```

---

### Issue: Flux Not Picking Up Git Changes

**Check**: Git source revision
```bash
flux get sources git
# Note the REVISION sha

git log --oneline -1
# Should match the Flux revision
```

**Fix**: Always use `--with-source` flag:
```bash
flux reconcile kustomization <name> --with-source
```

---

### Issue: "ServiceAccount flux-applier does not have permissions"

**Check**: ClusterRoleBinding exists
```bash
kubectl get clusterrolebinding flux-applier-external-dns
```

**Fix**: Apply RBAC configuration
```bash
kubectl apply -f infrastructure/controllers/external-dns/rbac.yaml
```

---

## Validation Checklist

After deployment, verify everything is working:

- [ ] All Flux kustomizations are Ready
  ```bash
  flux get kustomizations
  ```

- [ ] All HelmReleases are Ready
  ```bash
  flux get helmreleases -A
  ```

- [ ] External-DNS pod is Running
  ```bash
  kubectl get pods -n external-dns
  ```

- [ ] Cert-manager pods are Running (3 pods)
  ```bash
  kubectl get pods -n cert-manager
  ```

- [ ] N8N pod is Running
  ```bash
  kubectl get pods -n n8n
  ```

- [ ] Ingress has external IP
  ```bash
  kubectl get ingress -n n8n
  ```

- [ ] DNS records exist in Cloudflare
  ```bash
  curl -X GET "https://api.cloudflare.com/client/v4/zones/${ZONE_ID}/dns_records" \
    -H "Authorization: Bearer ${CF_TOKEN}" | jq -r '.result[].name'
  ```

- [ ] DNS resolves correctly
  ```bash
  nslookup customer1.mercury.kubetest.uk
  ```

- [ ] Certificate is Ready
  ```bash
  kubectl get certificate -n n8n
  ```

- [ ] HTTPS works without errors
  ```bash
  curl -I https://customer1.mercury.kubetest.uk
  ```

---

## Reference Information

### Environment Variables to Set

```bash
export ZONE_ID="0586507fe8e0c8bef795eb0d82b77cde"
export ACCOUNT_ID="884dbb82ad9c5e7acfa3bb414b808eb9"
export CF_TOKEN="your-cloudflare-api-token"
```

### Azure Resources

- **Subscription ID**: `6280aae8-f9e7-4540-9aa3-646c95dd57d1`
- **Resource Group**: `rg-cloud-course-aks`
- **AKS Cluster**: `mercury-staging`
- **Key Vault**: `kv-mercury-staging`
- **Region**: `northeurope`
- **Node Count**: 2
- **Node Size**: `Standard_D2s_v3`

### Kubernetes Configuration

- **FluxCD Namespace**: `flux-system`
- **External-DNS Namespace**: `external-dns`
- **Cert-Manager Namespace**: `cert-manager`
- **App Namespace**: `n8n`
- **Ingress Controller**: NGINX
- **DNS Provider**: Cloudflare
- **Certificate Issuer**: Let's Encrypt

### Domain Configuration

- **Base Zone**: `kubetest.uk`
- **Application Domain**: `customer1.mercury.kubetest.uk`
- **Cloudflare Zone ID**: `0586507fe8e0c8bef795eb0d82b77cde`

### Git Repository

- **URL**: `ssh://git@github.com/alexbenisch/mercury`
- **Branch**: `main`
- **Sync Interval**: 600 seconds (10 minutes)

---

## Common Commands Reference

```bash
# Flux status
flux get all -A
flux get sources git
flux get kustomizations
flux get helmreleases -A

# Force reconciliation (after git push)
flux reconcile source git mercury-system --with-source
flux reconcile kustomization mercury-system-infra-controllers --with-source
flux reconcile kustomization mercury-system-infra-configs --with-source
flux reconcile kustomization mercury-system-apps --with-source

# Check specific component
kubectl get pods -n external-dns
kubectl logs -n external-dns -l app.kubernetes.io/name=external-dns --tail=50
kubectl get pods -n cert-manager
kubectl logs -n cert-manager -l app=cert-manager --tail=50

# Check certificates
kubectl get certificate -A
kubectl describe certificate n8n-tls-prod -n n8n
kubectl get challenges -A

# Check ingress
kubectl get ingress -A
kubectl describe ingress n8n-ingress -n n8n

# Cloudflare DNS verification
curl -X GET "https://api.cloudflare.com/client/v4/zones/${ZONE_ID}/dns_records" \
  -H "Authorization: Bearer ${CF_TOKEN}" | jq -r '.result[] | "\(.name) -> \(.content)"'

# Test endpoints
nslookup customer1.mercury.kubetest.uk
curl -I https://customer1.mercury.kubetest.uk
```

---

## Success Criteria

Your deployment is successful when:

1. All Flux resources show `Ready=True`
2. External-DNS successfully creates DNS records in Cloudflare
3. DNS resolves to correct ingress IP
4. Certificate is issued and `Ready=True`
5. HTTPS endpoint returns HTTP 200 with valid certificate
6. Application is accessible at `https://customer1.mercury.kubetest.uk`

---

## Notes for Tomorrow

1. **Start early**: DNS propagation and certificate issuance take time
2. **Validate before deploying**: Check all configuration values match actual resources
3. **Use staging certificates first**: Switch to production only after everything works
4. **Monitor logs continuously**: Catch issues early before they cascade
5. **Commit often**: Small, incremental changes are easier to troubleshoot
6. **Document deviations**: If you encounter new issues, add them to troubleshooting-2026-01-06.md

Good luck with your deployment tomorrow!

---

# CloudNativePG Backup Configuration

**Date**: 2026-01-07
**Purpose**: Configure automated PostgreSQL backups to Azure Blob Storage using CloudNativePG barman-cloud integration

---

## Overview

This section documents the complete setup of automated backups for CloudNativePG PostgreSQL clusters, including:
- Azure Storage Account creation
- SAS token generation and Key Vault storage
- CloudNativePG backup configuration
- Scheduled backup automation
- Common pitfalls and solutions

---

## Prerequisites Validation

Before starting backup configuration, verify these tools are installed:

```bash
# Check cmctl (cert-manager CLI)
cmctl version
# Required for cert-manager operations

# Check kubectl cnpg plugin
kubectl cnpg version
# Required for backup operations
```

**Installation (using mise)**:
- cmctl: https://cert-manager.io/docs/reference/cmctl/#installation
- barman-cloud plugin: https://cloudnative-pg.io/plugin-barman-cloud/docs/installation/

**Critical Requirement**: CloudNativePG operator version 1.26+ must be installed
```bash
kubectl get deployment -n cnpg-system cnpg-controller-manager \
  -o jsonpath="{.spec.template.spec.containers[*].image}"
# Expected: ghcr.io/cloudnative-pg/postgresql:1.27.1 or newer
```

---

## Step 1: Azure Storage Infrastructure

### 1.1 Add Backup Resources to Terraform

Add the following to your main `main.tf`:

```hcl
## CNPG Backup Storage

resource "azurerm_storage_account" "cnpg_backups" {
  name                     = "alexmercurybackup"  # Max 24 chars, lowercase only
  resource_group_name      = azurerm_resource_group.aks.name
  location                 = azurerm_resource_group.aks.location
  account_tier             = "Standard"
  account_replication_type = "LRS"
  min_tls_version          = "TLS1_2"

  blob_properties {
    versioning_enabled = true
  }
}

resource "azurerm_storage_container" "customer1" {
  name                  = "customer1"
  storage_account_id    = azurerm_storage_account.cnpg_backups.id
  container_access_type = "private"
}

data "azurerm_storage_account_blob_container_sas" "customer1" {
  connection_string = azurerm_storage_account.cnpg_backups.primary_connection_string
  container_name    = azurerm_storage_container.customer1.name
  https_only        = true

  start  = timestamp()
  expiry = timeadd(timestamp(), "17520h") # 2 years

  permissions {
    read   = true
    write  = true
    delete = true
    list   = true
    add    = true
    create = true
  }
}

resource "azurerm_key_vault_secret" "storage_account_name" {
  name         = "storage-account-name"
  value        = azurerm_storage_account.cnpg_backups.name
  key_vault_id = azurerm_key_vault.mercury_vault.id

  depends_on = [azurerm_role_assignment.kv_admin]
}

resource "azurerm_key_vault_secret" "customer1_blob_sas" {
  name         = "customer1-blob-sas"
  value        = data.azurerm_storage_account_blob_container_sas.customer1.sas
  key_vault_id = azurerm_key_vault.mercury_vault.id

  depends_on = [azurerm_role_assignment.kv_admin]
}

output "storage_account_name" {
  value = azurerm_storage_account.cnpg_backups.name
}

output "customer1_backup_path" {
  value       = "${azurerm_storage_account.cnpg_backups.primary_blob_endpoint}customer1"
  description = "CNPG backup destination path for customer1"
}
```

### 1.2 Apply Terraform

```bash
# Plan and review
terraform plan

# Apply changes
terraform apply

# Verify outputs
terraform output storage_account_name
terraform output customer1_backup_path
```

**Expected outputs**:
- `storage_account_name = "alexmercurybackup"`
- `customer1_backup_path = "https://alexmercurybackup.blob.core.windows.net/customer1"`

### 1.3 Verify Azure Resources

```bash
# Verify storage account
az storage account show \
  --name alexmercurybackup \
  --resource-group rg-cloud-course-aks \
  --query "{name:name, location:location, sku:sku.name}" -o table

# Verify container
az storage container list \
  --account-name alexmercurybackup \
  --query "[].name" -o tsv

# Verify Key Vault secrets
az keyvault secret list \
  --vault-name kv-mercury-staging \
  --query "[?contains(name, 'storage') || contains(name, 'blob')].name" -o tsv
```

**Expected**: You should see `storage-account-name` and `customer1-blob-sas` secrets.

---

## Step 2: Kubernetes Backup Configuration

### 2.1 Update SecretProviderClass

Add backup credentials to `apps/base/customer1/secrets.yaml`:

```yaml
apiVersion: secrets-store.csi.x-k8s.io/v1
kind: SecretProviderClass
metadata:
  name: customer1-secrets
spec:
  provider: azure
  parameters:
    usePodIdentity: "false"
    useVMManagedIdentity: "true"
    userAssignedIdentityID: "${AKS_KEYVAULT_IDENTITY_CLIENT_ID}"
    keyvaultName: "kv-mercury-staging"
    tenantId: "${AZURE_TENANT_ID}"
    objects: |
      array:
        - |
          objectName: customer1-db-user
          objectType: secret
        - |
          objectName: customer1-db-password
          objectType: secret
        - |
          objectName: storage-account-name  # Added for backups
          objectType: secret
        - |
          objectName: customer1-blob-sas   # Added for backups
          objectType: secret
  secretObjects:
    - secretName: customer1-db-credentials
      type: kubernetes.io/basic-auth
      data:
        - objectName: customer1-db-user
          key: username
        - objectName: customer1-db-password
          key: password
    - secretName: customer1-n8n-env
      type: Opaque
      data:
        - objectName: customer1-db-user
          key: DB_POSTGRESDB_USER
        - objectName: customer1-db-password
          key: DB_POSTGRESDB_PASSWORD
    - secretName: customer1-backup-creds  # New secret for backups
      type: Opaque
      data:
        - objectName: storage-account-name
          key: storage-account-name
        - objectName: customer1-blob-sas
          key: customer1-blob-sas
```

### 2.2 Create ObjectStore Resource

Create `apps/base/customer1/objectstore.yaml`:

```yaml
apiVersion: barmancloud.cnpg.io/v1
kind: ObjectStore
metadata:
  name: customer1-objectstore
spec:
  configuration:
    destinationPath: "https://STORAGE_ACCOUNT.blob.core.windows.net/customer1"
    azureCredentials:
      storageAccount:
        name: customer1-backup-creds
        key: storage-account-name
      storageSasToken:
        name: customer1-backup-creds
        key: customer1-blob-sas
  retentionPolicy: "14d"
```

**Note**: The destinationPath placeholder will be patched in the staging overlay.

### 2.3 Update Cluster Configuration

Update `apps/base/customer1/database.yaml`:

```yaml
apiVersion: postgresql.cnpg.io/v1
kind: Cluster
metadata:
  name: customer1-db
spec:
  instances: 3

  bootstrap:
    initdb:
      database: app
      owner: app
      secret:
        name: customer1-db-credentials

  storage:
    size: 1Gi

  backup:
    barmanObjectStore:
      destinationPath: "https://STORAGE_ACCOUNT.blob.core.windows.net/customer1"
      azureCredentials:
        storageAccount:
          name: customer1-backup-creds
          key: storage-account-name
        storageSasToken:
          name: customer1-backup-creds
          key: customer1-blob-sas
```

**Critical**: Do NOT add the barman-cloud plugin when using `backup.barmanObjectStore` - they conflict!

### 2.4 Create Scheduled Backup

Create `apps/base/customer1/scheduled-backup.yaml`:

```yaml
apiVersion: postgresql.cnpg.io/v1
kind: ScheduledBackup
metadata:
  name: customer1-db-backup
spec:
  schedule: "0 */5 * * * *"  # Every 5 minutes (adjust as needed)
  backupOwnerReference: cluster
  cluster:
    name: customer1-db
```

**Schedule format**: Standard cron format with 6 fields (seconds included)
- `"0 */5 * * * *"` = Every 5 minutes
- `"0 0 3 * * *"` = Daily at 3 AM

### 2.5 Update Kustomization Files

Update `apps/base/customer1/kustomization.yaml`:

```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
namespace: customer1
resources:
  - namespace.yaml
  - secrets.yaml
  - objectstore.yaml        # Added
  - database.yaml
  - scheduled-backup.yaml   # Added
  - configmap.yaml
  - storage.yaml
  - deployment.yaml
  - service.yaml
  - ingress.yaml
```

Update `apps/staging/customer1/kustomization.yaml`:

```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - ../../base/customer1/
patches:
  - target:
      kind: SecretProviderClass
      name: customer1-secrets
    patch: |-
      - op: replace
        path: /spec/parameters/userAssignedIdentityID
        value: "48603787-7f9f-4c17-9071-677bcae61660"
      - op: replace
        path: /spec/parameters/tenantId
        value: "36e054ee-92ea-404f-97ee-2859b2462cd6"
  - target:
      kind: ObjectStore
      name: customer1-objectstore
    patch: |-
      - op: replace
        path: /spec/configuration/destinationPath
        value: "https://alexmercurybackup.blob.core.windows.net/customer1"
  - target:
      kind: Cluster
      name: customer1-db
    patch: |-
      - op: replace
        path: /spec/backup/barmanObjectStore/destinationPath
        value: "https://alexmercurybackup.blob.core.windows.net/customer1"
```

---

## Step 3: Deploy and Verify

### 3.1 Commit and Push

```bash
git add main.tf apps/base/customer1/ apps/staging/customer1/
git commit -m "feat: add CloudNativePG backup configuration"
git push origin main
```

### 3.2 Reconcile Flux

```bash
# Update Git source
flux reconcile source git mercury-system

# Apply configuration
flux reconcile kustomization mercury-system-apps
```

### 3.3 Verify Backup Resources

```bash
# Check ObjectStore
kubectl get objectstore -n customer1
# NAME                      AGE
# customer1-objectstore     1m

# Check ScheduledBackup
kubectl get scheduledbackup -n customer1
# NAME                   AGE   CLUSTER        LAST BACKUP
# customer1-db-backup    1m    customer1-db

# Check backup secret (requires pod to mount SecretProviderClass)
kubectl get secret customer1-backup-creds -n customer1
```

**If secret doesn't exist**: Restart a pod that mounts the SecretProviderClass:

```bash
kubectl rollout restart deployment customer1-n8n -n customer1
sleep 15
kubectl get secret customer1-backup-creds -n customer1
```

### 3.4 Verify Cluster Backup Configuration

```bash
# Check cluster status
kubectl cnpg status -n customer1 customer1-db

# Look for backup section
kubectl get cluster customer1-db -n customer1 -o yaml | grep -A 15 "backup:"
```

**Expected output**:
```yaml
backup:
  barmanObjectStore:
    azureCredentials:
      storageAccount:
        key: storage-account-name
        name: customer1-backup-creds
      storageSasToken:
        key: customer1-blob-sas
        name: customer1-backup-creds
    destinationPath: https://alexmercurybackup.blob.core.windows.net/customer1
```

### 3.5 Create Manual Backup

```bash
# Create backup
kubectl cnpg backup customer1-db -n customer1

# Check backup status
kubectl get backup -n customer1

# Wait for completion
kubectl get backup -n customer1 -w
```

**Expected output**:
```
NAME                          AGE   CLUSTER        METHOD              PHASE
customer1-db-20260107172424   28s   customer1-db   barmanObjectStore   completed
```

### 3.6 Verify Backup in Azure Storage

```bash
# List backup files
az storage blob list \
  --account-name alexmercurybackup \
  --container-name customer1 \
  --query "[].name" --output tsv | head -20
```

**Expected structure**:
```
customer1-db/base/20260107T172001/backup.info
customer1-db/base/20260107T172001/data.tar
customer1-db/wals/0000000100000000/000000010000000000000023
```

### 3.7 Check Continuous Backup Status

```bash
kubectl cnpg status -n customer1 customer1-db | grep -A 10 "Continuous Backup"
```

**Expected output**:
```
Continuous Backup status
First Point of Recoverability:  2026-01-07T17:20:05Z
Working WAL archiving:          OK
WALs waiting to be archived:    0
Last Archived WAL:              000000010000000000000023
```

---

## Common Issues and Solutions

### Issue 1: "Cannot proceed with backup as cluster has no backup section"

**Symptoms**:
```bash
kubectl get backup -n customer1
# NAME                    PHASE    ERROR
# customer1-db-backup     failed   cannot proceed with backup as the cluster has no backup section
```

**Root Cause**: The `backup.barmanObjectStore` section is missing or incorrectly configured in the Cluster spec.

**Solution**:
```bash
# Verify cluster has backup section
kubectl get cluster customer1-db -n customer1 -o yaml | grep -A 10 "backup:"

# If missing, add backup section to database.yaml and redeploy
```

---

### Issue 2: barman-cloud plugin conflicts with barmanObjectStore

**Symptoms**:
```bash
flux get kustomizations
# ERROR: Cannot enable a WAL archiver plugin when barmanObjectStore is configured
```

**Root Cause**: Using both `spec.plugins` with barman-cloud AND `spec.backup.barmanObjectStore` causes a conflict.

**Solution**: Remove the plugins section - `barmanObjectStore` handles WAL archiving automatically:

```yaml
# Remove this from database.yaml:
plugins:
  - name: barman-cloud.cloudnative-pg.io
    isWALArchiver: true
    parameters:
      barmanObjectName: customer1-objectstore
```

---

### Issue 3: backup-creds secret not created

**Symptoms**:
```bash
kubectl get secret customer1-backup-creds -n customer1
# Error from server (NotFound): secrets "customer1-backup-creds" not found
```

**Root Cause**: SecretProviderClass secrets are only created when a pod mounts the volume.

**Solution**: Restart a pod that uses the SecretProviderClass:

```bash
kubectl rollout restart deployment customer1-n8n -n customer1

# Wait for pod to start
kubectl wait --for=condition=ready pod -l app=customer1-n8n -n customer1 --timeout=60s

# Verify secret created
kubectl get secret customer1-backup-creds -n customer1
```

---

### Issue 4: Storage account name too long

**Symptoms**:
```
Error: name ("alexmercurybackupsstaging") can only consist of lowercase letters and numbers,
and must be between 3 and 24 characters long
```

**Solution**: Azure storage account names have a 24-character limit. Use a shorter name:

```hcl
resource "azurerm_storage_account" "cnpg_backups" {
  name = "alexmercurybackup"  # 18 chars - OK!
  # ...
}
```

---

### Issue 5: barmanObjectName field not declared in schema

**Symptoms**:
```
field not declared in schema: .spec.backup.barmanObjectStore.barmanObjectName
```

**Root Cause**: The `backup.barmanObjectStore` section doesn't accept `barmanObjectName`. It needs the actual configuration.

**Solution**: Use full configuration in backup section:

```yaml
# Wrong:
backup:
  barmanObjectStore:
    barmanObjectName: customer1-objectstore  # This field doesn't exist!

# Correct:
backup:
  barmanObjectStore:
    destinationPath: "https://alexmercurybackup.blob.core.windows.net/customer1"
    azureCredentials:
      storageAccount:
        name: customer1-backup-creds
        key: storage-account-name
```

---

## Validation Checklist

After deployment, verify:

- [ ] Storage account exists in Azure
  ```bash
  az storage account show --name alexmercurybackup --resource-group rg-cloud-course-aks
  ```

- [ ] Storage container exists
  ```bash
  az storage container list --account-name alexmercurybackup --query "[].name" -o tsv
  ```

- [ ] Key Vault secrets exist
  ```bash
  az keyvault secret list --vault-name kv-mercury-staging | grep -E "storage|blob"
  ```

- [ ] ObjectStore resource created
  ```bash
  kubectl get objectstore -n customer1
  ```

- [ ] ScheduledBackup resource created
  ```bash
  kubectl get scheduledbackup -n customer1
  ```

- [ ] Backup credentials secret exists
  ```bash
  kubectl get secret customer1-backup-creds -n customer1
  ```

- [ ] Cluster has backup configuration
  ```bash
  kubectl get cluster customer1-db -n customer1 -o yaml | grep "backup:"
  ```

- [ ] WAL archiving is working
  ```bash
  kubectl cnpg status -n customer1 customer1-db | grep "Working WAL"
  # Expected: Working WAL archiving: OK
  ```

- [ ] Manual backup succeeds
  ```bash
  kubectl cnpg backup customer1-db -n customer1
  kubectl get backup -n customer1
  # Expected: PHASE = completed
  ```

- [ ] Backup files exist in Azure Storage
  ```bash
  az storage blob list --account-name alexmercurybackup --container-name customer1
  ```

---

## Key Learnings

### 1. Configuration Structure

**CloudNativePG has two ways to configure backups**:
- **barmanObjectStore (recommended)**: Built-in backup configuration in Cluster spec
- **barman-cloud plugin**: External plugin - conflicts with barmanObjectStore

**Use barmanObjectStore for simplicity** - it handles both backups and WAL archiving.

### 2. SecretProviderClass Behavior

Secrets defined in `secretObjects` are **only created when a pod mounts the volume**. This means:
- Adding new secrets requires restarting pods
- Secrets won't exist until first pod mount
- Use `kubectl rollout restart` to trigger secret creation

### 3. Terraform State Management

When adding backup resources to existing Terraform:
- Always run in the main Terraform directory (not phase-6-cnpg)
- Use correct subscription ID
- Verify storage account names are under 24 characters
- SAS tokens have expiration - set appropriately (we used 2 years)

### 4. GitOps Workflow

For backup configuration changes:
```bash
# 1. Make changes to YAML files
# 2. Commit and push
git add . && git commit -m "Update backup config" && git push

# 3. Force Flux reconciliation
flux reconcile source git mercury-system
flux reconcile kustomization mercury-system-apps

# 4. Verify deployment
kubectl get backup -n customer1
```

### 5. Backup Schedule Format

CloudNativePG uses 6-field cron format (includes seconds):
```
┌───────────── second (0-59)
│ ┌───────────── minute (0-59)
│ │ ┌───────────── hour (0-23)
│ │ │ ┌───────────── day of month (1-31)
│ │ │ │ ┌───────────── month (1-12)
│ │ │ │ │ ┌───────────── day of week (0-6)
│ │ │ │ │ │
0 */5 * * * *  = Every 5 minutes
0 0 3 * * *    = Daily at 3 AM
```

---

## Reference Commands

```bash
# Backup operations
kubectl cnpg backup <cluster-name> -n <namespace>
kubectl get backup -n <namespace>
kubectl describe backup <backup-name> -n <namespace>

# Cluster status
kubectl cnpg status -n <namespace> <cluster-name>
kubectl get cluster -n <namespace>

# Azure storage
az storage account show --name <account-name> --resource-group <rg-name>
az storage blob list --account-name <account-name> --container-name <container-name>

# Key Vault
az keyvault secret list --vault-name <vault-name>
az keyvault secret show --vault-name <vault-name> --name <secret-name>

# Flux
flux reconcile source git mercury-system
flux reconcile kustomization mercury-system-apps
flux get kustomizations
```

---

## Next Steps

With backups configured, consider:

1. **Test Recovery**: Practice restoring from backup to a new cluster
2. **Monitor Backup Size**: Set up alerts for storage growth
3. **Retention Policy**: Adjust `retentionPolicy` based on requirements
4. **Backup Schedule**: Optimize schedule based on data change rate
5. **Disaster Recovery**: Document recovery procedures
6. **Cost Monitoring**: Track Azure Storage costs for backups

---

**Backup Configuration Complete!** ✅

Your PostgreSQL cluster now has:
- Automated WAL archiving to Azure Blob Storage
- Scheduled backups every 5 minutes
- 14-day retention policy
- Manual backup capability via `kubectl cnpg backup`
