# Kubernetes YAML Manifests

All YAML files referenced in the runbook are embedded inline in `00-RUNBOOK-MAIN.md`.

For quick reference, here are the key manifests organized by lab:

## Lab 1 — HTTP Route
- `golang-http.yaml` — Deployment + Service
- `golang-http-route.yaml` — HTTP Route (no TLS)

## Lab 2 — Edge Route
- `golang-edge.yaml` — Deployment + Service

## Lab 3 — Re-encrypt Route
- `reencryptapp-deploy.yaml` — Deployment + Service

## Lab 4 — Passthrough Route
- `passthrough-deploy.yaml` — Deployment + Service

## Lab 5 — mTLS
- `app2-nginx-config.yaml` — Nginx ConfigMap (with mTLS enforcement)
- `app2-deployment.yaml` — App2 Deployment (Flask + Nginx sidecar)
- `app1-deployment.yaml` — App1 Deployment + Service
- `app1-route.yaml` — Passthrough Route for App1

## Automation
- `scripts/deploy-all.sh` — Deploys edge, re-encrypt, passthrough in one go
- `scripts/cleanup.sh` — Tears down all lab resources
