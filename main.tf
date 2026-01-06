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
  subscription_id = "6280aae8-f9e7-4540-9aa3-646c95dd57d1"
}

resource "azurerm_resource_group" "aks" {
  name     = "rg-cloud-course-aks"
  location = "North Europe"
}

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
    url             = "ssh://git@github.com/alexbenisch/mercury-gitops"
    reference_type  = "branch"
    reference_value = "main"

    ssh_private_key_base64 = base64encode(file("~/.ssh/mercury"))
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
  name                = "kv-mercury-staging"
  location            = azurerm_resource_group.aks.location
  resource_group_name = azurerm_resource_group.aks.name
  tenant_id           = data.azurerm_client_config.current.tenant_id
  sku_name            = "standard"

  soft_delete_retention_days = 7
  purge_protection_enabled   = false

  rbac_authorization_enabled = true
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
  value        = "app"
  key_vault_id = azurerm_key_vault.mercury_vault.id

  depends_on = [azurerm_role_assignment.kv_admin]
}

resource "azurerm_key_vault_secret" "customer1_db_password" {
  name         = "customer1-db-password"
  value        = random_password.customer1_db_password.result
  key_vault_id = azurerm_key_vault.mercury_vault.id

  depends_on = [azurerm_role_assignment.kv_admin]
}


## CUSTOMER3 DB credentials

resource "random_password" "customer3_db_password" {
  length  = 24
  special = false

  lifecycle {
    ignore_changes = all
  }
}

resource "azurerm_key_vault_secret" "customer3_db_user" {
  name         = "customer3-db-user"
  value        = "app"
  key_vault_id = azurerm_key_vault.mercury_vault.id

  depends_on = [azurerm_role_assignment.kv_admin]
}

resource "azurerm_key_vault_secret" "customer3_db_password" {
  name         = "customer3-db-password"
  value        = random_password.customer3_db_password.result
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

