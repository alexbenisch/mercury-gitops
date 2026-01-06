#!/usr/bin/env python3
"""
Customer provisioning script for mercury-gitops.
Generates Kubernetes manifests from templates.
"""

import os
import sys
import argparse
from pathlib import Path


def replace_placeholders(content, replacements):
    """Replace all placeholders in content with actual values."""
    for placeholder, value in replacements.items():
        content = content.replace(f"{{{{{placeholder}}}}}", value)
    return content


def provision_customer(customer_name, aks_identity_client_id, azure_tenant_id):
    """Provision a new customer by generating manifests from templates."""

    # Define paths
    script_dir = Path(__file__).parent
    templates_dir = script_dir / "templates"
    repo_root = script_dir.parent.parent
    base_dir = repo_root / "apps" / "base" / customer_name
    staging_dir = repo_root / "apps" / "staging" / customer_name
    staging_kustomization = repo_root / "apps" / "staging" / "kustomization.yaml"

    # Define replacements
    replacements = {
        "CUSTOMER_NAME": customer_name,
        "AKS_IDENTITY_CLIENT_ID": aks_identity_client_id,
        "AZURE_TENANT_ID": azure_tenant_id
    }

    print(f"Provisioning customer: {customer_name}")
    print(f"Base directory: {base_dir}")
    print(f"Staging directory: {staging_dir}")
    print("-" * 60)

    # Create base directory structure
    base_dir.mkdir(parents=True, exist_ok=True)

    # Generate base manifests
    base_templates = templates_dir / "base"
    for template_file in base_templates.glob("*.yaml"):
        content = template_file.read_text()
        content = replace_placeholders(content, replacements)

        output_file = base_dir / template_file.name
        output_file.write_text(content)
        print(f"✓ Created {output_file.relative_to(repo_root)}")

    # Create staging directory structure
    staging_dir.mkdir(parents=True, exist_ok=True)

    # Generate staging kustomization
    staging_template = templates_dir / "staging" / "kustomization.yaml"
    content = staging_template.read_text()
    content = replace_placeholders(content, replacements)

    output_file = staging_dir / "kustomization.yaml"
    output_file.write_text(content)
    print(f"✓ Created {output_file.relative_to(repo_root)}")

    # Update apps/staging/kustomization.yaml to include new customer
    if staging_kustomization.exists():
        content = staging_kustomization.read_text()
        lines = content.strip().split('\n')

        # Check if customer already exists
        if f"  - {customer_name}" not in content:
            # Find the resources section and add the new customer
            for i, line in enumerate(lines):
                if line.strip() == "resources:":
                    # Find the last resource entry
                    j = i + 1
                    while j < len(lines) and lines[j].startswith("  - "):
                        j += 1
                    # Insert new customer at the end of resources
                    lines.insert(j, f"  - {customer_name}")
                    break

            # Write updated content
            staging_kustomization.write_text('\n'.join(lines) + '\n')
            print(f"✓ Updated {staging_kustomization.relative_to(repo_root)}")
        else:
            print(f"⚠ Customer {customer_name} already exists in {staging_kustomization.relative_to(repo_root)}")

    print("-" * 60)
    print(f"✓ Customer {customer_name} provisioned successfully!")
    print()
    print("Next steps:")
    print("1. Review the generated manifests")
    print("2. Update Terraform to create Azure Key Vault secrets")
    print(f"3. Commit changes and create a PR")

    return 0


def main():
    parser = argparse.ArgumentParser(
        description="Provision a new customer in mercury-gitops"
    )
    parser.add_argument(
        "customer_name",
        help="Customer name (e.g., customer2, customer3)"
    )
    parser.add_argument(
        "--aks-identity-client-id",
        required=True,
        help="AKS Key Vault Secrets Provider Client ID"
    )
    parser.add_argument(
        "--azure-tenant-id",
        required=True,
        help="Azure Tenant ID"
    )

    args = parser.parse_args()

    # Validate customer name format
    if not args.customer_name.startswith("customer"):
        print(f"ERROR: Customer name must start with 'customer' (e.g., customer2)")
        return 1

    return provision_customer(
        args.customer_name,
        args.aks_identity_client_id,
        args.azure_tenant_id
    )


if __name__ == "__main__":
    sys.exit(main())
