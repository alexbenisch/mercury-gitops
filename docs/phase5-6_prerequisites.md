# Phase 5-6 Prerequisites

This document outlines the prerequisites and important considerations for Phase 5 (n8n deployment) and Phase 6 (CloudNativePG PostgreSQL cluster).

## Important Notes

### Timing Considerations

When deploying applications with TLS certificates, be aware of the following timing issue:

**Certificate Issuance Timing:**
- Cert-manager typically takes 20-60 seconds to issue certificates after ingress creation
- Traefik may start before certificates are issued and cache a "secret not found" state
- **Solution**: If HTTPS routing doesn't work immediately, restart Traefik after certificates are ready:
  ```bash
  # Wait for certificate to be ready
  kubectl get certificate -n customer1
  # Look for READY=True

  # If Traefik has TLS errors, restart it
  kubectl rollout restart deployment traefik-traefik -n traefik
  ```

**Deployment Order:**
1. Infrastructure controllers (Traefik, cert-manager, external-dns) - deployed via Flux
2. Wait for all infrastructure to be healthy
3. Deploy applications (n8n, PostgreSQL)
4. Monitor certificate issuance
5. Restart Traefik if needed after certificates are issued

See `docs/troubleshooting.md` for detailed troubleshooting steps.

---

## Setup Steps

### 1. Register Provider
Register the required Azure provider for the deployment.

### 2. Create Domain
Create the domain: **kubetest.uk**

### 3. Terraform Apply
Run the Terraform configuration:
```bash
terraform apply
```

### 4. Terraform Outputs
After successful terraform apply, retrieve the outputs:
```bash
terraform output
```

Expected outputs:
```
aks_keyvault_secrets_provider_client_id = "00000000-0000-0000-0000-000000000000"
customer1_backup_path = "https://<storage-account-name>.blob.core.windows.net/customer1"
key_vault_name = "kv-mercury-staging"
key_vault_uri = "https://kv-mercury-staging.vault.azure.net/"
storage_account_name = "<storage-account-name>"
```

### 5. Azure Account Verification
Verify your Azure account configuration:
```bash
az account list
```

Expected output:
```json
[
  {
    "cloudName": "AzureCloud",
    "homeTenantId": "00000000-0000-0000-0000-000000000000",
    "id": "11111111-1111-1111-1111-111111111111",
    "isDefault": true,
    "managedByTenants": [],
    "name": "mercury",
    "state": "Enabled",
    "tenantDefaultDomain": "example.onmicrosoft.com",
    "tenantDisplayName": "Default Directory",
    "tenantId": "00000000-0000-0000-0000-000000000000",
    "user": {
      "name": "user@example.com",
      "type": "user"
    }
  }
]
```

---

## Post-Deployment Verification

After completing the terraform apply and deploying applications, verify everything is working:

### 1. Check Infrastructure Status

```bash
# Verify Flux kustomizations
flux get kustomizations
# Expected: All should show READY=True

# Check infrastructure controllers
kubectl get pods -n traefik
kubectl get pods -n cert-manager
kubectl get pods -n external-dns

# All pods should be Running
```

### 2. Verify Application Deployment

```bash
# Check customer1 namespace resources
kubectl get all -n customer1

# Expected output:
# - customer1-n8n deployment: 1/1 Running
# - customer1-db cluster: 3/3 instances Running
# - Services: customer1-n8n, customer1-db-rw, customer1-db-ro, customer1-db-r
```

### 3. Verify TLS Certificates

```bash
# Check certificate status
kubectl get certificate -n customer1
# Expected: READY=True

# If certificate exists but HTTPS doesn't work
kubectl get secret customer1-tls -n customer1
# If secret exists, restart Traefik
kubectl rollout restart deployment traefik-traefik -n traefik
```

### 4. Test HTTPS Connectivity

```bash
# Test DNS resolution
nslookup customer1.mercury.kubetest.uk
# Should return the Traefik LoadBalancer IP

# Test HTTPS endpoint
curl -I https://customer1.mercury.kubetest.uk
# Expected: HTTP/2 200

# Verify certificate
echo | openssl s_client -connect customer1.mercury.kubetest.uk:443 \
  -servername customer1.mercury.kubetest.uk 2>/dev/null | \
  openssl x509 -noout -issuer -subject -dates
# Expected: issuer=Let's Encrypt (R13 or similar)
```

### 5. Common Issues

If you encounter issues:

- **Pods not starting**: Check `kubectl describe pod <pod-name> -n customer1`
- **Certificate not ready**: Check `kubectl describe certificate customer1-tls -n customer1`
- **HTTPS not working but certificate ready**: Restart Traefik (see Timing Considerations above)
- **Database connection errors**: Verify secrets are mounted: `kubectl get secret -n customer1`

For detailed troubleshooting, see `docs/troubleshooting.md`.

---

## Resources Created

After successful deployment, you should have:

**Azure Resources:**
- AKS cluster with 2+ nodes
- Key Vault with secrets (db credentials, storage credentials, API tokens)
- Storage Account for PostgreSQL backups
- Container for customer1 backups

**Kubernetes Resources:**
- Namespace: `customer1`
- PostgreSQL cluster: 3 instances with automated backups
- n8n deployment: 1 replica with persistent storage
- Ingress with TLS certificate
- Secrets synced from Azure Key Vault via SecretProviderClass

**Networking:**
- DNS record: `customer1.mercury.kubetest.uk` → Traefik LoadBalancer IP
- TLS certificate: Let's Encrypt production certificate
- Exposed ports: 80 (HTTP redirect), 443 (HTTPS)
