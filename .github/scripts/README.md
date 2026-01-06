# Customer Provisioning Scripts

This directory contains scripts and templates for automated customer provisioning in the mercury-gitops repository.

## Overview

The customer provisioning system automates the creation of:
- Cloudflare DNS records
- Kubernetes manifests (namespace, database, n8n deployment, ingress, etc.)
- Azure Key Vault secrets for database credentials
- Pull requests with all changes for review

## GitHub Workflow Usage

### Prerequisites

1. **Cloudflare API Token**: Store in GitHub Secrets as `CLOUDFLARE_DNS_KUBETEST_UK`
   - Go to: https://dash.cloudflare.com/profile/api-tokens
   - Create token with `Zone.DNS` edit permissions for `kubetest.uk`

2. **Traefik LoadBalancer IP**: Get the external IP of your Traefik service:
   ```bash
   kubectl get svc -n traefik traefik -o jsonpath='{.status.loadBalancer.ingress[0].ip}'
   ```

### Running the Workflow

1. Go to **Actions** tab in GitHub
2. Select **Provision New Customer** workflow
3. Click **Run workflow**
4. Fill in the parameters:
   - **customer_name**: e.g., `customer2`, `customer3` (must be `customerN` format)
   - **traefik_ip**: Your Traefik LoadBalancer IP (e.g., `20.123.45.67`)
   - **aks_identity_client_id**: (optional, default provided)
   - **azure_tenant_id**: (optional, default provided)
5. Click **Run workflow**

### What Happens

The workflow will:
1. ✅ Validate the customer name format
2. ✅ Create/update Cloudflare DNS A record: `customerN.mercury.kubetest.uk -> <traefik_ip>`
3. ✅ Generate Kubernetes manifests from templates
4. ✅ Update Terraform configuration to add Key Vault secrets
5. ✅ Create a pull request with all changes

### After Workflow Completes

1. **Review the PR**: Check the generated manifests
2. **Merge the PR**: This triggers Flux to deploy to the cluster
3. **Apply Terraform**:
   ```bash
   cd /path/to/mercury-gitops
   terraform plan
   terraform apply
   ```
4. **Monitor Flux deployment**:
   ```bash
   flux get kustomizations
   kubectl get pods -n customerN
   ```
5. **Access n8n**: https://customerN.mercury.kubetest.uk

## Manual Usage

You can also run the scripts manually:

### Provision Customer Manifests

```bash
python3 .github/scripts/provision-customer.py customer2 \
  --aks-identity-client-id "49ff401d-772c-4e31-b711-f4e621375ed6" \
  --azure-tenant-id "36e054ee-92ea-404f-97ee-2859b2462cd6"
```

### Update Terraform

```bash
python3 .github/scripts/update-terraform.py customer2
```

## Template Structure

Templates are located in `.github/scripts/templates/`:

```
templates/
├── base/
│   ├── namespace.yaml
│   ├── database.yaml
│   ├── secrets.yaml
│   ├── configmap.yaml
│   ├── storage.yaml
│   ├── deployment.yaml
│   ├── service.yaml
│   ├── ingress.yaml
│   └── kustomization.yaml
└── staging/
    └── kustomization.yaml
```

### Template Placeholders

- `{{CUSTOMER_NAME}}`: Replaced with customer name (e.g., `customer2`)
- `{{AKS_IDENTITY_CLIENT_ID}}`: AKS Key Vault Secrets Provider Client ID
- `{{AZURE_TENANT_ID}}`: Azure Tenant ID

## Directory Structure After Provisioning

```
apps/
├── base/
│   └── customerN/
│       ├── namespace.yaml
│       ├── database.yaml
│       ├── secrets.yaml
│       ├── configmap.yaml
│       ├── storage.yaml
│       ├── deployment.yaml
│       ├── service.yaml
│       ├── ingress.yaml
│       └── kustomization.yaml
└── staging/
    ├── customerN/
    │   └── kustomization.yaml
    └── kustomization.yaml (updated to include customerN)
```

## Customizing for a Customer

After provisioning, you can customize individual customers by:

