variable "subscription_id" {
  description = "Azure subscription ID"
  type        = string
}

variable "resource_group_name" {
  description = "Name of the Azure resource group"
  type        = string
  default     = "rg-cloud-course-aks"
}

variable "location" {
  description = "Azure region for resources"
  type        = string
  default     = "North Europe"
}

variable "cluster_name" {
  description = "Name of the AKS cluster"
  type        = string
  default     = "mercury-staging"
}

variable "kubernetes_version" {
  description = "Kubernetes version for AKS cluster"
  type        = string
  default     = "1.32.0"
}

variable "node_count" {
  description = "Number of nodes in the default node pool"
  type        = number
  default     = 2
}

variable "node_vm_size" {
  description = "VM size for AKS nodes"
  type        = string
  default     = "Standard_D2s_v3"
}

variable "key_vault_name" {
  description = "Name of the Azure Key Vault (must be globally unique)"
  type        = string
  default     = "kv-mercury-staging"
}

variable "storage_account_name" {
  description = "Name of the storage account for CNPG backups (must be globally unique, 3-24 chars, lowercase/numbers only)"
  type        = string
  default     = "alexmercurybackup"

  validation {
    condition     = can(regex("^[a-z0-9]{3,24}$", var.storage_account_name))
    error_message = "Storage account name must be 3-24 characters, lowercase letters and numbers only."
  }
}

variable "flux_git_repo_url" {
  description = "Git repository URL for Flux CD"
  type        = string
  default     = "ssh://git@github.com/alexbenisch/mercury-gitops"
}

variable "flux_git_branch" {
  description = "Git branch for Flux CD to track"
  type        = string
  default     = "main"
}

variable "flux_ssh_key_path" {
  description = "Path to SSH private key for Flux Git authentication"
  type        = string
  default     = "~/.ssh/mercury"
}

variable "customer1_db_username" {
  description = "Username for customer1 database"
  type        = string
  default     = "app"
}

variable "soft_delete_retention_days" {
  description = "Number of days to retain soft-deleted Key Vault items"
  type        = number
  default     = 7
}

variable "purge_protection_enabled" {
  description = "Enable purge protection on Key Vault"
  type        = bool
  default     = false
}

variable "storage_versioning_enabled" {
  description = "Enable blob versioning on storage account"
  type        = bool
  default     = true
}

variable "sas_token_expiry_hours" {
  description = "Number of hours until SAS token expires (default: 17520 = 2 years)"
  type        = number
  default     = 17520
}

variable "cloudflare_api_token" {
  description = "Cloudflare API token for DNS-01 ACME challenges"
  type        = string
  sensitive   = true
}

variable "tags" {
  description = "Common tags to apply to all resources"
  type        = map(string)
  default = {
    Environment = "staging"
    Project     = "mercury"
    ManagedBy   = "terraform"
  }
}
