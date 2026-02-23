terraform {
  required_version = ">= 1.0"
  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "~> 4.0"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.0"
    }
  }
}

provider "azurerm" {
  features {}
  subscription_id = var.subscription_id
}

resource "azurerm_resource_group" "aks" {
  name     = var.resource_group_name
  location = var.location
  tags     = var.tags
}

resource "azurerm_kubernetes_cluster" "main" {
  name                = var.cluster_name
  location            = azurerm_resource_group.aks.location
  resource_group_name = azurerm_resource_group.aks.name
  dns_prefix          = "staging"
  kubernetes_version  = var.kubernetes_version
  tags                = var.tags

  default_node_pool {
    name       = "default"
    node_count = var.node_count
    vm_size    = var.node_vm_size
  }

  identity {
    type = "SystemAssigned"
  }

  network_profile {
    network_plugin     = "azure"
    network_policy     = "cilium"
    network_data_plane = "cilium"
  }

  key_vault_secrets_provider {
    secret_rotation_enabled = false
  }
}

## GitOps with Flux
# IMPORTANT: Register provider first: az provider register --namespace Microsoft.KubernetesConfiguration

resource "azurerm_kubernetes_cluster_extension" "flux" {
  name           = "mercury-flux"
  cluster_id     = azurerm_kubernetes_cluster.main.id
  extension_type = "microsoft.flux"
}

resource "azurerm_kubernetes_flux_configuration" "main" {
  name       = "mercury-system"
  cluster_id = azurerm_kubernetes_cluster.main.id
  namespace  = "flux-system"

  git_repository {
    url             = var.flux_git_repo_url
    reference_type  = "branch"
    reference_value = var.flux_git_branch

    ssh_private_key_base64 = base64encode(file(var.flux_ssh_key_path))
  }

  kustomizations {
    name                       = "infra-controllers"
    path                       = "./infrastructure/controllers/staging"
    sync_interval_in_seconds   = 300
    garbage_collection_enabled = true
  }

  kustomizations {
    name                       = "infra-configs"
    path                       = "./infrastructure/configs/staging"
    sync_interval_in_seconds   = 300
    depends_on                 = ["infra-controllers"]
    garbage_collection_enabled = true
  }

  kustomizations {
    name                       = "apps"
    path                       = "./apps/staging"
    sync_interval_in_seconds   = 300
    depends_on                 = ["infra-configs"]
    garbage_collection_enabled = true
  }

  scope = "cluster"

  depends_on = [azurerm_kubernetes_cluster_extension.flux]
}

## Key Vault

data "azurerm_client_config" "current" {}

resource "azurerm_key_vault" "mercury_vault" {
  name                = var.key_vault_name
  location            = azurerm_resource_group.aks.location
  resource_group_name = azurerm_resource_group.aks.name
  tenant_id           = data.azurerm_client_config.current.tenant_id
  sku_name            = "standard"

  soft_delete_retention_days = var.soft_delete_retention_days
  purge_protection_enabled   = var.purge_protection_enabled

  rbac_authorization_enabled = true
  tags                       = var.tags
  depends_on                 = [azurerm_kubernetes_cluster.main]
}

resource "azurerm_role_assignment" "kv_admin" {
  scope                = azurerm_key_vault.mercury_vault.id
  role_definition_name = "Key Vault Administrator"
  principal_id         = data.azurerm_client_config.current.object_id
}

resource "azurerm_role_assignment" "aks_keyvault_secrets_provider" {
  scope                = azurerm_key_vault.mercury_vault.id
  role_definition_name = "Key Vault Secrets User"
  principal_id         = azurerm_kubernetes_cluster.main.key_vault_secrets_provider[0].secret_identity[0].object_id
}

## Customer1 DB credentials

resource "random_password" "customer1_db_password" {
  length  = 24
  special = false

  lifecycle {
    ignore_changes = all
  }
}

resource "azurerm_key_vault_secret" "customer1_db_user" {
  name         = "customer1-db-user"
  value        = var.customer1_db_username
  key_vault_id = azurerm_key_vault.mercury_vault.id

  depends_on = [azurerm_role_assignment.kv_admin]
}

resource "azurerm_key_vault_secret" "customer1_db_password" {
  name         = "customer1-db-password"
  value        = random_password.customer1_db_password.result
  key_vault_id = azurerm_key_vault.mercury_vault.id

  depends_on = [azurerm_role_assignment.kv_admin]
}

output "key_vault_name" {
  value = azurerm_key_vault.mercury_vault.name
}

output "key_vault_uri" {
  value = azurerm_key_vault.mercury_vault.vault_uri
}

output "aks_keyvault_secrets_provider_client_id" {
  value       = azurerm_kubernetes_cluster.main.key_vault_secrets_provider[0].secret_identity[0].client_id
  description = "AKS Key Vault Secrets Provider Client ID for use in SecretProviderClass"
}

## CNPG Backup Storage

resource "azurerm_storage_account" "cnpg_backups" {
  name                     = var.storage_account_name
  resource_group_name      = azurerm_resource_group.aks.name
  location                 = azurerm_resource_group.aks.location
  account_tier             = "Standard"
  account_replication_type = "LRS"
  min_tls_version          = "TLS1_2"
  tags                     = var.tags

  blob_properties {
    versioning_enabled = var.storage_versioning_enabled
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
  expiry = timeadd(timestamp(), "${var.sas_token_expiry_hours}h")

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

