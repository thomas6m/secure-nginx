# OpenShift HPA Load Testing with Podman

Complete setup for testing CPU and Memory-based HPA scaling in OpenShift using Podman on a standalone Linux VM.

## Prerequisites

- Linux VM with Podman installed
- Access to OpenShift cluster
- Container registry access (Docker Hub, Quay.io, etc.)

## Quick Setup

### 1. Install Required Tools

```bash
# Install Podman (RHEL/CentOS/Fedora)
sudo dnf install podman -y

# Install Podman (Ubuntu/Debian)
sudo apt update && sudo apt install podman -y

# Install OpenShift CLI
curl -LO https://mirror.openshift.com/pub/openshift-v4/clients/ocp/stable/openshift-client-linux.tar.gz
tar -xzf openshift-client-linux.tar.gz
sudo mv oc /usr/local/bin/
```

### 2. Create Project Structure

```bash
mkdir ~/hpa-testing && cd ~/hpa-testing
```

### 3. Create Application Files

**CPU Load App:**
```bash
mkdir cpu-app
cat > cpu-app/app.py << 'EOF'
from flask import Flask
import threading
import time

app = Flask(__name__)
cpu_load_active = False

def cpu_task():
    global cpu_load_active
    while cpu_load_active:
        sum([i*i for i in range(10000)])

@app.route('/')
def home():
    return f'''
    <h1>CPU Load Generator</h1>
    <p>Status: {"Active" if cpu_load_active else "Stopped"}</p>
    <a href="/start">Start Load</a> | <a href="/stop">Stop Load</a>
    '''

@app.route('/start')
def start():
    global cpu_load_active
    if not cpu_load_active:
        cpu_load_active = True
        for _ in range(4):  # 4 threads for CPU load
            threading.Thread(target=cpu_task, daemon=True).start()
    return "CPU load started"

@app.route('/stop')
def stop():
    global cpu_load_active
    cpu_load_active = False
    return "CPU load stopped"

if __name__ == '__main__':
    app.run(host='0.0.0.0', port=8080)
EOF

cat > cpu-app/Dockerfile << 'EOF'
FROM python:3.9-slim
WORKDIR /app
RUN pip install flask
COPY app.py .
EXPOSE 8080
CMD ["python", "app.py"]
EOF
```

**Memory Load App:**
```bash
mkdir memory-app
cat > memory-app/app.py << 'EOF'
from flask import Flask
import gc

app = Flask(__name__)
memory_blocks = []

@app.route('/')
def home():
    memory_mb = len(memory_blocks) * 10
    return f'''
    <h1>Memory Load Generator</h1>
    <p>Allocated: {memory_mb}MB</p>
    <a href="/add/50">Add 50MB</a> | 
    <a href="/add/100">Add 100MB</a> | 
    <a href="/clear">Clear All</a>
    '''

@app.route('/add/<int:mb>')
def add_memory(mb):
    for _ in range(mb // 10):
        memory_blocks.append(bytearray(10 * 1024 * 1024))  # 10MB blocks
    return f"Added {mb}MB. Total: {len(memory_blocks) * 10}MB"

@app.route('/clear')
def clear():
    global memory_blocks
    memory_blocks.clear()
    gc.collect()
    return "Memory cleared"

if __name__ == '__main__':
    app.run(host='0.0.0.0', port=8080)
EOF

cat > memory-app/Dockerfile << 'EOF'
FROM python:3.9-slim
WORKDIR /app
RUN pip install flask
COPY app.py .
EXPOSE 8080
CMD ["python", "app.py"]
EOF
```

### 4. Build and Push Images

```bash
# Set your Docker Hub registry
REGISTRY="docker.io/test1234"

# Login to Docker Hub
podman login docker.io
# Enter your Docker Hub username: test1234
# Enter your Docker Hub password: [your-password]

# Build and push CPU app
cd cpu-app
podman build -t $REGISTRY/cpu-load-app:latest .
podman push $REGISTRY/cpu-load-app:latest

# Build and push Memory app
cd ../memory-app
podman build -t $REGISTRY/memory-load-app:latest .
podman push $REGISTRY/memory-load-app:latest

cd ..
```

