# Deployment Lessons - 2026-01-08

**Date**: 2026-01-08
**Focus**: Phase 5-6 deployment issues, n8n startup problems, and Traefik TLS routing

---

## Overview

This document captures issues encountered during Phase 5-6 deployment and their solutions. Use this guide to avoid these issues in future deployments.

---

## Issue 1: N8N Pod Not Starting - ObjectStore CRD Missing

### Problem

The n8n pod wasn't starting, and the `mercury-system-apps` kustomization was failing with:

```
ObjectStore/customer1/customer1-objectstore dry-run failed:
no matches for kind "ObjectStore" in version "barmancloud.cnpg.io/v1"
```

### Diagnosis Process

```bash
# Check kustomization status
kubectl get kustomizations -n flux-system
# NAME                  AGE   READY   STATUS
# mercury-system-apps   40m   False   ObjectStore/customer1/... dry-run failed

# Check if n8n pod exists
kubectl get pods -n customer1
# No resources found in customer1 namespace.

# The entire kustomization was blocked, preventing ANY resources from being created
```

### Root Cause

The `objectstore.yaml` file referenced a Custom Resource Definition (CRD) that doesn't exist:
- **CRD Referenced**: `barmancloud.cnpg.io/v1` (ObjectStore)
- **CRDs Available**: Only `postgresql.cnpg.io/v1` CRDs are installed
- The CloudNativePG operator doesn't include the `barmancloud.cnpg.io` API group

```bash
# Verify available CRDs
kubectl get crd | grep cnpg
# backups.postgresql.cnpg.io
# clusters.postgresql.cnpg.io
# scheduledbackups.postgresql.cnpg.io
# ... but NO objectstores.barmancloud.cnpg.io
```

### Why This Happened

The backup configuration can be done in two ways:

