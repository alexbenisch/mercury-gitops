#!/usr/bin/env python3
"""
Remove customer manifests from the mercury-gitops repository.
"""

import os
import sys
import shutil
from pathlib import Path


def remove_customer_directories(customer_name: str) -> None:
    """Remove customer base and staging directories."""
    repo_root = Path(__file__).parent.parent.parent
    base_dir = repo_root / "apps" / "base" / customer_name
    staging_dir = repo_root / "apps" / "staging" / customer_name

    print(f"Removing customer: {customer_name}")
    print(f"Base directory: {base_dir}")
    print(f"Staging directory: {staging_dir}")
    print("-" * 60)

    # Remove base directory
    if base_dir.exists():
        shutil.rmtree(base_dir)
        print(f"✓ Removed {base_dir.relative_to(repo_root)}/")
    else:
        print(f"⚠ Base directory not found: {base_dir.relative_to(repo_root)}/")

    # Remove staging directory
    if staging_dir.exists():
        shutil.rmtree(staging_dir)
        print(f"✓ Removed {staging_dir.relative_to(repo_root)}/")
    else:
        print(f"⚠ Staging directory not found: {staging_dir.relative_to(repo_root)}/")


def update_staging_kustomization(customer_name: str) -> None:
    """Remove customer reference from apps/staging/kustomization.yaml."""
    repo_root = Path(__file__).parent.parent.parent
    kustomization_file = repo_root / "apps" / "staging" / "kustomization.yaml"

    if not kustomization_file.exists():
        print(f"⚠ Staging kustomization not found: {kustomization_file}")
        return

    # Read the file
    with open(kustomization_file, 'r') as f:
        lines = f.readlines()

    # Remove the customer reference
    new_lines = []
    skip_next = False
    for i, line in enumerate(lines):
        # Skip lines that reference this customer
        if f"- ./{customer_name}" in line or f"- {customer_name}" in line:
            print(f"✓ Removed reference to {customer_name} from staging kustomization")
            continue
        new_lines.append(line)

    # Write back
    with open(kustomization_file, 'w') as f:
        f.writelines(new_lines)

    print(f"✓ Updated {kustomization_file.relative_to(repo_root)}")


def main():
    if len(sys.argv) != 2:
        print("Usage: deprovision-customer.py <customer_name>")
        sys.exit(1)

    customer_name = sys.argv[1]

    # Validate customer name format
    if not customer_name.startswith("customer") or not customer_name[8:].isdigit():
        print(f"ERROR: Invalid customer name format: {customer_name}")
        print("Expected format: customerN (e.g., customer2, customer3)")
        sys.exit(1)

    try:
        remove_customer_directories(customer_name)
        update_staging_kustomization(customer_name)
        print("\n" + "=" * 60)
        print(f"✓ Successfully removed customer: {customer_name}")
        print("=" * 60)
    except Exception as e:
        print(f"\n❌ ERROR: {e}", file=sys.stderr)
        sys.exit(1)


if __name__ == "__main__":
    main()
