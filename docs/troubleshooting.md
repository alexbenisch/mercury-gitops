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

---

## Validating n8n Database Integration

### Overview
n8n stores all workflow data, executions, credentials, and settings in a PostgreSQL database. This section describes how to validate that n8n is correctly connected to the database and storing data properly.

### Database Configuration

**Important:** The n8n application uses a database named `app`, not `n8n`. This is configured via environment variables:
- `DB_POSTGRESDB_DATABASE=app`
- `DB_POSTGRESDB_USER=app`
- `DB_POSTGRESDB_HOST=customer1-db-rw.customer1.svc.cluster.local`

### Quick Validation

To quickly check if n8n is working correctly:

```bash
# 1. Check n8n pod is running
kubectl get pods -n customer1 -l app=n8n
# Expected: STATUS = Running, READY = 1/1

# 2. Check database pods are running
kubectl get pods -n customer1 | grep db
# Expected: 3 pods (customer1-db-1, customer1-db-2, customer1-db-3) all Running

# 3. Verify database exists and has correct tables
kubectl exec -n customer1 customer1-db-1 -- psql -U postgres -d app -c "\dt" | grep execution_entity
# Expected: Should show execution_entity table
```

### Detailed Database Validation

#### 1. Check Database and Tables

```bash
# List all databases
kubectl exec -n customer1 customer1-db-1 -- psql -U postgres -c "\l"
# Expected: Should show 'app' database owned by 'app' user

# List all n8n tables in the app database
kubectl exec -n customer1 customer1-db-1 -- psql -U postgres -d app -c "\dt"
# Expected: 52 n8n tables including:
#   - execution_entity (workflow executions)
#   - execution_data (execution results)
#   - workflow_entity (workflow definitions)
#   - credentials_entity (stored credentials)
#   - user (user accounts)
```

#### 2. Validate Execution Storage

Check if workflow executions are being stored correctly:

```bash
# Count total executions
kubectl exec -n customer1 customer1-db-1 -- psql -U postgres -d app -c "SELECT COUNT(*) as total_executions FROM execution_entity;"

# View recent executions with details
kubectl exec -n customer1 customer1-db-1 -- psql -U postgres -d app -c "SELECT id, \"workflowId\", mode, finished, \"startedAt\", \"stoppedAt\" FROM execution_entity ORDER BY \"startedAt\" DESC LIMIT 10;"

# Check execution statistics (finished vs unfinished)
kubectl exec -n customer1 customer1-db-1 -- psql -U postgres -d app -c "SELECT COUNT(*) as total, COUNT(CASE WHEN finished = true THEN 1 END) as finished, COUNT(CASE WHEN finished = false THEN 1 END) as running FROM execution_entity;"
```

#### 3. Inspect Execution Details

```bash
# View execution status breakdown
kubectl exec -n customer1 customer1-db-1 -- psql -U postgres -d app -c "SELECT status, COUNT(*) as count FROM execution_entity GROUP BY status;"

# Check execution modes (manual, trigger, webhook, etc.)
kubectl exec -n customer1 customer1-db-1 -- psql -U postgres -d app -c "SELECT mode, COUNT(*) as count FROM execution_entity GROUP BY mode;"

# View table structure
kubectl exec -n customer1 customer1-db-1 -- psql -U postgres -d app -c "\d execution_entity"
```

#### 4. Check Database Size and Health

```bash
# Check database size
kubectl exec -n customer1 customer1-db-1 -- psql -U postgres -d app -c "SELECT pg_size_pretty(pg_database_size('app')) as database_size;"

# Check table sizes
kubectl exec -n customer1 customer1-db-1 -- psql -U postgres -d app -c "SELECT schemaname, tablename, pg_size_pretty(pg_total_relation_size(schemaname||'.'||tablename)) AS size FROM pg_tables WHERE schemaname = 'public' ORDER BY pg_total_relation_size(schemaname||'.'||tablename) DESC LIMIT 10;"

# Check for table bloat or issues
kubectl exec -n customer1 customer1-db-1 -- psql -U postgres -d app -c "SELECT COUNT(*) as table_count FROM information_schema.tables WHERE table_schema = 'public' AND table_type = 'BASE TABLE';"
# Expected: 52 tables
```

### Interactive Database Session

For more detailed inspection, you can start an interactive psql session:

```bash
# Connect to database interactively
kubectl exec -it -n customer1 customer1-db-1 -- psql -U postgres -d app

# Once connected, useful commands:
\dt                          # List all tables
\d execution_entity          # Describe execution_entity table
\d+ execution_entity         # Detailed table description with indexes
SELECT * FROM execution_entity ORDER BY "startedAt" DESC LIMIT 1;  # View latest execution
\q                           # Quit
```

### Verify n8n Application Configuration

Check that n8n is configured with the correct database settings:

```bash
# View n8n database environment variables
kubectl exec -n customer1 $(kubectl get pod -n customer1 -l app=n8n -o jsonpath='{.items[0].metadata.name}') -- env | grep DB

# Expected output should include:
# DB_TYPE=postgresdb
# DB_POSTGRESDB_DATABASE=app
# DB_POSTGRESDB_USER=app
# DB_POSTGRESDB_HOST=customer1-db-rw.customer1.svc.cluster.local
# DB_POSTGRESDB_PORT=5432
```

### Common Issues and Solutions

**Issue: No executions in database**
- Check if workflows are active: Access n8n UI and verify workflows are activated
- Check n8n logs: `kubectl logs -n customer1 -l app=n8n`
- Verify database connectivity from n8n pod

**Issue: Database connection errors**
- Verify database pods are running: `kubectl get pods -n customer1 | grep db`
- Check database service: `kubectl get svc -n customer1 customer1-db-rw`
- Test connection from n8n pod:
  ```bash
  kubectl exec -n customer1 -l app=n8n -- nc -zv customer1-db-rw.customer1.svc.cluster.local 5432
  ```

**Issue: "database n8n does not exist"**
- This is expected! The database is named `app`, not `n8n`
- Always use `-d app` when connecting to the n8n database

### Expected Healthy State

A healthy n8n installation should show:
- ✅ n8n pod running (1/1 Ready)
- ✅ 3 database pods running (customer1-db-1, customer1-db-2, customer1-db-3)
- ✅ Database `app` exists with 52 tables
- ✅ Executions being stored in `execution_entity` table
- ✅ Database environment variables correctly configured in n8n pod
- ✅ Database size growing as workflows execute

### Reference: Key n8n Tables

| Table Name | Purpose |
|------------|---------|
| `execution_entity` | Stores workflow execution metadata |
| `execution_data` | Stores execution input/output data |
| `execution_metadata` | Additional execution metadata |
| `workflow_entity` | Workflow definitions |
| `credentials_entity` | Encrypted credentials |
| `user` | User accounts |
| `settings` | n8n instance settings |
| `tag_entity` | Tags for organization |
| `webhook_entity` | Webhook configurations |
