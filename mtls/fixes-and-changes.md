# Fixes & Changes Log

This document lists all corrections and improvements made from the original runbooks.

---

## Critical Fixes

### 1. Passthrough Route — Pod Must Serve TLS
**Original bug:** The automation script (`network-ingress-automation.sh`) used a plain HTTP Flask app for all three route types, including passthrough. Passthrough routes forward raw TLS to the pod — if the pod doesn't terminate TLS, the connection fails.

**Fix:** Created separate images:
- `edgeapp` → plain HTTP Flask (router handles TLS)
- `reencryptapp` → Flask with `ssl_context` (pod terminates TLS)
- `passthroughapp` → Flask with `ssl_context` (pod terminates TLS)

### 2. Nginx Sidecar Missing mTLS Directives
**Original bug:** The `app2-nginx-config.yaml` in `mtls-v1.txt` did not include `ssl_verify_client on;` or `ssl_client_certificate /certs/ca.crt;`. Without these, Nginx accepts any connection (TLS but not mutual TLS).

**Fix:** Added to nginx.conf:
```nginx
ssl_verify_client on;
ssl_client_certificate /certs/ca.crt;
```

### 3. Duplicate DNS.6 in SAN Config
**Original bug:** In `san.cnf` used by the Java passthrough labs, `DNS.6` appeared twice:
```
DNS.6 = ingress-http.default.svc.cluster.local
DNS.6 = ingress-https.default.svc.cluster.local   # Overwrites the above
```

**Fix:** Changed to `DNS.6` and `DNS.7`.

### 4. App1 Client Cert Missing SANs
**Original bug:** In `mtls-runbook.txt`, App1's client cert was generated with only `-subj "/CN=app1"` and no Subject Alternative Names. While technically functional for client auth, this is inconsistent and less robust.

**Fix:** App1 cert now uses an OpenSSL config with SANs matching service DNS names.

---

## Improvements

### 5. Added /healthz Endpoints
All Flask apps now include a `/healthz` endpoint for Kubernetes health checks. The mTLS App1 previously had no health endpoint.

### 6. HTTPS Health Probes for TLS Pods
Re-encrypt and passthrough deployments now use `scheme: HTTPS` in readiness/liveness probes, since these pods serve HTTPS.

### 7. Nginx X-Client-DN Header
The mTLS Nginx config now passes the client certificate DN to Flask via `X-Client-DN` header, enabling the backend to identify the calling service.

### 8. Consolidated Certificate Generation
All labs now share a single certificate generation section (Section 3) instead of each lab re-generating certs independently.

### 9. Cleanup Script
Added `scripts/cleanup.sh` to tear down all lab resources across namespaces.

### 10. ConfigMap Keys Standardized
Certificate ConfigMaps now use consistent key names (`server.crt`, `server.key`, `ca.crt`) so the same mount path works across apps.