### 5. Create Deployment Files

```bash
# Update REGISTRY variable with Docker Hub
REGISTRY="docker.io/test1234"

# CPU Load Deployment
cat > cpu-deployment.yaml << EOF
apiVersion: apps/v1
kind: Deployment
metadata:
  name: cpu-load-app
spec:
  replicas: 1
  selector:
    matchLabels:
      app: cpu-load-app
  template:
    metadata:
      labels:
        app: cpu-load-app
    spec:
      containers:
      - name: cpu-load-app
        image: $REGISTRY/cpu-load-app:latest
        ports:
        - containerPort: 8080
        resources:
          requests:
            cpu: 100m
            memory: 128Mi
          limits:
            cpu: 500m
            memory: 256Mi
---
apiVersion: v1
kind: Service
metadata:
  name: cpu-load-service
spec:
  selector:
    app: cpu-load-app
  ports:
  - port: 80
    targetPort: 8080
---
apiVersion: route.openshift.io/v1
kind: Route
metadata:
  name: cpu-load-route
spec:
  to:
    kind: Service
    name: cpu-load-service
EOF

# Memory Load Deployment
cat > memory-deployment.yaml << EOF
apiVersion: apps/v1
kind: Deployment
metadata:
  name: memory-load-app
spec:
  replicas: 1
  selector:
    matchLabels:
      app: memory-load-app
  template:
    metadata:
      labels:
        app: memory-load-app
    spec:
      containers:
      - name: memory-load-app
        image: $REGISTRY/memory-load-app:latest
        ports:
        - containerPort: 8080
        resources:
          requests:
            cpu: 100m
            memory: 128Mi
          limits:
            cpu: 200m
            memory: 512Mi
---
apiVersion: v1
kind: Service
metadata:
  name: memory-load-service
spec:
  selector:
    app: memory-load-app
  ports:
  - port: 80
    targetPort: 8080
---
apiVersion: route.openshift.io/v1
kind: Route
metadata:
  name: memory-load-route
spec:
  to:
    kind: Service
    name: memory-load-service
EOF

# CPU HPA
cat > cpu-hpa.yaml << 'EOF'
apiVersion: autoscaling/v2
kind: HorizontalPodAutoscaler
metadata:
  name: cpu-hpa
spec:
  scaleTargetRef:
    apiVersion: apps/v1
    kind: Deployment
    name: cpu-load-app
  minReplicas: 1
  maxReplicas: 5
  metrics:
  - type: Resource
    resource:
      name: cpu
      target:
        type: Utilization
        averageUtilization: 50
  behavior:
    scaleUp:
      stabilizationWindowSeconds: 30
      policies:
      - type: Percent
        value: 100
        periodSeconds: 15
    scaleDown:
      stabilizationWindowSeconds: 60  # Reduced from 300s to 60s
      policies:
      - type: Percent
        value: 50  # Allow 50% scale down
        periodSeconds: 30  # Check every 30s
      - type: Pods
        value: 2  # Or scale down by max 2 pods
        periodSeconds: 30
EOF

# Memory HPA
cat > memory-hpa.yaml << 'EOF'
apiVersion: autoscaling/v2
kind: HorizontalPodAutoscaler
metadata:
  name: memory-hpa
spec:
  scaleTargetRef:
    apiVersion: apps/v1
    kind: Deployment
    name: memory-load-app
  minReplicas: 1
  maxReplicas: 5
  metrics:
  - type: Resource
    resource:
      name: memory
      target:
        type: Utilization
        averageUtilization: 70
EOF
```

### 6. Deploy to OpenShift