1. **Using barmanObjectStore in Cluster spec** (recommended, what we're using):
   ```yaml
   apiVersion: postgresql.cnpg.io/v1
   kind: Cluster
   spec:
     backup:
       barmanObjectStore:
         destinationPath: "https://..."
         azureCredentials: ...
   ```

2. **Using separate ObjectStore resource** (requires additional plugin):
   ```yaml
   apiVersion: barmancloud.cnpg.io/v1  # This CRD doesn't exist!
   kind: ObjectStore
   spec:
     configuration: ...
   ```

We had BOTH configurations, but the ObjectStore CRD wasn't available, causing the entire kustomization to fail.

### Solution

Remove the ObjectStore resource from the kustomization since it's redundant and not supported:

**File: `apps/base/customer1/kustomization.yaml`**
```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
namespace: customer1
resources:
  - namespace.yaml
  - secrets.yaml
  # - objectstore.yaml  # COMMENTED OUT - CRD not available
  - database.yaml
  - scheduled-backup.yaml
  - configmap.yaml
  - storage.yaml
  - deployment.yaml
  - service.yaml
  - ingress.yaml
```

**File: `apps/staging/customer1/kustomization.yaml`**
```yaml
patches:
  - target:
      kind: SecretProviderClass
      name: customer1-secrets
    patch: ...
  # ObjectStore patch commented out - CRD not available
  # - target:
  #     kind: ObjectStore
  #     name: customer1-objectstore
  #   patch: ...
  - target:
      kind: Cluster
      name: customer1-db
    patch: ...
```

### Commands to Fix

```bash
# 1. Comment out objectstore.yaml in kustomization files
vi apps/base/customer1/kustomization.yaml
vi apps/staging/customer1/kustomization.yaml

# 2. Commit and push
git add apps/base/customer1/kustomization.yaml apps/staging/customer1/kustomization.yaml
git commit -m "fix: remove ObjectStore resource to resolve n8n deployment issue"
git push

# 3. Force reconciliation
flux reconcile source git mercury-system
flux reconcile kustomization mercury-system-apps

# 4. Verify deployment
kubectl get pods -n customer1
# Expected: All pods Running
```

### Key Learnings

1. **One failing resource blocks entire kustomization**: If ANY resource in a kustomization references a non-existent CRD, the ENTIRE kustomization fails and NO resources are created
2. **Check CRD availability**: Always verify CRDs exist before referencing them: `kubectl get crd | grep <api-group>`
3. **Use built-in backup configuration**: The `backup.barmanObjectStore` configuration in the Cluster spec is sufficient - no need for separate ObjectStore resources
4. **Redundant configurations cause conflicts**: Having both ObjectStore resource AND backup.barmanObjectStore was redundant

### Prevention

Before adding Custom Resources to manifests:
```bash
# Verify the CRD exists
kubectl get crd <resource-plural>.<api-group>
# Example: kubectl get crd objectstores.barmancloud.cnpg.io

# List all available CRDs for an API group
kubectl get crd | grep <api-group>
# Example: kubectl get crd | grep cnpg

# Check what versions are available
kubectl explain <resource>
# Example: kubectl explain Cluster.spec.backup
```

---

## Issue 2: Traefik TLS Routing Broken Despite Valid Certificate

### Problem

N8N was deployed with a valid Let's Encrypt certificate, but HTTPS routing wasn't working. Traefik logs showed repeated errors:

```bash
kubectl logs -n traefik -l app.kubernetes.io/name=traefik --tail=50 | grep -i error
# Error configuring TLS error="secret customer1/customer1-tls does not exist"
# Error configuring TLS error="secret customer1/customer1-tls does not exist"
# (repeated continuously)
```

However, the certificate and secret actually existed:
```bash
kubectl get certificate -n customer1
# NAME            READY   SECRET          AGE
# customer1-tls   True    customer1-tls   44m

kubectl get secret customer1-tls -n customer1
# NAME            TYPE                DATA   AGE
# customer1-tls   kubernetes.io/tls   2      44m
```

### Root Cause

**Timing Issue**: Traefik starts and configures ingress routes BEFORE cert-manager has issued the TLS certificate. Even though cert-manager successfully creates the certificate 20-60 seconds later, Traefik has already cached the "secret not found" state and doesn't automatically reload the configuration.

**Sequence of Events:**
1. Flux deploys ingress resource (t=0s)
2. Traefik sees ingress, tries to configure TLS route (t=0-5s)
3. TLS secret doesn't exist yet → Traefik caches "secret not found"
4. Cert-manager creates certificate challenge (t=10s)
5. Certificate issued successfully (t=30s)
6. TLS secret created (t=30s)
7. **Traefik never reloads** - still thinks secret doesn't exist

### Solution

Restart Traefik to pick up the TLS secret:

```bash
# 1. Verify certificate is ready
kubectl get certificate -n customer1
# Look for READY=True

# 2. Verify secret exists
kubectl get secret customer1-tls -n customer1

# 3. Restart Traefik
kubectl rollout restart deployment traefik-traefik -n traefik

# 4. Wait for Traefik to be ready
kubectl wait --for=condition=ready pod -l app.kubernetes.io/name=traefik -n traefik --timeout=60s

# 5. Verify HTTPS works
curl -I https://customer1.mercury.kubetest.uk
# Expected: HTTP/2 200

# 6. Verify certificate
echo | openssl s_client -connect customer1.mercury.kubetest.uk:443 \
  -servername customer1.mercury.kubetest.uk 2>/dev/null | \
  openssl x509 -noout -issuer -subject -dates
# Expected: issuer=C = US, O = Let's Encrypt, CN = R13
```

### Key Learnings

1. **Certificate issuance takes time**: 20-60 seconds is typical for Let's Encrypt
2. **Traefik doesn't auto-reload**: When TLS secrets are created after startup, Traefik needs to be restarted
3. **Always verify both**: Check certificate status (READY=True) AND actual HTTPS connectivity
4. **Monitor logs during deployment**: Watch both cert-manager and Traefik logs to catch timing issues early

### Prevention Strategies

**Option 1: Deploy in Stages** (Recommended for production)
```bash
# Stage 1: Deploy infrastructure
flux reconcile kustomization mercury-system-infra-controllers --with-source

# Wait for all infrastructure to be ready
kubectl get pods -n cert-manager
kubectl get pods -n traefik
kubectl get pods -n external-dns

# Stage 2: Deploy applications
flux reconcile kustomization mercury-system-apps --with-source

# Stage 3: Wait for certificates
kubectl wait --for=condition=ready certificate customer1-tls -n customer1 --timeout=120s

# Stage 4: Restart Traefik if needed
kubectl rollout restart deployment traefik-traefik -n traefik
```

**Option 2: Use HelmRelease Dependencies**
Configure Flux dependencies so applications wait for infrastructure:

```yaml
apiVersion: kustomize.toolkit.fluxcd.io/v1
kind: Kustomization
metadata:
  name: mercury-system-apps
spec:
  dependsOn:
    - name: mercury-system-infra-controllers
  healthChecks:
    - apiVersion: apps/v1
      kind: Deployment
      name: cert-manager
      namespace: cert-manager
    - apiVersion: apps/v1
      kind: Deployment
      name: traefik-traefik
      namespace: traefik
```

**Option 3: Add Post-Deploy Hook**
Create a Job that waits for certificates and restarts Traefik:

```yaml
apiVersion: batch/v1
kind: Job
metadata:
  name: wait-for-certificates
  namespace: customer1
spec:
  template:
    spec:
      containers:
      - name: wait-cert
        image: bitnami/kubectl:latest
        command:
        - /bin/sh
        - -c
        - |
          kubectl wait --for=condition=ready certificate customer1-tls -n customer1 --timeout=120s
          kubectl rollout restart deployment traefik-traefik -n traefik
      restartPolicy: OnFailure
```

---

## Issue 3: Storage Account Placeholder Not Replaced

### Problem

The `database.yaml` and `objectstore.yaml` files contained placeholder values:

```yaml
destinationPath: "https://STORAGE_ACCOUNT.blob.core.windows.net/customer1"
```

While the staging overlay did patch this value, having placeholders in base files makes the configuration unclear and error-prone.

### Solution

Replace placeholders with actual values in base files:

```bash
# Update base files
vi apps/base/customer1/database.yaml
# Change: https://STORAGE_ACCOUNT.blob.core.windows.net/customer1
# To:     https://alexmercurybackup.blob.core.windows.net/customer1

vi apps/base/customer1/objectstore.yaml
# Same change

# Commit changes
git add apps/base/customer1/database.yaml apps/base/customer1/objectstore.yaml
git commit -m "fix: replace storage account placeholder with actual value"
git push
```

### Key Learnings

1. **Base files should be valid**: Even with overlays, base files should contain working defaults
2. **Placeholders cause confusion**: Using actual values (or environment-agnostic defaults) is clearer
3. **Document the values**: Keep terraform outputs in documentation for easy reference

---

## Backup Management Lessons

### Scheduled Backup Frequency

The current schedule creates backups **every 5 minutes**:

```yaml
apiVersion: postgresql.cnpg.io/v1
kind: ScheduledBackup
spec:
  schedule: "0 */5 * * * *"  # Every 5 minutes
```

**For testing**: This is fine to verify the backup system works

**For production**: This is too frequent and will generate unnecessary costs and storage usage

**Recommended production schedules:**
```yaml
# Daily at 3 AM
schedule: "0 0 3 * * *"

# Every 6 hours
schedule: "0 0 */6 * * *"

# Every hour
schedule: "0 0 * * * *"
```

### Backup Cleanup

To delete old backups:

```bash
# List backups older than 5 minutes
kubectl get backup -n customer1 --sort-by=.metadata.creationTimestamp -o json | \
  jq -r '.items[] | select(((now - (.metadata.creationTimestamp | fromdateiso8601)) / 60) > 5) | .metadata.name'

# Delete them
kubectl get backup -n customer1 --sort-by=.metadata.creationTimestamp -o json | \
  jq -r '.items[] | select(((now - (.metadata.creationTimestamp | fromdateiso8601)) / 60) > 5) | .metadata.name' | \
  xargs -I {} kubectl delete backup {} -n customer1

# Verify remaining
kubectl get backup -n customer1
```

**Note**: Kubernetes backup resources are metadata - deleting them doesn't delete the actual backup files in Azure Storage.

### Backup Verification

```bash
# Check backup status
kubectl get backup -n customer1

# Check scheduled backup
kubectl get scheduledbackup -n customer1

# Verify backup files in Azure
az storage blob list \
  --account-name alexmercurybackup \
  --container-name customer1 \
  --query "[].name" --output tsv

# Check cluster backup configuration
kubectl cnpg status -n customer1 customer1-db | grep -A 10 "Continuous Backup"
```

---

## General Workflow Improvements for Tomorrow

### 1. Pre-Deployment Checklist

Before running deployment:

```bash
# ✅ Verify CRDs for custom resources
kubectl get crd | grep <api-group>

# ✅ Check infrastructure is healthy
kubectl get pods -n cert-manager
kubectl get pods -n traefik
kubectl get pods -n external-dns

# ✅ Verify DNS is working
nslookup customer1.mercury.kubetest.uk

# ✅ Check Flux status
flux get kustomizations
```

### 2. Staged Deployment Process

Use this order to minimize errors:

```bash
# Step 1: Sync Git source
flux reconcile source git mercury-system

# Step 2: Deploy infrastructure controllers
flux reconcile kustomization mercury-system-infra-controllers

# Wait 30 seconds for controllers to stabilize
sleep 30

# Step 3: Deploy infrastructure configs
flux reconcile kustomization mercury-system-infra-configs

# Step 4: Deploy applications
flux reconcile kustomization mercury-system-apps

# Step 5: Wait for certificates
kubectl get certificate -A -w

# Step 6: Restart Traefik after certs are ready
kubectl rollout restart deployment traefik-traefik -n traefik
```

### 3. Post-Deployment Verification

After deployment, verify everything systematically:

```bash
# Check all kustomizations
flux get kustomizations
# All should show READY=True

# Check all pods
kubectl get pods -A | grep -v Running | grep -v Completed
# Should be empty (except for system pods in Pending)

# Check certificates
kubectl get certificate -A
# All should show READY=True

# Check ingress
kubectl get ingress -A
# Should have ADDRESS populated

# Test HTTPS endpoints
curl -I https://customer1.mercury.kubetest.uk
# Should return HTTP/2 200
```

### 4. Common Error Patterns to Watch For

| Error | Likely Cause | Quick Fix |
|-------|--------------|-----------|
| `no matches for kind "X"` | CRD missing | Remove resource or install CRD |
| `secret not found` | Timing issue | Wait for secret creation |
| `Error configuring TLS` | Traefik started before cert | Restart Traefik |
| `Failed to pull image` | Network/registry issue | Check image name and pull secrets |
| `cannot proceed with backup` | Missing backup config | Check Cluster.spec.backup |
| `ObjectStore plugin conflict` | Using both methods | Use only barmanObjectStore |

### 5. Debugging Commands Reference

```bash
# Quick status check
kubectl get pods -A | grep -v Running | grep -v Completed

# Flux status
flux get all -A

# Certificate details
kubectl describe certificate <name> -n <namespace>

# Check ingress details
kubectl describe ingress <name> -n <namespace>

# View recent events
kubectl get events -n <namespace> --sort-by='.lastTimestamp'

# Check specific pod logs
kubectl logs -n <namespace> <pod-name> --tail=50

# Check controller logs
kubectl logs -n cert-manager -l app=cert-manager --tail=50
kubectl logs -n traefik -l app.kubernetes.io/name=traefik --tail=50
```

---

## TODO for Tomorrow

### 1. Test Backup Recovery

- [ ] Create a manual backup
- [ ] Delete the current cluster
- [ ] Restore from backup to a new cluster
- [ ] Verify data integrity
- [ ] Document the recovery process

### 2. Optimize Backup Schedule

- [ ] Change scheduled backup from 5 minutes to a production-appropriate interval
- [ ] Update retention policy if needed
- [ ] Test that scheduled backups still work

### 3. Improve Deployment Automation

- [ ] Add health checks to kustomizations
- [ ] Configure proper dependencies between kustomizations
- [ ] Consider adding a post-deploy job to handle Traefik restart

### 4. Documentation Updates

- [ ] Add backup recovery procedure to docs
- [ ] Create deployment runbook with exact commands
- [ ] Document all environment-specific values

---

## Reference Information

### Current Configuration

**Namespace**: `customer1`

**Database**:
- Cluster: `customer1-db`
- Instances: 3
- Storage: 1Gi per instance
- Backup destination: `https://alexmercurybackup.blob.core.windows.net/customer1`

**Application**:
- Deployment: `customer1-n8n`
- Image: `docker.n8n.io/n8nio/n8n:1.123.3`
- Port: 3008

**Ingress**:
- Host: `customer1.mercury.kubetest.uk`
- TLS: Let's Encrypt production
- Certificate: `customer1-tls`
- Ingress class: `traefik-traefik`

**Scheduled Backup**:
- Name: `customer1-db-backup`
- Schedule: Every 5 minutes
- Retention: 14 days

### Useful Commands

```bash
# Complete health check
kubectl get kustomizations -n flux-system && \
kubectl get certificate -A && \
kubectl get ingress -A && \
kubectl get pods -n customer1

# Force complete reconciliation
flux reconcile source git mercury-system && \
flux reconcile kustomization mercury-system-infra-controllers --with-source && \
flux reconcile kustomization mercury-system-apps --with-source

# View all resources in customer1 namespace
kubectl get all,secrets,configmaps,pvc,certificates,ingress -n customer1

# Check backup status
kubectl get backup,scheduledbackup -n customer1 && \
kubectl cnpg status -n customer1 customer1-db | grep -A 10 "Backup"
```

---

## Summary

Today we encountered and resolved:

1. **ObjectStore CRD issue** - Removed unsupported CRD reference
2. **Traefik TLS timing** - Documented restart procedure
3. **Storage placeholders** - Replaced with actual values
4. **Backup management** - Cleaned up test backups

**Key Takeaway**: Most issues were related to timing and configuration mismatches. Tomorrow's deployment should be much smoother with:
- Staged deployment process
- Proper health checks
- Clear understanding of component interactions

**Current Status**: ✅ All systems operational
- N8N accessible at https://customer1.mercury.kubetest.uk
- PostgreSQL cluster running with 3 instances
- Backups configured and working
- TLS certificates valid and routing functional
