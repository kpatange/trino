#!/bin/bash
set -e

# Create root directory
ROOT_DIR="trino-k8s-argocd"
mkdir -p "$ROOT_DIR"
cd "$ROOT_DIR"

# Create base directory structure
mkdir -p {base,overlays/{production,development},scripts}

# Create base kustomization
cat > base/kustomization.yaml <<EOF
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
- minio/deployment.yaml
- minio/service.yaml
- minio/pvc.yaml
- nessie/deployment.yaml
- nessie/service.yaml
- trino/configmap-jvm.yaml
- trino/configmap-main.yaml
- trino/configmap-catalog.yaml
- trino/deployment.yaml
- trino/service.yaml
EOF

# Create MinIO components
mkdir -p base/minio

# MinIO Deployment
cat > base/minio/deployment.yaml <<EOF
apiVersion: apps/v1
kind: Deployment
metadata:
  name: minio
spec:
  replicas: 1
  selector:
    matchLabels:
      app: minio
  template:
    metadata:
      labels:
        app: minio
    spec:
      containers:
      - name: minio
        image: minio/minio:latest
        args:
        - server
        - /data
        - --console-address
        - ":9001"
        env:
        - name: MINIO_ROOT_USER
          value: minioadmin
        - name: MINIO_ROOT_PASSWORD
          value: minioadmin
        ports:
        - containerPort: 9000
        - containerPort: 9001
        volumeMounts:
        - name: minio-data
          mountPath: /data
        readinessProbe:
          httpGet:
            path: /minio/health/ready
            port: 9000
          initialDelaySeconds: 5
          periodSeconds: 10
      volumes:
      - name: minio-data
        persistentVolumeClaim:
          claimName: minio-pvc
EOF

# MinIO Service
cat > base/minio/service.yaml <<EOF
apiVersion: v1
kind: Service
metadata:
  name: minio
spec:
  selector:
    app: minio
  ports:
    - name: api
      port: 9000
      targetPort: 9000
    - name: console
      port: 9001
      targetPort: 9001
EOF

# MinIO PVC
cat > base/minio/pvc.yaml <<EOF
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: minio-pvc
spec:
  accessModes:
    - ReadWriteOnce
  resources:
    requests:
      storage: 10Gi
EOF

# Create Nessie components
mkdir -p base/nessie

# Nessie Deployment
cat > base/nessie/deployment.yaml <<EOF
apiVersion: apps/v1
kind: Deployment
metadata:
  name: nessie
spec:
  replicas: 1
  selector:
    matchLabels:
      app: nessie
  template:
    metadata:
      labels:
        app: nessie
    spec:
      containers:
      - name: nessie
        image: projectnessie/nessie:latest
        ports:
        - containerPort: 19120
        env:
        - name: NESSIE_VERSION_STORE_TYPE
          value: IN_MEMORY
        readinessProbe:
          httpGet:
            path: /api/v1/config
            port: 19120
          initialDelaySeconds: 5
          periodSeconds: 10
EOF

# Nessie Service
cat > base/nessie/service.yaml <<EOF
apiVersion: v1
kind: Service
metadata:
  name: nessie
spec:
  selector:
    app: nessie
  ports:
    - port: 19120
      targetPort: 19120
EOF

# Create Trino components
mkdir -p base/trino

# Trino JVM ConfigMap
cat > base/trino/configmap-jvm.yaml <<EOF
apiVersion: v1
kind: ConfigMap
metadata:
  name: trino-jvm-config
data:
  jvm.config: |
    -server
    -Xmx2G
    -XX:+UseG1GC
    -XX:G1HeapRegionSize=32M
    -XX:+ExplicitGCInvokesConcurrent
    -XX:+ExitOnOutOfMemoryError
    -XX:+HeapDumpOnOutOfMemoryError
    -XX:-OmitStackTraceInFastThrow
    -XX:ReservedCodeCacheSize=512M
    -XX:PerMethodRecompilationCutoff=10000
    -XX:PerBytecodeRecompilationCutoff=10000
    -Djdk.attach.allowAttachSelf=true
    -Djdk.nio.maxCachedBufferSize=2000000
    -XX:+UnlockDiagnosticVMOptions
    -XX:+UseAESCTRIntrinsics
EOF

# Trino Main ConfigMap
cat > base/trino/configmap-main.yaml <<EOF
apiVersion: v1
kind: ConfigMap
metadata:
  name: trino-config
data:
  config.properties: |
    coordinator=true
    node-scheduler.include-coordinator=true
    http-server.http.port=8080
    query.max-memory=1GB
    query.max-memory-per-node=512MB
    discovery.uri=http://localhost:8080
    
  node.properties: |
    node.environment=demo
    node.id=trino-demo
    node.data-dir=/data/trino
    
  log.properties: |
    io.trino=INFO
EOF

# Trino Catalog ConfigMap
cat > base/trino/configmap-catalog.yaml <<EOF
apiVersion: v1
kind: ConfigMap
metadata:
  name: trino-catalog-config