```bash
# Login to OpenShift
oc login https://your-openshift-cluster:6443

# Create project
oc new-project hpa-testing

# Deploy applications
oc apply -f cpu-deployment.yaml
oc apply -f memory-deployment.yaml
oc apply -f cpu-hpa.yaml
oc apply -f memory-hpa.yaml

# Wait for deployments
oc wait --for=condition=available deployment/cpu-load-app --timeout=300s
oc wait --for=condition=available deployment/memory-load-app --timeout=300s
```

### 7. Get Application URLs

```bash
echo "CPU Load App: http://$(oc get route cpu-load-route -o jsonpath='{.spec.host}')"
echo "Memory Load App: http://$(oc get route memory-load-route -o jsonpath='{.spec.host}')"
```

## Testing HPA Scaling

### CPU Testing
1. Open CPU app URL in browser
2. Click "Start Load" to generate CPU usage
3. Monitor scaling: `oc get hpa cpu-hpa -w`
4. Watch pods scale up: `oc get pods -l app=cpu-load-app -w`
5. Click "Stop Load" and observe scale down

### Memory Testing
1. Open Memory app URL in browser
2. Click "Add 100MB" repeatedly to increase memory usage
3. Monitor scaling: `oc get hpa memory-hpa -w`
4. Watch pods scale up: `oc get pods -l app=memory-load-app -w`
5. Click "Clear All" and observe scale down

## Monitoring Commands

```bash
# Watch HPA status
oc get hpa -w

# Check resource usage
oc top pods

# View HPA details
oc describe hpa cpu-hpa
oc describe hpa memory-hpa

# Check events
oc get events --sort-by=.metadata.creationTimestamp
```

## Automation Script

For complete automation:

```bash
cat > deploy.sh << 'EOF'
#!/bin/bash
set -e

REGISTRY=${1:-"docker.io/test1234"}
PROJECT=${2:-"hpa-testing"}

echo "Building and deploying HPA test apps..."
echo "Registry: $REGISTRY"
echo "Project: $PROJECT"

# Login to Docker Hub
podman login docker.io

# Build and push images
cd cpu-app && podman build -t $REGISTRY/cpu-load-app:latest . && podman push $REGISTRY/cpu-load-app:latest
cd ../memory-app && podman build -t $REGISTRY/memory-load-app:latest . && podman push $REGISTRY/memory-load-app:latest
cd ..

# Update deployment files
sed -i "s|docker.io/test1234|$REGISTRY|g" *-deployment.yaml

# Deploy to OpenShift
oc new-project $PROJECT 2>/dev/null || oc project $PROJECT
oc apply -f cpu-deployment.yaml -f memory-deployment.yaml -f cpu-hpa.yaml -f memory-hpa.yaml

# Wait and show URLs
oc wait --for=condition=available deployment/cpu-load-app deployment/memory-load-app --timeout=300s

echo "Deployment complete!"
echo "CPU App: http://$(oc get route cpu-load-route -o jsonpath='{.spec.host}')"
echo "Memory App: http://$(oc get route memory-load-route -o jsonpath='{.spec.host}')"
EOF

chmod +x deploy.sh

# Usage:
# ./deploy.sh docker.io/test1234 my-project
# or simply: ./deploy.sh
```

## Troubleshooting HPA Scale Down Issues

If replicas don't scale down after stopping CPU load, try these steps:

### 1. Check Current HPA Status
```bash
# Check HPA metrics and status
oc describe hpa cpu-hpa

# Check current CPU usage
oc top pods -l app=cpu-load-app

# Watch HPA in real-time
oc get hpa cpu-hpa -w
```

### 2. Common Issues and Solutions

**Issue: Long stabilization window (default 300s)**
```bash
# Update HPA with shorter scale-down window
oc patch hpa cpu-hpa --type='merge' -p='{"spec":{"behavior":{"scaleDown":{"stabilizationWindowSeconds":60}}}}'
```

**Issue: CPU metrics not updating**
```bash
# Restart metrics-server if needed (cluster admin required)
oc get pods -n openshift-monitoring | grep metrics

# Or wait 1-2 minutes for metrics to refresh
```

