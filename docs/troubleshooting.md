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

---

## Traefik TLS Routing Issues

### Issue: Traefik reports "secret does not exist" but certificate is valid

**Symptoms:**
```bash
# Traefik logs show repeated TLS errors
kubectl logs -n traefik -l app.kubernetes.io/name=traefik --tail=50

# Error output:
Error configuring TLS error="secret customer1/customer1-tls does not exist"

# But the certificate and secret actually exist
kubectl get certificate -n customer1
# NAME            READY   SECRET          AGE
# customer1-tls   True    customer1-tls   44m

kubectl get secret customer1-tls -n customer1
# NAME            TYPE                DATA   AGE
# customer1-tls   kubernetes.io/tls   2      44m
```

**Root Cause:**
This is a **timing issue**. Traefik starts and configures ingress routes before cert-manager has issued the TLS certificate. Even though cert-manager successfully creates the certificate seconds later, Traefik has already cached the "secret not found" state and doesn't automatically reload the configuration.

**Diagnosis:**
```bash
# Check if certificate is ready
kubectl get certificate -n customer1
# Look for READY=True

# Check if secret exists
kubectl get secret customer1-tls -n customer1

# Check Traefik logs for TLS errors
kubectl logs -n traefik -l app.kubernetes.io/name=traefik --tail=50 | grep -i "error configuring tls"

# Try accessing the HTTPS endpoint
curl -I https://customer1.mercury.kubetest.uk
# If routing is broken, you may see connection errors or HTTP 404
```

**Solution:**
Restart Traefik to pick up the TLS secret:

```bash
# Restart Traefik deployment
kubectl rollout restart deployment traefik-traefik -n traefik

# Wait for pod to be ready
kubectl wait --for=condition=ready pod -l app.kubernetes.io/name=traefik -n traefik --timeout=60s

# Verify HTTPS is working
curl -I https://customer1.mercury.kubetest.uk
# Expected: HTTP/2 200

# Verify certificate
echo | openssl s_client -connect customer1.mercury.kubetest.uk:443 \
  -servername customer1.mercury.kubetest.uk 2>/dev/null | \
  openssl x509 -noout -issuer -subject -dates
# Expected: issuer=C = US, O = Let's Encrypt, CN = R13 (or similar)
```

**Prevention:**
To avoid this issue in future deployments:

1. **Deploy in stages**: Deploy infrastructure (including cert-manager) first, wait for certificates to be issued, then deploy applications
2. **Use HelmRelease dependencies**: Configure HelmRelease dependencies so Traefik waits for cert-manager to be ready
3. **Monitor certificate status**: Add a readiness check that waits for certificates before marking deployment as complete

**Key Learnings:**
- Traefik doesn't automatically reload TLS configuration when secrets are created after startup
- Certificate issuance typically takes 20-60 seconds after ingress creation
- Always verify both certificate status (READY=True) and actual HTTPS connectivity
- In GitOps deployments, timing issues between components are common - restart strategies help resolve them

**Verification:**
After restarting Traefik, verify everything is working:

```bash
# Check ingress has ADDRESS and correct ports
kubectl get ingress -n customer1
# Expected: PORTS = 80, 443

# Check DNS resolution
nslookup customer1.mercury.kubetest.uk
# Should return the LoadBalancer IP

# Check HTTPS response
curl -I https://customer1.mercury.kubetest.uk
# Expected: HTTP/2 200

# Check certificate details
kubectl describe certificate customer1-tls -n customer1
# Look for: Status: True, Type: Ready

# Check Traefik logs (should be clean)
kubectl logs -n traefik -l app.kubernetes.io/name=traefik --tail=20
# Should not show TLS configuration errors
```
