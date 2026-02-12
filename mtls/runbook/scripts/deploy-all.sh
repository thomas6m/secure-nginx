#!/bin/bash
#####################################################################
# deploy-all.sh — Deploy Edge, Re-encrypt, and Passthrough apps
# in a single namespace with proper TLS handling.
#
# FIXES from original:
#   - Passthrough and Re-encrypt apps now use Flask with ssl_context
#   - Edge app uses plain HTTP Flask (TLS handled by router)
#   - Nginx sidecar NOT needed here (no mTLS between apps)
#   - Separate Containerfiles for TLS vs non-TLS apps
#####################################################################
set -euo pipefail

# Load .env if present
if [[ -f .env ]]; then
  export $(grep -v '^#' .env | xargs)
fi

: "${DOCKER_USER:?Missing DOCKER_USER}"
: "${DOCKER_PASS:?Missing DOCKER_PASS}"

# ─── Variables ───────────────────────────────────────────────────
NAMESPACE="network-ingress"
DOMAIN="apps.sno.example.com"
DOCKER_REPO="docker.io/thomas6m"
VERSION="v1"

echo "═══════════════════════════════════════════════════════════"
echo "  OpenShift Route Demo — All-in-One Deployment"
echo "═══════════════════════════════════════════════════════════"

# ─── Docker Login ────────────────────────────────────────────────
echo "🔐 Logging in to Docker Hub..."
echo "$DOCKER_PASS" | podman login docker.io --username "$DOCKER_USER" --password-stdin

# ─── Project Setup ───────────────────────────────────────────────
oc project "$NAMESPACE" 2>/dev/null || oc new-project "$NAMESPACE"

# ─── Generate CA ─────────────────────────────────────────────────
mkdir -p certs
echo "🔧 Generating CA..."
openssl genpkey -algorithm RSA -out certs/ca.key 2>/dev/null
openssl req -x509 -new -key certs/ca.key -out certs/ca.crt -days 3650 -subj "/CN=my-ca"

# ─── Generate Per-App Certs ─────────────────────────────────────
for app in edgeapp reencryptapp passthroughapp; do
  echo "🔧 Generating certificate for $app..."
  cat > certs/${app}-openssl.cnf <<EOF
[ req ]
default_bits       = 2048
prompt             = no
default_md         = sha256
req_extensions     = req_ext
distinguished_name = dn

[ dn ]
CN = ${app}-service.${NAMESPACE}.svc.cluster.local

[ req_ext ]
subjectAltName = @alt_names

[ alt_names ]
DNS.1 = ${app}-service
DNS.2 = ${app}-service.${NAMESPACE}.svc.cluster.local
DNS.3 = ${app}-service.${NAMESPACE}.svc
DNS.4 = ${app}.${DOMAIN}
EOF

  openssl genpkey -algorithm RSA -out certs/${app}.key 2>/dev/null
  openssl req -new -key certs/${app}.key -out certs/${app}.csr -config certs/${app}-openssl.cnf
  openssl x509 -req -in certs/${app}.csr -CA certs/ca.crt -CAkey certs/ca.key -CAcreateserial \
    -out certs/${app}.crt -days 3650 -extensions req_ext -extfile certs/${app}-openssl.cnf 2>/dev/null
done

# ─── ConfigMaps ──────────────────────────────────────────────────
echo "📦 Creating ConfigMaps..."
for app in edgeapp reencryptapp passthroughapp; do
  oc create configmap ${app}-certs \
    --from-file=server.crt=certs/${app}.crt \
    --from-file=server.key=certs/${app}.key \
    --from-file=ca.crt=certs/ca.crt \
    --dry-run=client -o yaml | oc apply -f -
done

# ─── App Source: Plain HTTP (for Edge) ───────────────────────────
cat > app-http.py <<'PYEOF'
from flask import Flask, jsonify
app = Flask(__name__)

@app.route('/')
def hello():
    return jsonify({"message": "Hello from Flask (Edge - HTTP backend)!"})

@app.route('/healthz')
def healthz():
    return "OK", 200

if __name__ == "__main__":
    app.run(host='0.0.0.0', port=5000)
PYEOF