**Issue: Threads not properly stopping**
```bash
# Enhanced CPU app with better thread cleanup
cat > cpu-app/app.py << 'EOF'
from flask import Flask
import threading
import time
import os
import signal

app = Flask(__name__)
cpu_load_active = False
threads = []

def cpu_task():
    global cpu_load_active
    while cpu_load_active:
        # Lighter CPU load for better control
        sum([i*i for i in range(5000)])
        time.sleep(0.001)  # Small pause to allow thread checking

@app.route('/')
def home():
    return f'''
    <h1>CPU Load Generator</h1>
    <p>Status: {"Active" if cpu_load_active else "Stopped"}</p>
    <p>Active threads: {sum(1 for t in threads if t.is_alive())}</p>
    <a href="/start">Start Load</a> | <a href="/stop">Stop Load</a>
    '''

@app.route('/start')
def start():
    global cpu_load_active, threads
    if not cpu_load_active:
        cpu_load_active = True
        threads.clear()
        for i in range(2):  # Reduced from 4 to 2 threads
            t = threading.Thread(target=cpu_task, daemon=True, name=f"cpu-worker-{i}")
            t.start()
            threads.append(t)
    return f"CPU load started with {len([t for t in threads if t.is_alive()])} threads"

@app.route('/stop')
def stop():
    global cpu_load_active
    cpu_load_active = False
    
    # Wait for threads to finish
    for t in threads:
        if t.is_alive():
            t.join(timeout=1.0)
    
    return f"CPU load stopped. Remaining active threads: {sum(1 for t in threads if t.is_alive())}"

@app.route('/force-stop')
def force_stop():
    global cpu_load_active, threads
    cpu_load_active = False
    threads.clear()
    return "Forced stop - all references cleared"

if __name__ == '__main__':
    app.run(host='0.0.0.0', port=8080)
EOF

# Rebuild and redeploy
cd cpu-app
podman build -t docker.io/test1234/cpu-load-app:latest .
podman push docker.io/test1234/cpu-load-app:latest
cd ..

# Restart deployment to get new image
oc rollout restart deployment/cpu-load-app
```

### 3. Manual Scale Down Test
```bash
# Manually scale down to test
oc scale deployment cpu-load-app --replicas=1

# Check if it stays at 1 (should scale back up if CPU is still high)
oc get pods -l app=cpu-load-app -w
```

### 4. Force HPA Refresh
```bash
# Delete and recreate HPA to reset metrics
oc delete hpa cpu-hpa
oc apply -f cpu-hpa.yaml

# Or restart the HPA controller (cluster admin required)
oc delete pod -n openshift-kube-controller-manager -l app=kube-controller-manager
```

### 5. Check Metrics Server
```bash
# Verify metrics are working
oc top nodes
oc top pods -n hpa-testing

# If no metrics, check metrics server
oc get pods -n openshift-monitoring | grep metrics
```

### 6. Alternative: Faster Scale Down HPA
```bash
cat > cpu-hpa-fast.yaml << 'EOF'
apiVersion: autoscaling/v2
kind: HorizontalPodAutoscaler
metadata:
  name: cpu-hpa
spec:
  scaleTargetRef:
    apiVersion: apps/v1
    kind: Deployment
    name: cpu-load-app
  minReplicas: 1
  maxReplicas: 5
  metrics:
  - type: Resource
    resource:
      name: cpu
      target:
        type: Utilization
        averageUtilization: 30  # Lower threshold
  behavior:
    scaleUp:
      stabilizationWindowSeconds: 15
      policies:
      - type: Percent
        value: 100
        periodSeconds: 15
    scaleDown:
      stabilizationWindowSeconds: 30  # Very short window
      policies:
      - type: Percent
        value: 100  # Allow immediate scale down
        periodSeconds: 15
EOF

# Apply faster scaling HPA
oc apply -f cpu-hpa-fast.yaml
```