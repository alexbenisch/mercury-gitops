## Key Vault Outputs

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

## Storage Outputs

output "storage_account_name" {
  value       = azurerm_storage_account.cnpg_backups.name
  description = "Storage account for CNPG backups"
}