1. **Editing base manifests**: Modify `apps/base/customerN/*.yaml`
2. **Adding staging patches**: Add patches to `apps/staging/customerN/kustomization.yaml`
3. **Commit and push**: Flux will automatically sync changes

## Troubleshooting

### DNS not resolving
- Verify Cloudflare DNS record exists: https://dash.cloudflare.com
- Check TTL (should be 1 = Auto)
- Wait a few minutes for DNS propagation

### Pod not starting
```bash
kubectl describe pod -n customerN <pod-name>
kubectl logs -n customerN <pod-name>
```

### Database connection errors
- Verify Key Vault secrets exist:
  ```bash
  az keyvault secret list --vault-name kv-mercury-staging
  ```
- Check SecretProviderClass:
  ```bash
  kubectl describe secretproviderclass -n customerN customerN-secrets
  ```

### Certificate not issued
```bash
kubectl describe certificate -n customerN customerN-tls
kubectl describe certificaterequest -n customerN
```

## Architecture

```
GitHub Actions Workflow
    ↓
1. Create Cloudflare DNS record
    ↓
2. Generate K8s manifests from templates
    ↓
3. Update Terraform (Key Vault secrets)
    ↓
4. Create Pull Request
    ↓
5. (After merge) Flux syncs to cluster
    ↓
6. (Manual) terraform apply creates secrets
    ↓
7. Pods start with secrets from Key Vault
```

## Security Notes

- **Secrets**: Never commit actual secrets to git
- **Key Vault**: All secrets stored in Azure Key Vault
- **CSI Driver**: Secrets mounted at runtime via CSI driver
- **TLS**: Automatic Let's Encrypt certificates via cert-manager
- **Cloudflare API Token**: Stored in GitHub Secrets, never exposed in logs

## Customer Deprovisioning

### Running the Deprovision Workflow

1. Go to **Actions** tab in GitHub
2. Select **Deprovision Customer** workflow
3. Click **Run workflow**
4. Fill in the parameters:
   - **customer_name**: e.g., `customer3` (must be `customerN` format)
   - **delete_dns**: Check to remove Cloudflare DNS record
5. Click **Run workflow**

### What Happens

The workflow will:
1. ✅ Validate the customer exists
2. ✅ Delete Cloudflare DNS A record (if selected)
3. ✅ Remove all Kubernetes manifests
4. ✅ Update Terraform to remove Key Vault secrets
5. ✅ Create a pull request with all cleanup changes

### After Workflow Completes

1. **Review the PR**: Check what will be deleted
2. **Merge the PR**: This triggers Flux to remove resources from the cluster
3. **Apply Terraform**:
   ```bash
   cd /path/to/mercury-gitops
   terraform plan
   terraform apply
   ```
4. **Verify deletion**:
   ```bash
   kubectl get namespace customerN  # should show "not found"
   az keyvault secret list --vault-name kv-mercury-staging | grep customerN  # should be empty
   ```

### Manual Deprovisioning

You can also run the scripts manually:

```bash
# Remove customer manifests
python3 .github/scripts/deprovision-customer.py customer3

# Remove Terraform resources
python3 .github/scripts/remove-terraform.py customer3

# Delete DNS record manually
# Go to https://dash.cloudflare.com and delete the A record
```

### What Gets Deleted

**Kubernetes Resources (after PR merge):**
- Namespace and all resources within it
- PostgreSQL database cluster and all data
- n8n deployment
- Persistent Volume Claims (all data is lost)
- Ingress and TLS certificates
- Azure Key Vault SecretProviderClass

**Azure Resources (after terraform apply):**
- Key Vault secrets for database credentials

**DNS (if selected):**
- Cloudflare A record for `customerN.mercury.kubetest.uk`

⚠️ **Warning:** All data is permanently deleted. This cannot be undone.

## Future Enhancements

- [ ] Automated Terraform apply after PR merge
- [x] Customer deletion workflow
- [ ] Custom database sizes per customer
- [ ] Multiple environments (staging, production)
- [ ] Slack/email notifications on provisioning/deprovisioning complete
- [ ] Backup customer data before deprovisioning
