#!/usr/bin/env python3
"""
Update Terraform configuration to add Azure Key Vault secrets for a new customer.
"""

import os
import sys
import argparse
from pathlib import Path


TERRAFORM_TEMPLATE = """
## {CUSTOMER_NAME_UPPER} DB credentials

resource "random_password" "{customer_name}_db_password" {{
  length  = 24
  special = false

  lifecycle {{
    ignore_changes = all
  }}
}}

resource "azurerm_key_vault_secret" "{customer_name}_db_user" {{
  name         = "{customer_name}-db-user"
  value        = "app"
  key_vault_id = azurerm_key_vault.mercury_vault.id

  depends_on = [azurerm_role_assignment.kv_admin]
}}

resource "azurerm_key_vault_secret" "{customer_name}_db_password" {{
  name         = "{customer_name}-db-password"
  value        = random_password.{customer_name}_db_password.result
  key_vault_id = azurerm_key_vault.mercury_vault.id

  depends_on = [azurerm_role_assignment.kv_admin]
}}
"""


def update_terraform(customer_name, terraform_file):
    """Add Key Vault secret resources for a new customer to main.tf."""

    print(f"Updating Terraform configuration for: {customer_name}")
    print(f"Terraform file: {terraform_file}")
    print("-" * 60)

    if not terraform_file.exists():
        print(f"ERROR: Terraform file not found: {terraform_file}")
        return 1

    # Read existing content
    content = terraform_file.read_text()

    # Check if customer already exists
    if f'resource "random_password" "{customer_name}_db_password"' in content:
        print(f"⚠ Customer {customer_name} already exists in Terraform configuration")
        return 0

    # Generate new resources
    new_resources = TERRAFORM_TEMPLATE.format(
        customer_name=customer_name,
        CUSTOMER_NAME_UPPER=customer_name.upper()
    )

    # Find insertion point (before the outputs section)
    output_index = content.find('output "key_vault_name"')

    if output_index == -1:
        # If no outputs section found, append to end
        updated_content = content.rstrip() + "\n" + new_resources
    else:
        # Insert before outputs section
        updated_content = content[:output_index] + new_resources + "\n" + content[output_index:]

    # Write updated content
    terraform_file.write_text(updated_content)
    print(f"✓ Added Key Vault secrets for {customer_name}")
    print("-" * 60)
    print("✓ Terraform configuration updated successfully!")
    print()
    print("Next steps:")
    print("1. Review the Terraform changes")
    print("2. Run 'terraform plan' to verify")
    print("3. Run 'terraform apply' to create the secrets")

    return 0


def main():
    parser = argparse.ArgumentParser(
        description="Update Terraform to add Key Vault secrets for a new customer"
    )
    parser.add_argument(
        "customer_name",
        help="Customer name (e.g., customer2, customer3)"
    )
    parser.add_argument(
        "--terraform-file",
        type=Path,
        help="Path to main.tf file (default: ./main.tf)"
    )

    args = parser.parse_args()

    # Determine terraform file path
    if args.terraform_file:
        terraform_file = args.terraform_file
    else:
        # Assume script is run from repo root or .github/scripts
        script_dir = Path(__file__).parent
        repo_root = script_dir.parent.parent
        terraform_file = repo_root / "main.tf"

    return update_terraform(args.customer_name, terraform_file)


if __name__ == "__main__":
    sys.exit(main())