cat > Containerfile.http <<'DEOF'
FROM python:3.10-slim
RUN adduser --disabled-password --gecos '' appuser
WORKDIR /home/appuser
COPY app-http.py /home/appuser/app.py
RUN chown -R appuser:appuser /home/appuser && chmod -R 755 /home/appuser
RUN pip install flask
USER appuser
EXPOSE 5000
CMD ["python", "app.py"]
DEOF

# ─── App Source: HTTPS (for Re-encrypt & Passthrough) ────────────
cat > app-https.py <<'PYEOF'
from flask import Flask, jsonify
import ssl

app = Flask(__name__)

@app.route('/')
def hello():
    return jsonify({"message": "Hello from Flask (TLS-enabled backend)!"})

@app.route('/healthz')
def healthz():
    return "OK", 200

if __name__ == "__main__":
    context = ssl.create_default_context(ssl.Purpose.CLIENT_AUTH)
    context.load_cert_chain(certfile='/certs/server.crt', keyfile='/certs/server.key')
    context.load_verify_locations(cafile='/certs/ca.crt')
    context.verify_mode = ssl.CERT_OPTIONAL
    app.run(host='0.0.0.0', port=5000, ssl_context=context)
PYEOF

cat > Containerfile.https <<'DEOF'
FROM python:3.10-slim
RUN adduser --disabled-password --gecos '' appuser
WORKDIR /home/appuser
COPY app-https.py /home/appuser/app.py
RUN chown -R appuser:appuser /home/appuser && chmod -R 755 /home/appuser
RUN pip install flask
USER appuser
EXPOSE 5000
CMD ["python", "app.py"]
DEOF

# ─── Build & Push Images ────────────────────────────────────────
echo "📦 Building and pushing images..."

# Edge uses HTTP backend
podman build -f Containerfile.http -t ${DOCKER_REPO}/edgeapp:${VERSION} .
podman push ${DOCKER_REPO}/edgeapp:${VERSION}

# Re-encrypt and Passthrough use HTTPS backend
podman build -f Containerfile.https -t ${DOCKER_REPO}/reencryptapp:${VERSION} .
podman push ${DOCKER_REPO}/reencryptapp:${VERSION}

podman build -f Containerfile.https -t ${DOCKER_REPO}/passthroughapp:${VERSION} .
podman push ${DOCKER_REPO}/passthroughapp:${VERSION}

# ─── Deploy Edge App ────────────────────────────────────────────
echo "🚀 Deploying edgeapp..."
cat > edgeapp-deploy.yaml <<EOF
apiVersion: apps/v1
kind: Deployment
metadata:
  name: edgeapp
  namespace: ${NAMESPACE}
spec:
  replicas: 1
  selector:
    matchLabels:
      app: edgeapp
  template:
    metadata:
      labels:
        app: edgeapp
    spec:
      containers:
      - name: edgeapp
        image: ${DOCKER_REPO}/edgeapp:${VERSION}
        ports:
        - containerPort: 5000
        readinessProbe:
          httpGet:
            path: /healthz
            port: 5000
          initialDelaySeconds: 5
          periodSeconds: 10
        livenessProbe:
          httpGet:
            path: /healthz
            port: 5000
          initialDelaySeconds: 10
          periodSeconds: 20
---
apiVersion: v1
kind: Service
metadata:
  name: edgeapp-service
  namespace: ${NAMESPACE}
spec:
  selector:
    app: edgeapp
  ports:
  - protocol: TCP
    port: 8080
    targetPort: 5000
---
apiVersion: route.openshift.io/v1
kind: Route
metadata:
  name: edgeapp-route
  namespace: ${NAMESPACE}
spec:
  host: edgeapp.${DOMAIN}
  to:
    kind: Service
    name: edgeapp-service
  port:
    targetPort: 8080
  tls:
    termination: edge
    certificate: |
$(sed 's/^/      /' certs/edgeapp.crt)
    key: |
$(sed 's/^/      /' certs/edgeapp.key)
    caCertificate: |
$(sed 's/^/      /' certs/ca.crt)
EOF
oc apply -f edgeapp-deploy.yaml

