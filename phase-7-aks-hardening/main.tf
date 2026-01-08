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
  subscription_id = "c9f99369-d202-458b-9a97-4c95a5cbc20c"
}

resource "azurerm_resource_group" "aks" {
  name     = "rg-cloud-course-aks"
  location = "North Europe"
}

## AKS Cluster with Best Practices
# Reference: https://learn.microsoft.com/en-us/azure/aks/best-practices

resource "azurerm_kubernetes_cluster" "main" {
  name                = "mercury-staging"
  location            = azurerm_resource_group.aks.location
  resource_group_name = azurerm_resource_group.aks.name
  dns_prefix          = "staging"
  kubernetes_version  = "1.32.1"

  azure_active_directory_role_based_access_control {
    admin_group_object_ids = ["6c2aab3d-abfe-4b6a-90e2-d76433d03eb6"]
  }

  # Automatic upgrades,  patch level only for stability
  automatic_upgrade_channel = "patch"

  # Node OS auto-upgrade for security patches
  node_os_upgrade_channel = "NodeImage"

  # System node pool for critical Kubernetes components
  # Tainted with CriticalAddonsOnly so user workloads don't schedule here
  default_node_pool {
    name                         = "agentpool"
    node_count                   = 2
    vm_size                      = "Standard_D2s_v3"
    only_critical_addons_enabled = true # Adds CriticalAddonsOnly taint

    upgrade_settings {
      max_surge = "33%" # Microsoft recommended for production
    }
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

  # Maintenance windows - schedule upgrades during low-traffic periods
  # Microsoft recommends at least 4 hours duration
  maintenance_window_auto_upgrade {
    frequency   = "Weekly"
    interval    = 1
    duration    = 4
    day_of_week = "Sunday"
    start_time  = "02:00"
    utc_offset  = "+00:00"
  }

  maintenance_window_node_os {
    frequency   = "Weekly"
    interval    = 1
    duration    = 4
    day_of_week = "Sunday"
    start_time  = "02:00"
    utc_offset  = "+00:00"
  }
}

# User node pool - for application workloads
# No taint, so pods schedule here by default
resource "azurerm_kubernetes_cluster_node_pool" "user" {
  name                  = "userpool"
  kubernetes_cluster_id = azurerm_kubernetes_cluster.main.id
  vm_size               = "Standard_D2s_v3"
  node_count            = 2

  upgrade_settings {
    max_surge = "33%"
  }
}

## GitOps with Flux
# IMPORTANT: Register provider first: az provider register --namespace Microsoft.KubernetesConfiguration

resource "azurerm_kubernetes_cluster_extension" "flux" {
  name           = "mercury-flux"
  cluster_id     = azurerm_kubernetes_cluster.main.id
  extension_type = "microsoft.flux"

  # Wait for user node pool to be ready before installing extensions
  # The system pool has CriticalAddonsOnly taint, so Flux needs user nodes
  depends_on = [azurerm_kubernetes_cluster_node_pool.user]
}

resource "azurerm_kubernetes_flux_configuration" "main" {
  name       = "mercury-staging"
  cluster_id = azurerm_kubernetes_cluster.main.id
  namespace  = "flux-system"

  git_repository {
    url             = "ssh://git@github.com/mischavandenburg/mercury-gitops"
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
