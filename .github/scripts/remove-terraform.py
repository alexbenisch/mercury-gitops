#!/usr/bin/env python3
"""
Remove customer Terraform resources from main.tf.
"""

import os
import sys
import re
from pathlib import Path


def remove_customer_terraform(customer_name: str) -> None:
    """Remove customer Terraform resources from main.tf."""
    repo_root = Path(__file__).parent.parent.parent
    terraform_file = repo_root / "main.tf"

    if not terraform_file.exists():
        print(f"ERROR: Terraform file not found: {terraform_file}")
        sys.exit(1)

    # Read the file
    with open(terraform_file, 'r') as f:
        content = f.read()

    print(f"Removing Terraform resources for: {customer_name}")
    print("-" * 60)

    # Pattern to match the entire customer section
    # Matches from the comment header to the end of the last resource
    pattern = re.compile(
        rf'## {customer_name.capitalize()} DB credentials.*?'
        rf'resource "azurerm_key_vault_secret" "{customer_name}_db_password" {{.*?'
        rf'depends_on = \[azurerm_role_assignment\.kv_admin\]\s*\}}\s*\n',
        re.DOTALL
    )

    match = pattern.search(content)
    if match:
        # Remove the matched section
        new_content = content[:match.start()] + content[match.end():]

        # Write back
        with open(terraform_file, 'w') as f:
            f.write(new_content)

        print(f"✓ Removed Terraform resources for {customer_name}")
        print(f"  - random_password.{customer_name}_db_password")
        print(f"  - azurerm_key_vault_secret.{customer_name}_db_user")
        print(f"  - azurerm_key_vault_secret.{customer_name}_db_password")
    else:
        print(f"⚠ No Terraform resources found for {customer_name}")
        print("  (may have been removed already or never existed)")

    print(f"✓ Updated {terraform_file.relative_to(repo_root)}")


def main():
    if len(sys.argv) != 2:
        print("Usage: remove-terraform.py <customer_name>")
        sys.exit(1)

    customer_name = sys.argv[1]

    # Validate customer name format
    if not customer_name.startswith("customer") or not customer_name[8:].isdigit():
        print(f"ERROR: Invalid customer name format: {customer_name}")
        print("Expected format: customerN (e.g., customer2, customer3)")
        sys.exit(1)

    try:
        remove_customer_terraform(customer_name)
        print("\n" + "=" * 60)
        print(f"✓ Successfully removed Terraform config for: {customer_name}")
        print("=" * 60)
        print("\nNext steps:")
        print("  1. Review the changes in main.tf")
        print("  2. After PR merge, run:")
        print("     terraform plan")
        print("     terraform apply")
    except Exception as e:
        print(f"\n❌ ERROR: {e}", file=sys.stderr)
        import traceback
        traceback.print_exc()
        sys.exit(1)


if __name__ == "__main__":
    main()
