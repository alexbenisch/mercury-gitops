# Terraform Setup Guide

## Quick Start

### 1. Create Your Variables File

Copy the example file and customize it:

```bash
cp terraform.tfvars.example terraform.tfvars
```

### 2. Edit terraform.tfvars

Update the following required values:

```hcl
# REQUIRED: Your Azure subscription ID
subscription_id = "your-subscription-id-here"
```

Get your subscription ID:
```bash
az account show --query id -o tsv
```

### 3. Customize Optional Values

The following have sensible defaults but can be customized:

- **resource_group_name**: Default is `rg-cloud-course-aks`
- **location**: Default is `North Europe`
- **cluster_name**: Default is `mercury-staging`
- **key_vault_name**: Must be globally unique (default: `kv-mercury-staging`)
- **storage_account_name**: Must be globally unique, 3-24 chars, lowercase/numbers only (default: `alexmercurybackup`)

### 4. Initialize and Deploy

```bash
# Initialize Terraform
terraform init

# Validate configuration
terraform validate

# Preview changes
terraform plan

# Apply infrastructure
terraform apply
```

## Variable Reference

### Required Variables

| Variable | Description | How to Get |
|----------|-------------|------------|
| `subscription_id` | Azure subscription ID | `az account show --query id -o tsv` |

### Optional Variables (with defaults)

| Variable | Default | Description |
|----------|---------|-------------|
| `resource_group_name` | `rg-cloud-course-aks` | Resource group name |
| `location` | `North Europe` | Azure region |
| `cluster_name` | `mercury-staging` | AKS cluster name |
| `kubernetes_version` | `1.32.0` | Kubernetes version |
| `node_count` | `2` | Number of nodes |
| `node_vm_size` | `Standard_D2s_v3` | VM size for nodes |
| `key_vault_name` | `kv-mercury-staging` | Key Vault name (must be unique) |
| `storage_account_name` | `alexmercurybackup` | Storage account for backups (must be unique) |
| `customer1_db_username` | `app` | Database username |
| `flux_git_repo_url` | `ssh://git@github.com/alexbenisch/mercury-gitops` | Flux Git repo |
| `flux_git_branch` | `main` | Flux Git branch |
| `flux_ssh_key_path` | `~/.ssh/mercury` | SSH key for Flux |

## Important Notes

### Globally Unique Names

These resources require globally unique names across all of Azure:

- **Key Vault name** (`key_vault_name`)
  - 3-24 characters
  - Alphanumeric and hyphens
  - Must start with letter

- **Storage Account name** (`storage_account_name`)
  - 3-24 characters
  - Lowercase letters and numbers only
  - No hyphens or special characters

If you get a "name already exists" error, change these values to something unique.

### SSH Key for Flux

Before running `terraform apply`, ensure your SSH key exists:

```bash
# Check if key exists
ls -la ~/.ssh/mercury

# If not, create it
ssh-keygen -t ed25519 -f ~/.ssh/mercury -C "flux@mercury-gitops"

# Add public key to GitHub
cat ~/.ssh/mercury.pub
# Copy output and add as deploy key in GitHub repo settings
```

### Database Password

The database password is automatically generated and stored in Azure Key Vault as `customer1-db-password`. It will be 24 characters long (alphanumeric only).

To view it after deployment:

```bash
az keyvault secret show \
  --vault-name $(terraform output -raw key_vault_name) \
  --name customer1-db-password \
  --query value -o tsv
```

## Outputs

After successful deployment, Terraform provides these outputs:

```bash
# View all outputs
terraform output

# Get specific output
terraform output key_vault_name
terraform output aks_keyvault_secrets_provider_client_id
terraform output customer1_backup_path
```

## Useful Commands

```bash
# Format Terraform files
terraform fmt

# Validate configuration
terraform validate

# Show current state
terraform show

# List resources
terraform state list

# Get specific resource details
terraform state show azurerm_kubernetes_cluster.main

# Refresh state
terraform refresh

# Destroy infrastructure (careful!)
terraform destroy
```

## Troubleshooting

### Provider Not Registered

If you see errors about `Microsoft.KubernetesConfiguration` not being registered:

```bash
az provider register --namespace Microsoft.KubernetesConfiguration
az provider register --namespace Microsoft.ContainerService
az provider register --namespace Microsoft.KeyVault
az provider register --namespace Microsoft.Storage

# Wait for registration (can take a few minutes)
az provider show --namespace Microsoft.KubernetesConfiguration --query registrationState
```

### Permission Errors

Ensure you have Contributor or Owner role:

```bash
az role assignment list --assignee $(az ad signed-in-user show --query id -o tsv) \
  --query "[?roleDefinitionName=='Owner' || roleDefinitionName=='Contributor']" -o table
```

### SSH Key Errors

If Flux configuration fails with SSH errors:

1. Verify key exists: `ls -la ~/.ssh/mercury`
2. Verify public key added to GitHub: `cat ~/.ssh/mercury.pub`
3. Test GitHub access: `ssh -T git@github.com -i ~/.ssh/mercury`

### Name Already Exists

If Key Vault or Storage Account names are taken:

1. Edit `terraform.tfvars`
2. Change `key_vault_name` and/or `storage_account_name` to something unique
3. Re-run `terraform apply`

## Migration from Hardcoded Values

If you're migrating from the old hardcoded `main.tf`:

1. Create `terraform.tfvars` with your values
2. Run `terraform plan` to verify changes
3. If the plan shows infrastructure replacement (not desired), use:
   ```bash
   terraform refresh
   ```
4. The state should recognize existing resources with new variable references
