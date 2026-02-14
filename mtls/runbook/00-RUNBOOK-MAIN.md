# OpenShift Routes & mTLS — Consolidated Runbook

**Version:** 2.0 (Consolidated & Corrected)
**Platform:** OpenShift (Single Node / SNO)
**Cluster Domain:** `apps.sno.example.com` (adjust to your environment)
**Last Updated:** February 2026

---

## Table of Contents

1. [Overview & Architecture](#1-overview--architecture)
2. [Prerequisites](#2-prerequisites)
3. [Certificate Generation (Shared)](#3-certificate-generation-shared)
4. [Lab 1 — HTTP Route (No TLS)](#4-lab-1--http-route-no-tls)
5. [Lab 2 — Edge Route](#5-lab-2--edge-route)
6. [Lab 3 — Re-encrypt Route](#6-lab-3--re-encrypt-route)
7. [Lab 4 — Passthrough Route](#7-lab-4--passthrough-route)
8. [Lab 5 — mTLS (App-to-App)](#8-lab-5--mtls-app-to-app)
9. [Automation Script (All-in-One)](#9-automation-script-all-in-one)
10. [Troubleshooting](#10-troubleshooting)
11. [Quick Reference Cheat Sheet](#11-quick-reference-cheat-sheet)

---

## 1. Overview & Architecture

### OpenShift Route Types

| Route Type    | TLS at Router | TLS to Pod | Use Case |
|---------------|:---:|:---:|---|
| **HTTP**      | ✗ | ✗ | Non-sensitive internal apps |
| **Edge**      | ✓ (terminates) | ✗ | Most web apps — TLS offloaded at router |
| **Re-encrypt**| ✓ (terminates) | ✓ (new TLS) | End-to-end encryption with separate certs |
| **Passthrough**| ✗ (forwards) | ✓ (pod handles) | Pod controls TLS — needed for mTLS, custom ciphers |

### Traffic Flow Diagrams

```
HTTP:
  Client --HTTP--> Router --HTTP--> Pod:8080

Edge:
  Client --HTTPS--> Router (terminates TLS) --HTTP--> Pod:8080

Re-encrypt:
  Client --HTTPS--> Router (terminates TLS, re-encrypts) --HTTPS--> Pod:5000

Passthrough:
  Client --HTTPS--> Router (passes through) --HTTPS--> Pod:8443

mTLS (App1 → App2):
  Client --HTTPS--> App1 (via Route) --HTTPS+mTLS--> App2 (Nginx sidecar) --HTTP--> App2 (Flask)
```

---

## 2. Prerequisites

### System Packages (Build Server / Jump Server)

```bash
dnf -y install net-tools telnet curl wget traceroute nmap-ncat git \
  httpd-tools jq nfs-utils
dnf install -y epel-release && dnf update -y

# For Java apps
dnf install -y java-17-openjdk java-17-openjdk-devel maven podman

# Verify
java -version
mvn -version
podman --version
oc version
```

### Environment Variables (Set Once)

```bash
export DOMAIN="apps.sno.example.com"        # Your cluster domain
export DOCKER_REPO="docker.io/thomas6m"      # Your container registry
export DOCKER_USER="your-user"
export DOCKER_PASS="your-pass"

# Login to registry
echo "$DOCKER_PASS" | podman login docker.io --username "$DOCKER_USER" --password-stdin
```

---

## 3. Certificate Generation (Shared)

All labs share a single CA and set of server/client certificates. Generate them once.

```bash
mkdir -p /data/project/certs && cd /data/project/certs
```

### 3.1 — CA Certificate

```bash
openssl genrsa -out ca.key 4096
openssl req -x509 -new -nodes -key ca.key -sha256 -days 3650 \
  -out ca.crt \
  -subj "/CN=Lab Certificate Authority/O=Home/OU=Dev/L=City/ST=State/C=US"
```

### 3.2 — Server Certificate (with SANs)

```bash
cat > san.cnf <<'EOF'
[req]
distinguished_name = req_distinguished_name
req_extensions = v3_req
prompt = no

[req_distinguished_name]
CN = localhost
O = Home
OU = Dev
L = City
ST = State
C = US

[v3_req]
keyUsage = keyEncipherment, dataEncipherment, digitalSignature
extendedKeyUsage = serverAuth
subjectAltName = @alt_names

[alt_names]
DNS.1 = localhost
DNS.2 = ingress-edge.apps.sno1.example.com
DNS.3 = ingress-passthrough.apps.sno1.example.com
DNS.4 = ingress-reencrypt.apps.sno1.example.com
DNS.5 = ingress-http.apps.sno1.example.com
DNS.6 = ingress-http.default.svc.cluster.local
DNS.7 = ingress-https.default.svc.cluster.local
EOF

openssl genrsa -out server.key 2048
openssl req -new -key server.key -out server.csr -config san.cnf
openssl x509 -req -in server.csr -CA ca.crt -CAkey ca.key -CAcreateserial \
  -out server.crt -days 365 -sha256 -extfile san.cnf -extensions v3_req

# Verify
openssl verify -CAfile ca.crt server.crt
openssl x509 -in server.crt -text -noout | grep -A 1 "Subject Alternative Name"
```

> **FIX from original:** DNS.6 was duplicated — now DNS.6 and DNS.7 are unique.

### 3.3 — Client Certificate (for mTLS / Passthrough testing)

```bash
cat > client-san.cnf <<'EOF'
[req]
distinguished_name = req_distinguished_name
req_extensions = v3_req
prompt = no

[req_distinguished_name]
CN = client
O = Home
OU = Dev
L = City
ST = State
C = US

[v3_req]
keyUsage = digitalSignature
extendedKeyUsage = clientAuth
EOF

openssl genrsa -out client.key 2048
openssl req -new -key client.key -out client.csr -config client-san.cnf
openssl x509 -req -in client.csr -CA ca.crt -CAkey ca.key -CAcreateserial \
  -out client.crt -days 365 -sha256 -extfile client-san.cnf -extensions v3_req

openssl verify -CAfile ca.crt client.crt
```

### 3.4 — Java Keystores (for Java Passthrough app)

```bash
# PKCS12 from server cert
openssl pkcs12 -export -in server.crt -inkey server.key \
  -out server.p12 -name mykey -password pass:changeit

# JKS keystore
keytool -importkeystore \
  -srckeystore server.p12 -srcstoretype PKCS12 -srcstorepass changeit \
  -destkeystore keystore.jks -deststoretype JKS -deststorepass changeit

# Truststore with CA
keytool -import -alias myca -file ca.crt \
  -keystore truststore.jks -storepass changeit -noprompt

# Client PKCS12 and keystore
openssl pkcs12 -export -in client.crt -inkey client.key \
  -out client.p12 -name clientcert -password pass:changeit

keytool -importkeystore \
  -srckeystore client.p12 -srcstoretype PKCS12 -srcstorepass changeit \
  -destkeystore client-keystore.jks -deststorepass changeit
```

### 3.5 — Verify All Files

```bash
ls -la /data/project/certs/
# Expected files:
#   ca.key  ca.crt  ca.srl
#   server.key  server.csr  server.crt  server.p12
#   client.key  client.csr  client.crt  client.p12
#   keystore.jks  truststore.jks  client-keystore.jks
#   san.cnf  client-san.cnf
```

---

## 4. Lab 1 — HTTP Route (No TLS)

The simplest route — no encryption anywhere. Uses a pre-built Golang image.

### 4.1 — Deployment

```bash
mkdir -p /data/project/ingress/http && cd /data/project/ingress/http
```

Create `golang-http.yaml`:

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: golang-http
  labels:
    app: golang-http
spec:
  replicas: 1
  selector:
    matchLabels:
      app: golang-http
  template:
    metadata:
      labels:
        app: golang-http
    spec:
      containers:
        - name: golang-http
          image: bashayralabdullah/golang-http:v1.0
          imagePullPolicy: Always
          ports:
            - containerPort: 8080
              protocol: TCP
          readinessProbe:
            tcpSocket:
              port: 8080
            initialDelaySeconds: 5
            periodSeconds: 10
            failureThreshold: 3
          livenessProbe:
            tcpSocket:
              port: 8080
            initialDelaySeconds: 10
            periodSeconds: 20
            failureThreshold: 3
---
apiVersion: v1
kind: Service
metadata:
  name: golang-http-svc
  labels:
    app: golang-http
spec:
  selector:
    app: golang-http
  ports:
    - protocol: TCP
      port: 8080
      targetPort: 8080
  type: ClusterIP
```

Create `golang-http-route.yaml`:

```yaml
apiVersion: route.openshift.io/v1
kind: Route
metadata:
  name: golang-http-route
  labels:
    app: golang-http
spec:
  host: golang-http.apps.sno.example.com
  to:
    kind: Service
    name: golang-http-svc
  port:
    targetPort: 8080
  tls: null
```

### 4.2 — Deploy & Test

```bash
oc apply -f golang-http.yaml
oc apply -f golang-http-route.yaml

# Test — HTTP only (no HTTPS)
curl http://golang-http.apps.sno.example.com
```

---

## 5. Lab 2 — Edge Route

TLS terminates at the OpenShift router. Traffic from router to pod is plain HTTP.

### 5.1 — Using Pre-built Golang Image

```bash
mkdir -p /data/project/ingress/edge && cd /data/project/ingress/edge
```

Create `golang-edge.yaml`:

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: golang-edge
  labels:
    app: golang-edge
spec:
  replicas: 1
  selector:
    matchLabels:
      app: golang-edge
  template:
    metadata:
      labels:
        app: golang-edge
    spec:
      containers:
        - name: golang-edge
          image: bashayralabdullah/golang-https-edge:v1.0
          imagePullPolicy: Always
          ports:
            - containerPort: 8443
              protocol: TCP
          readinessProbe:
            tcpSocket:
              port: 8443
            initialDelaySeconds: 5
            periodSeconds: 10
            failureThreshold: 3
          livenessProbe:
            tcpSocket:
              port: 8443
            initialDelaySeconds: 10
            periodSeconds: 20
            failureThreshold: 3
---
apiVersion: v1
kind: Service
metadata:
  name: golang-edge
  labels:
    app: golang-edge
spec:
  selector:
    app: golang-edge
  ports:
    - protocol: TCP
      port: 8443
      targetPort: 8443
  type: ClusterIP
```

### 5.2 — Generate Edge-specific Certs (Optional custom certs)

```bash
cd /data/project/certs

cat > openssl-edge.cnf <<EOF
[ req ]
default_bits       = 2048
prompt             = no
default_md         = sha256
req_extensions     = req_ext
distinguished_name = dn

[ dn ]
CN = golang-edge.apps.sno.example.com

[ req_ext ]
subjectAltName = @alt_names

[ alt_names ]
DNS.1 = golang-edge
DNS.2 = golang-edge.default.svc.cluster.local
DNS.3 = golang-edge.default.svc
DNS.4 = golang-edge.apps.sno.example.com
EOF

openssl genpkey -algorithm RSA -out edge-server.key
openssl req -new -key edge-server.key -out edge-server.csr -config openssl-edge.cnf
openssl x509 -req -in edge-server.csr -CA ca.crt -CAkey ca.key -CAcreateserial \
  -out edge-server.crt -days 3650 -extensions req_ext -extfile openssl-edge.cnf
```

### 5.3 — Create Edge Route & Deploy

```bash
oc apply -f golang-edge.yaml

# Create edge route with custom certs
oc create route edge golang-edge-route \
  --service=golang-edge \
  --cert=/data/project/certs/edge-server.crt \
  --key=/data/project/certs/edge-server.key \
  --ca-cert=/data/project/certs/ca.crt \
  --hostname=golang-edge.apps.sno.example.com
```

### 5.4 — Test

```bash
# Works — router terminates TLS
curl -k https://golang-edge.apps.sno.example.com

# With CA verification
curl --cacert /data/project/certs/ca.crt https://golang-edge.apps.sno.example.com
```

---

## 6. Lab 3 — Re-encrypt Route

TLS terminates at the router, then the router opens a NEW TLS connection to the pod. The pod must serve HTTPS.

### 6.1 — Flask App with TLS (app.py)

```bash
mkdir -p /data/project/ingress/reencrypt && cd /data/project/ingress/reencrypt
```

Create `app.py`:

```python
from flask import Flask, jsonify, request
import ssl

app = Flask(__name__)

@app.route('/')
def hello():
    return jsonify({"message": "Hello from Flask with re-encrypt TLS!"})

@app.route('/healthz')
def healthz():
    return "OK", 200

if __name__ == "__main__":
    context = ssl.create_default_context(ssl.Purpose.CLIENT_AUTH)
    context.load_cert_chain(certfile='/certs/server.crt', keyfile='/certs/server.key')
    context.load_verify_locations(cafile='/certs/ca.crt')
    context.verify_mode = ssl.CERT_OPTIONAL

    app.run(host='0.0.0.0', port=5000, ssl_context=context)
```

### 6.2 — Containerfile

Create `Containerfile`:

```dockerfile
FROM python:3.10-slim

RUN adduser --disabled-password --gecos '' appuser
WORKDIR /home/appuser

COPY app.py .
RUN chown -R appuser:appuser /home/appuser && chmod -R 755 /home/appuser
RUN pip install flask

USER appuser
EXPOSE 5000
CMD ["python", "app.py"]
```

### 6.3 — Generate Certs for Re-encrypt App

```bash
export NAMESPACE="default"
export APP="reencryptapp"

cat > certs-openssl.cnf <<EOF
[ req ]
default_bits       = 2048
prompt             = no
default_md         = sha256
req_extensions     = req_ext
distinguished_name = dn

[ dn ]
CN = ${APP}-service.${NAMESPACE}.svc.cluster.local

[ req_ext ]
subjectAltName = @alt_names

[ alt_names ]
DNS.1 = ${APP}-service
DNS.2 = ${APP}-service.${NAMESPACE}.svc.cluster.local
DNS.3 = ${APP}-service.${NAMESPACE}.svc
EOF

openssl genpkey -algorithm RSA -out reencrypt-server.key
openssl req -new -key reencrypt-server.key -out reencrypt-server.csr -config certs-openssl.cnf
openssl x509 -req -in reencrypt-server.csr \
  -CA /data/project/certs/ca.crt -CAkey /data/project/certs/ca.key -CAcreateserial \
  -out reencrypt-server.crt -days 3650 -extensions req_ext -extfile certs-openssl.cnf
```

### 6.4 — Build, Push, Create ConfigMap

```bash
podman build -t ${DOCKER_REPO}/reencryptapp:v1 .
podman push ${DOCKER_REPO}/reencryptapp:v1

# Create ConfigMap with certs
oc create configmap reencryptapp-certs \
  --from-file=server.crt=reencrypt-server.crt \
  --from-file=server.key=reencrypt-server.key \
  --from-file=ca.crt=/data/project/certs/ca.crt \
  --dry-run=client -o yaml | oc apply -f -
```

### 6.5 — Deployment YAML

Create `reencryptapp-deploy.yaml`:

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: reencryptapp
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
        image: docker.io/thomas6m/reencryptapp:v1
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
spec:
  selector:
    app: reencryptapp
  ports:
  - protocol: TCP
    port: 443
    targetPort: 5000
```

> **FIX from original:** Added HTTPS health checks since the pod now serves TLS.

### 6.6 — Create Re-encrypt Route

```bash
oc apply -f reencryptapp-deploy.yaml

# Create route with destinationCACertificate
oc create route reencrypt reencryptapp-route \
  --service=reencryptapp-service \
  --port=443 \
  --hostname=ingress-reencrypt.apps.sno.example.com \
  --dest-ca-cert=/data/project/certs/ca.crt
```

### 6.7 — Test

```bash
curl -k https://ingress-reencrypt.apps.sno.example.com
# Expected: {"message":"Hello from Flask with re-encrypt TLS!"}
```

---

## 7. Lab 4 — Passthrough Route

The router does NOT terminate TLS — it forwards the raw TLS connection to the pod. The pod MUST handle TLS itself.

### 7.1 — Java HTTPS App with Conditional mTLS

This Java app uses JKS keystores and supports optional client certificate verification.

```bash
mkdir -p /data/project/ingress/passthrough && cd /data/project/ingress/passthrough
```

Create the Maven project:

```bash
mvn archetype:generate \
  -DgroupId=com.example.https \
  -DartifactId=ingress-passthrough \
  -DarchetypeArtifactId=maven-archetype-quickstart \
  -DinteractiveMode=false

cd ingress-passthrough
rm src/test/java/com/example/https/AppTest.java
```

### 7.2 — App.java

Replace `src/main/java/com/example/https/App.java`:

```java
package com.example.https;

import com.sun.net.httpserver.*;
import javax.net.ssl.*;
import java.io.*;
import java.net.InetSocketAddress;
import java.security.KeyStore;
import java.security.cert.X509Certificate;

public class App {
    public static void main(String[] args) throws Exception {
        int httpsPort = 8443;

        String keystorePassword = System.getenv("KEYSTORE_PASSWORD");
        String keyPassword      = System.getenv("KEY_PASSWORD");
        String keystorePath     = System.getenv("KEYSTORE_PATH");
        String truststorePath   = System.getenv("TRUSTSTORE_PATH");

        if (keystorePassword == null || keyPassword == null
            || keystorePath == null || truststorePath == null) {
            throw new RuntimeException(
                "Required env vars: KEYSTORE_PASSWORD, KEY_PASSWORD, "
                + "KEYSTORE_PATH, TRUSTSTORE_PATH");
        }

        // Load Keystore (server identity)
        KeyStore ks = KeyStore.getInstance("JKS");
        try (FileInputStream fis = new FileInputStream(keystorePath)) {
            ks.load(fis, keystorePassword.toCharArray());
        }
        KeyManagerFactory kmf = KeyManagerFactory.getInstance("SunX509");
        kmf.init(ks, keyPassword.toCharArray());

        // Load Truststore (trusted client CAs)
        KeyStore ts = KeyStore.getInstance("JKS");
        try (FileInputStream fis = new FileInputStream(truststorePath)) {
            ts.load(fis, keystorePassword.toCharArray());
        }
        TrustManagerFactory tmf = TrustManagerFactory.getInstance("SunX509");
        tmf.init(ts);

        // Configure SSL context
        SSLContext sslContext = SSLContext.getInstance("TLS");
        sslContext.init(kmf.getKeyManagers(), tmf.getTrustManagers(), null);

        HttpsServer httpsServer = HttpsServer.create(
            new InetSocketAddress("0.0.0.0", httpsPort), 0);

        httpsServer.setHttpsConfigurator(new HttpsConfigurator(sslContext) {
            @Override
            public void configure(HttpsParameters params) {
                SSLParameters sslparams = getSSLContext().getDefaultSSLParameters();
                // wantClientAuth = request cert but don't require it
                // Use setNeedClientAuth(true) to enforce mTLS
                sslparams.setWantClientAuth(true);
                params.setSSLParameters(sslparams);
            }
        });

        // Health check endpoint — no client cert required
        httpsServer.createContext("/healthz", exchange -> {
            byte[] resp = "OK".getBytes("UTF-8");
            exchange.sendResponseHeaders(200, resp.length);
            try (OutputStream os = exchange.getResponseBody()) { os.write(resp); }
        });

        // Main endpoint — checks for client certificate
        httpsServer.createContext("/", exchange -> {
            SSLSession session = ((HttpsExchange) exchange).getSSLSession();
            try {
                X509Certificate[] certs =
                    (X509Certificate[]) session.getPeerCertificates();
                String cn = certs[0].getSubjectX500Principal().getName();
                byte[] resp = ("Hello from Passthrough with mTLS! Client: " + cn)
                    .getBytes("UTF-8");
                exchange.sendResponseHeaders(200, resp.length);
                try (OutputStream os = exchange.getResponseBody()) { os.write(resp); }
            } catch (SSLPeerUnverifiedException e) {
                byte[] resp = "Client certificate required".getBytes("UTF-8");
                exchange.sendResponseHeaders(403, resp.length);
                try (OutputStream os = exchange.getResponseBody()) { os.write(resp); }
            }
        });

        httpsServer.setExecutor(null);
        httpsServer.start();
        System.out.println("HTTPS Server with conditional mTLS started on port " + httpsPort);
    }
}
```

### 7.3 — pom.xml

Replace `pom.xml`:

```xml
<project xmlns="http://maven.apache.org/POM/4.0.0"
         xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance"
         xsi:schemaLocation="http://maven.apache.org/POM/4.0.0
                             http://maven.apache.org/xsd/maven-4.0.0.xsd">
  <modelVersion>4.0.0</modelVersion>
  <groupId>com.example</groupId>
  <artifactId>ingress-passthrough</artifactId>
  <version>1.0.0</version>
  <packaging>jar</packaging>
  <name>HTTPS Passthrough Server</name>

  <properties>
    <maven.compiler.source>17</maven.compiler.source>
    <maven.compiler.target>17</maven.compiler.target>
  </properties>

  <build>
    <plugins>
      <plugin>
        <groupId>org.apache.maven.plugins</groupId>
        <artifactId>maven-compiler-plugin</artifactId>
        <version>3.10.1</version>
      </plugin>
      <plugin>
        <groupId>org.apache.maven.plugins</groupId>
        <artifactId>maven-jar-plugin</artifactId>
        <version>3.3.0</version>
        <configuration>
          <archive>
            <manifest>
              <mainClass>com.example.https.App</mainClass>
            </manifest>
          </archive>
        </configuration>
      </plugin>
    </plugins>
  </build>
</project>
```

### 7.4 — Build JAR

```bash
mvn clean package
ls -la target/ingress-passthrough-1.0.0.jar
```

### 7.5 — Containerfile

```dockerfile
FROM registry.access.redhat.com/ubi9/openjdk-17

WORKDIR /app
COPY target/ingress-passthrough-1.0.0.jar ./ingress-passthrough.jar

VOLUME ["/etc/security"]
EXPOSE 8443

ENV KEYSTORE_PATH=/etc/security/keystore.jks \
    TRUSTSTORE_PATH=/etc/security/truststore.jks \
    KEYSTORE_PASSWORD=changeit \
    KEY_PASSWORD=changeit

ENTRYPOINT ["java", "-jar", "ingress-passthrough.jar"]
```

### 7.6 — Build & Push Image

```bash
podman build -f Containerfile -t ${DOCKER_REPO}/ingress-passthrough:v1 .
podman push ${DOCKER_REPO}/ingress-passthrough:v1
```

### 7.7 — Create ConfigMap & Deploy

```bash
cd /data/project/certs

oc create configmap ssl-config \
  --from-file=keystore.jks=keystore.jks \
  --from-file=truststore.jks=truststore.jks \
  --dry-run=client -o yaml | oc apply -f -
```

Create `passthrough-deploy.yaml`:

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: ingress-passthrough
spec:
  replicas: 1
  selector:
    matchLabels:
      app: ingress-passthrough
  template:
    metadata:
      labels:
        app: ingress-passthrough
    spec:
      containers:
        - name: ingress-passthrough
          image: docker.io/thomas6m/ingress-passthrough:v1
          ports:
            - containerPort: 8443
          env:
            - name: KEYSTORE_PASSWORD
              value: changeit
            - name: KEY_PASSWORD
              value: changeit
            - name: KEYSTORE_PATH
              value: /etc/security/keystore.jks
            - name: TRUSTSTORE_PATH
              value: /etc/security/truststore.jks
          volumeMounts:
            - name: ssl-volume
              mountPath: /etc/security
              readOnly: true
          readinessProbe:
            httpGet:
              path: /healthz
              port: 8443
              scheme: HTTPS
            initialDelaySeconds: 10
            periodSeconds: 5
            failureThreshold: 3
          livenessProbe:
            httpGet:
              path: /healthz
              port: 8443
              scheme: HTTPS
            initialDelaySeconds: 30
            periodSeconds: 10
            failureThreshold: 5
      volumes:
        - name: ssl-volume
          configMap:
            name: ssl-config
---
apiVersion: v1
kind: Service
metadata:
  name: ingress-passthrough
spec:
  selector:
    app: ingress-passthrough
  ports:
    - protocol: TCP
      name: https
      port: 443
      targetPort: 8443
```

### 7.8 — Create Passthrough Route & Deploy

```bash
oc apply -f passthrough-deploy.yaml

oc create route passthrough ingress-passthrough \
  --service=ingress-passthrough \
  --port=https \
  --hostname=ingress-passthrough.apps.sno.example.com
```

### 7.9 — Test

```bash
# Without client cert — returns 403
curl -k https://ingress-passthrough.apps.sno.example.com
# Expected: "Client certificate required"

# With client cert — returns 200
curl --cert /data/project/certs/client.crt \
     --key /data/project/certs/client.key \
     --cacert /data/project/certs/ca.crt \
     https://ingress-passthrough.apps.sno.example.com
# Expected: "Hello from Passthrough with mTLS! Client: CN=client,..."
```

---

## 8. Lab 5 — mTLS (App-to-App)

Two Flask apps where App1 calls App2 using mutual TLS. App2 uses an Nginx sidecar for proper TLS termination with client cert verification.

### Architecture

```
Client → (HTTPS via Passthrough Route) → App1 Flask (/proxy)
    → (HTTPS + mTLS with client cert) → App2 Nginx (port 5002, SSL termination)
        → (HTTP localhost) → App2 Flask (/data, port 5000)
```

### 8.1 — Generate mTLS Certificates

```bash
mkdir -p /data/apps/mtls/ssl && cd /data/apps/mtls/ssl

# CA
openssl genpkey -algorithm RSA -out ca.key
openssl req -x509 -new -key ca.key -out ca.crt -days 3650 -subj "/CN=mtls-ca"

# App1 Client Certificate (with SANs)
cat > app1-openssl.cnf <<EOF
[ req ]
default_bits       = 2048
prompt             = no
default_md         = sha256
req_extensions     = req_ext
distinguished_name = dn

[ dn ]
CN = app1-service

[ req_ext ]
subjectAltName = @alt_names

[ alt_names ]
DNS.1 = app1-service
DNS.2 = app1-service.mtls.svc
DNS.3 = app1-service.mtls.svc.cluster.local
DNS.4 = app1-route-mtls.apps.sno.example.com
EOF

openssl genpkey -algorithm RSA -out app1.key
openssl req -new -key app1.key -out app1.csr -config app1-openssl.cnf
openssl x509 -req -in app1.csr -CA ca.crt -CAkey ca.key -CAcreateserial \
  -out app1.crt -days 3650 -extensions req_ext -extfile app1-openssl.cnf

# App2 Server Certificate (with SANs)
cat > app2-openssl.cnf <<EOF
[ req ]
default_bits       = 2048
prompt             = no
default_md         = sha256
req_extensions     = req_ext
distinguished_name = dn

[ dn ]
CN = app2-service

[ req_ext ]
subjectAltName = @alt_names

[ alt_names ]
DNS.1 = app2-service
DNS.2 = app2-service.mtls.svc
DNS.3 = app2-service.mtls.svc.cluster.local
EOF

openssl genpkey -algorithm RSA -out app2.key
openssl req -new -key app2.key -out app2.csr -config app2-openssl.cnf
openssl x509 -req -in app2.csr -CA ca.crt -CAkey ca.key -CAcreateserial \
  -out app2.crt -days 3650 -extensions req_ext -extfile app2-openssl.cnf
```

> **FIX from original:** App1 cert now includes SANs (was missing in older runbook).

### 8.2 — Create Namespace & ConfigMaps

```bash
oc new-project mtls

cd /data/apps/mtls/ssl

oc create configmap app1-client-cert-configmap \
  --from-file=app1.crt --from-file=app1.key --from-file=ca.crt \
  --dry-run=client -o yaml | oc apply -f -

oc create configmap app2-cert-configmap \
  --from-file=app2.crt --from-file=app2.key --from-file=ca.crt \
  --dry-run=client -o yaml | oc apply -f -
```

### 8.3 — App1 (Flask Proxy)

Create `/data/apps/mtls/app1/app.py`:

```python
import requests
from flask import Flask, jsonify

app = Flask(__name__)

@app.route('/proxy', methods=['GET'])
def proxy():
    try:
        response = requests.get(
            'https://app2-service:5002/data',
            cert=('/certs/app1.crt', '/certs/app1.key'),
            verify='/certs/ca.crt'
        )
        return jsonify({"app2_response": response.json()}), 200
    except Exception as e:
        return jsonify({"error": str(e)}), 500

@app.route('/healthz', methods=['GET'])
def healthz():
    return "OK", 200

if __name__ == '__main__':
    app.run(
        host='0.0.0.0',
        port=5001,
        ssl_context=('/certs/app1.crt', '/certs/app1.key')
    )
```

> **FIX from original:** Added /healthz endpoint for probes.

Create `/data/apps/mtls/app1/Containerfile`:

```dockerfile
FROM python:3.10-slim

RUN adduser --disabled-password --gecos '' appuser
WORKDIR /home/appuser

COPY app.py /home/appuser/
RUN chown -R appuser:appuser /home/appuser && chmod -R 755 /home/appuser
RUN pip install flask requests

USER appuser
EXPOSE 5001
CMD ["python", "app.py"]
```

Build & push:

```bash
cd /data/apps/mtls/app1
podman build -f Containerfile -t ${DOCKER_REPO}/mtls-app1:v1 .
podman push ${DOCKER_REPO}/mtls-app1:v1
```

### 8.4 — App2 (Flask Backend)

Create `/data/apps/mtls/app2/app.py`:

```python
from flask import Flask

app = Flask(__name__)

@app.route('/data', methods=['GET'])
def data():
    return {"message": "Response from App2 over mTLS"}, 200

@app.route('/healthz', methods=['GET'])
def healthz():
    return "OK", 200

if __name__ == '__main__':
    # Flask runs plain HTTP — Nginx sidecar handles TLS
    app.run(host='0.0.0.0', port=5000)
```

Create `/data/apps/mtls/app2/Containerfile`:

```dockerfile
FROM python:3.10-slim

RUN adduser --disabled-password --gecos '' appuser
WORKDIR /home/appuser

COPY app.py /home/appuser/
RUN chown -R appuser:appuser /home/appuser && chmod -R 755 /home/appuser
RUN pip install flask

USER appuser
EXPOSE 5000
CMD ["python", "app.py"]
```

Build & push:

```bash
cd /data/apps/mtls/app2
podman build -f Containerfile -t ${DOCKER_REPO}/mtls-app2:v1 .
podman push ${DOCKER_REPO}/mtls-app2:v1
```

### 8.5 — App2 Nginx Config (mTLS Enforcement)

Create `app2-nginx-config.yaml`:

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: app2-nginx-config
data:
  nginx.conf: |
    worker_processes 1;
    pid /tmp/nginx.pid;

    events {
        worker_connections 1024;
    }

    http {
        server {
            listen 5002 ssl;

            ssl_certificate     /certs/app2.crt;
            ssl_certificate_key /certs/app2.key;

            # --- mTLS: Require client certificate ---
            ssl_verify_client on;
            ssl_client_certificate /certs/ca.crt;

            ssl_protocols       TLSv1.2 TLSv1.3;
            ssl_ciphers         HIGH:!aNULL:!MD5;

            location / {
                proxy_pass http://127.0.0.1:5000;
                proxy_set_header Host $host;
                proxy_set_header X-Real-IP $remote_addr;
                proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
                proxy_set_header X-Forwarded-Proto $scheme;
                # Pass client cert DN to Flask
                proxy_set_header X-Client-DN $ssl_client_s_dn;
            }
        }
    }
```

> **CRITICAL FIX from original:** Added `ssl_verify_client on;` and `ssl_client_certificate` — without these, Nginx does NOT enforce mTLS.

### 8.6 — App2 Deployment (Flask + Nginx Sidecar)

Create `app2-deployment.yaml`:

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: app2
spec:
  replicas: 1
  selector:
    matchLabels:
      app: app2
  template:
    metadata:
      labels:
        app: app2
    spec:
      containers:
      - name: app2-flask
        image: docker.io/thomas6m/mtls-app2:v1
        ports:
        - containerPort: 5000
        volumeMounts:
        - name: ssl-certs
          mountPath: /certs
          readOnly: true
      - name: app2-nginx
        image: nginx:stable-alpine
        ports:
        - containerPort: 5002
        volumeMounts:
        - name: ssl-certs
          mountPath: /certs
          readOnly: true
        - name: nginx-config
          mountPath: /etc/nginx/nginx.conf
          subPath: nginx.conf
          readOnly: true
        - name: nginx-cache
          mountPath: /var/cache/nginx
        readinessProbe:
          tcpSocket:
            port: 5002
          initialDelaySeconds: 5
          periodSeconds: 10
        livenessProbe:
          tcpSocket:
            port: 5002
          initialDelaySeconds: 10
          periodSeconds: 20
      volumes:
      - name: ssl-certs
        configMap:
          name: app2-cert-configmap
      - name: nginx-config
        configMap:
          name: app2-nginx-config
      - name: nginx-cache
        emptyDir: {}
---
apiVersion: v1
kind: Service
metadata:
  name: app2-service
spec:
  selector:
    app: app2
  ports:
  - protocol: TCP
    port: 5002
    targetPort: 5002
```

### 8.7 — App1 Deployment & Route

Create `app1-deployment.yaml`:

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: app1
spec:
  replicas: 1
  selector:
    matchLabels:
      app: app1
  template:
    metadata:
      labels:
        app: app1
    spec:
      containers:
      - name: app1
        image: docker.io/thomas6m/mtls-app1:v1
        ports:
        - containerPort: 5001
        volumeMounts:
        - name: ssl-certs
          mountPath: /certs
          readOnly: true
        readinessProbe:
          tcpSocket:
            port: 5001
          initialDelaySeconds: 5
          periodSeconds: 10
        livenessProbe:
          tcpSocket:
            port: 5001
          initialDelaySeconds: 10
          periodSeconds: 20
      volumes:
      - name: ssl-certs
        configMap:
          name: app1-client-cert-configmap
---
apiVersion: v1
kind: Service
metadata:
  name: app1-service
spec:
  selector:
    app: app1
  ports:
  - protocol: TCP
    port: 5001
    targetPort: 5001
  type: ClusterIP
```

Create `app1-route.yaml`:

```yaml
apiVersion: route.openshift.io/v1
kind: Route
metadata:
  name: app1-route
spec:
  to:
    kind: Service
    name: app1-service
  port:
    targetPort: 5001
  tls:
    termination: passthrough
```

### 8.8 — Deploy Everything

```bash
# App2 (must be running first)
oc apply -f app2-nginx-config.yaml
oc apply -f app2-deployment.yaml

# App1
oc apply -f app1-deployment.yaml
oc apply -f app1-route.yaml

# Wait for pods
oc get pods -w
```

### 8.9 — Test mTLS

```bash
# Test App1 → App2 via the proxy endpoint
curl -k https://app1-route-mtls.apps.sno.example.com/proxy
# Expected: {"app2_response": {"message": "Response from App2 over mTLS"}}

# With CA verification
curl --cacert /data/apps/mtls/ssl/ca.crt \
     --cert /data/apps/mtls/ssl/app1.crt \
     --key /data/apps/mtls/ssl/app1.key \
     https://app1-route-mtls.apps.sno.example.com/proxy

# Without client cert (should fail with 400 from Nginx)
curl -k https://app2-service:5002/data
# Expected: 400 Bad Request - No required SSL certificate was sent
```

---

## 9. Automation Script (All-in-One)

Deploys edge, re-encrypt, and passthrough apps in a single namespace. See `scripts/deploy-all.sh` in the zip archive.

> **CRITICAL FIX:** The original automation script used a plain HTTP Flask app for all 3 route types. The passthrough route requires TLS at the pod. The corrected script uses separate app images:
> - Edge & HTTP: plain Flask (no TLS)
> - Re-encrypt: Flask with `ssl_context`
> - Passthrough: Flask with `ssl_context`

---

## 10. Troubleshooting

### Common Issues

| Symptom | Cause | Fix |
|---|---|---|
| `curl: (35) SSL connect error` on passthrough | Pod not serving TLS | Ensure app uses ssl_context or keystore |
| `400 No required SSL certificate` | Nginx requires client cert | Provide `--cert` and `--key` in curl |
| `503 Service Unavailable` | Pod not ready | Check `oc get pods`, readiness probes |
| `certificate verify failed` | SAN mismatch | Regenerate cert with correct DNS names in SAN |
| Route shows `host not found` | DNS not configured | Ensure `*.apps.sno.example.com` resolves |
| Re-encrypt route `503` | destinationCACertificate wrong | Route must trust the pod's CA cert |

### Debug Commands

```bash
# Check pod logs
oc logs <pod-name> -c <container-name>

# Check route config
oc get route <route-name> -o yaml

# Test from inside cluster
oc run debug --image=curlimages/curl --rm -it -- sh
curl -k https://app2-service.mtls.svc:5002/data

# Verify certificate chain
openssl s_client -connect <service>:<port> -CAfile ca.crt

# Check cert SANs
openssl x509 -in server.crt -text -noout | grep -A 2 "Subject Alternative Name"

# Check Nginx config inside pod
oc exec <pod> -c app2-nginx -- cat /etc/nginx/nginx.conf
oc exec <pod> -c app2-nginx -- nginx -t
```

---

## 11. Quick Reference Cheat Sheet

### Route Creation CLI Commands

```bash
# HTTP (no TLS)
oc expose svc/my-svc --hostname=my-app.apps.sno.example.com

# Edge
oc create route edge --service=frontend \
  --cert=tls.crt --key=tls.key --ca-cert=ca.crt \
  --hostname=www.example.com

# Re-encrypt
oc create route reencrypt --service=frontend \
  --cert=tls.crt --key=tls.key --ca-cert=ca.crt \
  --dest-ca-cert=destca.crt \
  --hostname=www.example.com

# Passthrough
oc create route passthrough --service=frontend \
  --port=8443 \
  --hostname=www.example.com
```

### Certificate Quick Reference

| File | Purpose | Used By |
|---|---|---|
| `ca.key` / `ca.crt` | Certificate Authority | Signs all other certs |
| `server.key` / `server.crt` | Server identity | Pod TLS (re-encrypt, passthrough) |
| `client.key` / `client.crt` | Client identity | mTLS client authentication |
| `keystore.jks` | Java keystore (server cert) | Java passthrough app |
| `truststore.jks` | Java truststore (CA cert) | Java passthrough app — validates clients |

### Key Differences Summary

| Aspect | Edge | Re-encrypt | Passthrough |
|---|---|---|---|
| Router terminates TLS | Yes | Yes | No |
| Pod needs TLS | No | Yes | Yes |
| Custom certs on route | Optional | Optional + destCA | Not applicable |
| mTLS possible | No | No | Yes |
| Pod sees client cert | No | No | Yes |
