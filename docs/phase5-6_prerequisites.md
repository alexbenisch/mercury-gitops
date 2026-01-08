# Phase 5-6 Prerequisites

## Setup Steps

### 1. Register Provider
Register the required Azure provider for the deployment.

### 2. Create Domain
Create the domain: **kubetest.uk**

### 3. Terraform Apply
Run the Terraform configuration:
```bash
terraform apply
```

### 4. Terraform Outputs
After successful terraform apply, retrieve the outputs:
```bash
terraform output
```

Expected outputs:
```
aks_keyvault_secrets_provider_client_id = "00000000-0000-0000-0000-000000000000"
customer1_backup_path = "https://<storage-account-name>.blob.core.windows.net/customer1"
key_vault_name = "kv-mercury-staging"
key_vault_uri = "https://kv-mercury-staging.vault.azure.net/"
storage_account_name = "<storage-account-name>"
```

### 5. Azure Account Verification
Verify your Azure account configuration:
```bash
az account list
```

Expected output:
```json
[
  {
    "cloudName": "AzureCloud",
    "homeTenantId": "00000000-0000-0000-0000-000000000000",
    "id": "11111111-1111-1111-1111-111111111111",
    "isDefault": true,
    "managedByTenants": [],
    "name": "mercury",
    "state": "Enabled",
    "tenantDefaultDomain": "example.onmicrosoft.com",
    "tenantDisplayName": "Default Directory",
    "tenantId": "00000000-0000-0000-0000-000000000000",
    "user": {
      "name": "user@example.com",
      "type": "user"
    }
  }
]
```