data:
  iceberg.properties: |
    connector.name=iceberg
    iceberg.catalog.type=nessie
    iceberg.nessie-catalog.uri=http://nessie:19120/api/v1
    iceberg.nessie-catalog.default-warehouse-dir=s3://warehouse/
    fs.hadoop.enabled=false
    fs.native-s3.enabled=true
    s3.endpoint=http://minio:9000
    s3.aws-access-key=minioadmin
    s3.aws-secret-key=minioadmin
    s3.path-style-access=true
    s3.region=us-east-1
EOF

# Trino Deployment
cat > base/trino/deployment.yaml <<EOF
apiVersion: apps/v1
kind: Deployment
metadata:
  name: trino
spec:
  replicas: 1
  selector:
    matchLabels:
      app: trino
  template:
    metadata:
      labels:
        app: trino
    spec:
      containers:
      - name: trino
        image: trinodb/trino:latest
        ports:
        - containerPort: 8080
        volumeMounts:
        - name: trino-config
          mountPath: /etc/trino/config.properties
          subPath: config.properties
        - name: trino-config
          mountPath: /etc/trino/node.properties
          subPath: node.properties
        - name: trino-config
          mountPath: /etc/trino/log.properties
          subPath: log.properties
        - name: trino-jvm
          mountPath: /etc/trino/jvm.config
          subPath: jvm.config
        - name: trino-catalog
          mountPath: /etc/trino/catalog/iceberg.properties
          subPath: iceberg.properties
        readinessProbe:
          exec:
            command: ["/usr/lib/trino/bin/health-check"]
          initialDelaySeconds: 60
          periodSeconds: 30
      volumes:
      - name: trino-config
        configMap:
          name: trino-config
      - name: trino-jvm
        configMap:
          name: trino-jvm-config
      - name: trino-catalog
        configMap:
          name: trino-catalog-config
EOF

# Trino Service
cat > base/trino/service.yaml <<EOF
apiVersion: v1
kind: Service
metadata:
  name: trino
spec:
  selector:
    app: trino
  ports:
    - port: 8080
      targetPort: 8080
EOF

# Create overlays
# Production
cat > overlays/production/kustomization.yaml <<EOF
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
bases:
- ../../base
namespace: trino-production
EOF

cat > overlays/production/argocd-app.yaml <<EOF
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: trino-production
spec:
  project: default
  source:
    repoURL: https://github.com/your-repo/trino-k8s-argocd.git
    targetRevision: HEAD
    path: overlays/production
  destination:
    server: https://kubernetes.default.svc
    namespace: trino-production
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    syncOptions:
    - CreateNamespace=true
EOF

# Development
cat > overlays/development/kustomization.yaml <<EOF
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
bases:
- ../../base
namespace: trino-development
EOF

cat > overlays/development/argocd-app.yaml <<EOF
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: trino-development
spec:
  project: default
  source:
    repoURL: https://github.com/your-repo/trino-k8s-argocd.git
    targetRevision: HEAD
    path: overlays/development
  destination:
    server: https://kubernetes.default.svc
    namespace: trino-development
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    syncOptions:
    - CreateNamespace=true
EOF

# Create scripts
cat > scripts/setup-minio-buckets.sh <<EOF
#!/bin/bash
kubectl exec -it \$(kubectl get pods -l app=minio -o jsonpath='{.items[0].metadata.name}') -- \\
  mc alias set minio http://minio:9000 minioadmin minioadmin
kubectl exec -it \$(kubectl get pods -l app=minio -o jsonpath='{.items[0].metadata.name}') -- \\
  mc mb minio/warehouse || true
EOF

cat > scripts/verify-installation.sh <<EOF
#!/bin/bash
echo "Checking pods..."
kubectl get pods -n trino-production

echo "Checking services..."
kubectl get svc -n trino-production

echo "Testing Trino connectivity..."
kubectl exec -it \$(kubectl get pods -l app=trino -n trino-production -o jsonpath='{.items[0].metadata.name}') -- \\
  trino --execute "SELECT 1"
EOF

chmod +x scripts/*.sh

# Create README
cat > README.md <<EOF
# Trino with Iceberg, Nessie, and MinIO on K3s with Argo CD

## Prerequisites
- K3s cluster
- Argo CD installed
- kubectl configured

## Deployment

1. For direct K3s deployment:
\`\`\`bash
kubectl apply -k overlays/production
\`\`\`

2. For Argo CD deployment:
\`\`\`bash
kubectl apply -f overlays/production/argocd-app.yaml
\`\`\`

3. Initialize MinIO buckets:
\`\`\`bash
./scripts/setup-minio-buckets.sh
\`\`\`

## Accessing Services

- Trino UI: \`kubectl port-forward svc/trino -n trino-production 8080:8080\`
- MinIO UI: \`kubectl port-forward svc/minio -n trino-production 9001:9001\`
- Nessie API: \`kubectl port-forward svc/nessie -n trino-production 19120:19120\`

## Verification
Run the verification script:
\`\`\`bash
./scripts/verify-installation.sh
\`\`\`
EOF

echo "Trino K8s Argo CD setup created in $ROOT_DIR directory"
