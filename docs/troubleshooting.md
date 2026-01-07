# Troubleshooting Guide

This document contains common issues and their solutions when working with this GitOps setup.

## CloudNativePG Installation Conflicts

### Issue: Server-side apply conflicts when installing CloudNativePG

**Symptoms:**
```bash
kubectl apply --server-side -f \
  https://raw.githubusercontent.com/cloudnative-pg/cloudnative-pg/release-1.28/releases/cnpg-1.28.0.yaml

# Error output:
Apply failed with 1 conflict: conflict with "helm-controller" using apiextensions.k8s.io/v1
```

**Root Cause:**
CloudNativePG is already installed and managed by Flux via HelmRelease. When you try to install it manually using `kubectl apply`, it conflicts with the existing Helm-managed resources. The helm-controller owns these resources, and attempting to apply the manifest directly creates ownership conflicts.

**Diagnosis:**
```bash
# Check current CloudNativePG version
kubectl get deployment -n cnpg-system cnpg-controller-manager \
  -o jsonpath="{.spec.template.spec.containers[*].image}"
# Output: ghcr.io/cloudnative-pg/cloudnative-pg:1.28.0

# Check HelmRelease
kubectl get helmrelease -A | grep cnpg
# Output: flux-system   cnpg   3h12m   True    Helm install succeeded...
```

**Solution:**
Do not manually install CloudNativePG when using this GitOps setup. The operator is already installed and managed by Flux through the `infrastructure/controllers` HelmRelease.

**Key Learnings:**
- In a GitOps setup, infrastructure components are managed declaratively via Flux
- Manual kubectl applies conflict with Flux/Helm-managed resources
- Always check if a component is already installed before attempting manual installation
- CloudNativePG 1.28.0 is installed via Flux and meets the requirements for the barman-cloud plugin (version 1.26+)

**Verification:**
To verify CloudNativePG is properly installed and running:
```bash
# Check deployment
kubectl get deployment -n cnpg-system cnpg-controller-manager

# Check HelmRelease status
kubectl get helmrelease -n flux-system cnpg

# Check operator version
kubectl get deployment -n cnpg-system cnpg-controller-manager \
  -o jsonpath="{.spec.template.spec.containers[*].image}"
```