# ─── Deploy Re-encrypt App ──────────────────────────────────────
echo "🚀 Deploying reencryptapp..."
cat > reencryptapp-deploy.yaml <<EOF
apiVersion: apps/v1
kind: Deployment
metadata:
  name: reencryptapp
  namespace: ${NAMESPACE}
spec:
  replicas: 1
  selector:
    matchLabels:
      app: reencryptapp
  template:
    metadata:
      labels:
        app: reencryptapp
    spec:
      containers:
      - name: reencryptapp
        image: ${DOCKER_REPO}/reencryptapp:${VERSION}
        ports:
        - containerPort: 5000
        readinessProbe:
          httpGet:
            path: /healthz
            port: 5000
            scheme: HTTPS
          initialDelaySeconds: 5
          periodSeconds: 10
        livenessProbe:
          httpGet:
            path: /healthz
            port: 5000
            scheme: HTTPS
          initialDelaySeconds: 10
          periodSeconds: 20
        volumeMounts:
        - name: certs
          mountPath: /certs
          readOnly: true
      volumes:
      - name: certs
        configMap:
          name: reencryptapp-certs
---
apiVersion: v1
kind: Service
metadata:
  name: reencryptapp-service
  namespace: ${NAMESPACE}
spec:
  selector:
    app: reencryptapp
  ports:
  - protocol: TCP
    port: 443
    targetPort: 5000
---
apiVersion: route.openshift.io/v1
kind: Route
metadata:
  name: reencryptapp-route
  namespace: ${NAMESPACE}
spec:
  host: reencryptapp.${DOMAIN}
  to:
    kind: Service
    name: reencryptapp-service
  port:
    targetPort: 443
  tls:
    termination: reencrypt
    destinationCACertificate: |
$(sed 's/^/      /' certs/ca.crt)
EOF
oc apply -f reencryptapp-deploy.yaml

# ─── Deploy Passthrough App ─────────────────────────────────────
echo "🚀 Deploying passthroughapp..."
cat > passthroughapp-deploy.yaml <<EOF
apiVersion: apps/v1
kind: Deployment
metadata:
  name: passthroughapp
  namespace: ${NAMESPACE}
spec:
  replicas: 1
  selector:
    matchLabels:
      app: passthroughapp
  template:
    metadata:
      labels:
        app: passthroughapp
    spec:
      containers:
      - name: passthroughapp
        image: ${DOCKER_REPO}/passthroughapp:${VERSION}
        ports:
        - containerPort: 5000
        readinessProbe:
          httpGet:
            path: /healthz
            port: 5000
            scheme: HTTPS
          initialDelaySeconds: 5
          periodSeconds: 10
        livenessProbe:
          httpGet:
            path: /healthz
            port: 5000
            scheme: HTTPS
          initialDelaySeconds: 10
          periodSeconds: 20
        volumeMounts:
        - name: certs
          mountPath: /certs
          readOnly: true
      volumes:
      - name: certs
        configMap:
          name: passthroughapp-certs
---
apiVersion: v1
kind: Service
metadata:
  name: passthroughapp-service
  namespace: ${NAMESPACE}
spec:
  selector:
    app: passthroughapp
  ports:
  - protocol: TCP
    port: 443
    targetPort: 5000
---
apiVersion: route.openshift.io/v1
kind: Route
metadata:
  name: passthroughapp-route
  namespace: ${NAMESPACE}
spec:
  host: passthroughapp.${DOMAIN}
  to:
    kind: Service
    name: passthroughapp-service
  port:
    targetPort: 443
  tls:
    termination: passthrough
EOF
oc apply -f passthroughapp-deploy.yaml

# ─── Summary ────────────────────────────────────────────────────
echo ""
echo "═══════════════════════════════════════════════════════════"
echo "  Deployment Complete!"
echo "═══════════════════════════════════════════════════════════"
echo ""
echo "  Edge:        curl -k https://edgeapp.${DOMAIN}"
echo "  Re-encrypt:  curl -k https://reencryptapp.${DOMAIN}"
echo "  Passthrough: curl -k https://passthroughapp.${DOMAIN}"
echo ""
echo "  Check pods:  oc get pods -n ${NAMESPACE}"
echo "═══════════════════════════════════════════════════════════"
