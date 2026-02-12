#!/bin/bash
#####################################################################
# cleanup.sh — Remove all lab resources
#####################################################################
set -euo pipefail

echo "🧹 Cleaning up all lab resources..."

# ─── Network Ingress Namespace ───────────────────────────────────
echo "Cleaning network-ingress namespace..."
oc delete all --all -n network-ingress 2>/dev/null || true
oc delete configmap edgeapp-certs reencryptapp-certs passthroughapp-certs -n network-ingress 2>/dev/null || true
oc delete project network-ingress 2>/dev/null || true

# ─── mTLS Namespace ─────────────────────────────────────────────
echo "Cleaning mtls namespace..."
oc delete all --all -n mtls 2>/dev/null || true
oc delete configmap app1-client-cert-configmap app2-cert-configmap app2-nginx-config -n mtls 2>/dev/null || true
oc delete project mtls 2>/dev/null || true

# ─── Default Namespace Resources ─────────────────────────────────
echo "Cleaning default namespace resources..."
oc delete deployment golang-http golang-edge golang-reencrypt ingress-passthrough reencryptapp -n default 2>/dev/null || true
oc delete svc golang-http-svc golang-edge golang-reencrypt ingress-passthrough reencryptapp-service -n default 2>/dev/null || true
oc delete route golang-http-route golang-edge-route golang-reencrypt-route ingress-passthrough reencryptapp-route -n default 2>/dev/null || true
oc delete configmap ssl-config reencryptapp-certs -n default 2>/dev/null || true

# ─── Clean Completed Pods Cluster-wide ───────────────────────────
echo "Cleaning completed pods..."
oc get pods --all-namespaces --field-selector=status.phase=Succeeded -o json | oc delete -f - 2>/dev/null || true

echo "✅ Cleanup complete!"
