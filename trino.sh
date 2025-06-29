#!/bin/bash
#Author : Krunal Patange
# Exit on any error, but handle expected failures gracefully
set -e

PROJECT_DIR="trino"

# Function to handle cleanup with proper error handling
cleanup_previous() {
    echo "🧹 Cleaning up any previous containers and data..."
    
    # Stop and remove containers, networks, volumes
    docker-compose down -v --remove-orphans 2>/dev/null || echo "   No existing docker-compose setup found"
    
    # Remove any dangling containers
    echo "🗑️  Removing any dangling containers..."
    docker ps -aq --filter "ancestor=trinodb/trino" 2>/dev/null | xargs -r docker rm -f 2>/dev/null || echo "   No Trino containers to remove"
    docker ps -aq --filter "ancestor=minio/minio" 2>/dev/null | xargs -r docker rm -f 2>/dev/null || echo "   No MinIO containers to remove"
    docker ps -aq --filter "ancestor=projectnessie/nessie" 2>/dev/null | xargs -r docker rm -f 2>/dev/null || echo "   No Nessie containers to remove"
    
    # Remove dangling volumes
    echo "🗑️  Removing dangling volumes..."
    docker volume ls -q --filter "dangling=true" 2>/dev/null | xargs -r docker volume rm 2>/dev/null || echo "   No dangling volumes to remove"
    
    # Clean up project directory
    if [ -d "$PROJECT_DIR" ]; then
        echo "🗑️  Removing existing project directory..."
        rm -rf "$PROJECT_DIR"
    fi
}

# Function to create directory structure
create_structure() {
    echo "📁 Creating project structure..."
    mkdir -p "$PROJECT_DIR/trino/etc/catalog"
    cd "$PROJECT_DIR"
    
    if [ ! -d "trino/etc/catalog" ]; then
        echo "❌ Error: Failed to create project structure"
        exit 1
    fi
}

# Function to create docker-compose file
create_docker_compose() {
    echo "📦 Creating docker-compose.yml..."
    cat > docker-compose.yml <<'EOF'
version: '3.8'
services:
  minio:
    image: minio/minio:latest
    container_name: trino-minio
    ports:
      - "9000:9000"
      - "9001:9001"
    environment:
      MINIO_ROOT_USER: minioadmin
      MINIO_ROOT_PASSWORD: minioadmin
    command: server /data --console-address ":9001"
    volumes:
      - minio_data:/data
    healthcheck:
      test: ["CMD", "curl", "-f", "http://localhost:9000/minio/health/live"]
      interval: 30s
      timeout: 20s
      retries: 3

  nessie:
    image: projectnessie/nessie:latest
    container_name: trino-nessie
    ports:
      - "19120:19120"
    environment:
      NESSIE_VERSION_STORE_TYPE: IN_MEMORY
    healthcheck:
      test: ["CMD", "curl", "-f", "http://localhost:19120/api/v1/config"]
      interval: 30s
      timeout: 10s
      retries: 3

  trino:
    image: trinodb/trino:latest
    container_name: trino-coordinator
    ports:
      - "8080:8080"
    volumes:
      - ./trino/etc:/etc/trino:ro
    depends_on:
      minio:
        condition: service_healthy
      nessie:
        condition: service_healthy
    healthcheck:
      test: ["CMD-SHELL", "/usr/lib/trino/bin/health-check"]
      interval: 30s
      timeout: 10s
      retries: 5
      start_period: 60s

volumes:
  minio_data:
EOF
    
    if [ ! -f "docker-compose.yml" ]; then
        echo "❌ Error: Failed to create docker-compose.yml"
        exit 1
    fi
}

# Function to create Trino configuration files
create_trino_configs() {
    echo "🛠️  Creating Trino config files..."
    
    # jvm.config
    cat > trino/etc/jvm.config <<'EOF'
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
    
    # config.properties
    cat > trino/etc/config.properties <<'EOF'
coordinator=true
node-scheduler.include-coordinator=true
http-server.http.port=8080
query.max-memory=1GB
query.max-memory-per-node=512MB
discovery.uri=http://localhost:8080
EOF
    
    # node.properties
    cat > trino/etc/node.properties <<'EOF'
node.environment=demo
node.id=trino-demo
node.data-dir=/data/trino
EOF
    
    # log.properties
    cat > trino/etc/log.properties <<'EOF'
io.trino=INFO
EOF
    
    # Corrected iceberg.properties
    cat > trino/etc/catalog/iceberg.properties <<'EOF'
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
    
    if [ ! -f "trino/etc/jvm.config" ] || [ ! -f "trino/etc/config.properties" ] || [ ! -f "trino/etc/catalog/iceberg.properties" ]; then
        echo "❌ Error: Failed to create Trino configuration files"
        exit 1
    fi
}

# Function to start containers
start_containers() {
    echo "🚀 Bringing up containers..."
    
    if [ ! -f "docker-compose.yml" ]; then
        echo "❌ Error: docker-compose.yml not found"
        exit 1
    fi
    
    if ! docker-compose up -d; then
        echo "❌ Error: Failed to start containers"
        docker-compose logs || true
        exit 1
    fi
    
    echo "⏳ Waiting for services to initialize..."
    sleep 20
    
    # Setup MinIO bucket
    echo "🪣 Configuring MinIO..."
    if ! docker-compose exec minio mc alias set minio http://minio:9000 minioadmin minioadmin; then
        echo "⚠️  Failed to set MinIO alias"
    fi
    
    if ! docker-compose exec minio mc mb minio/warehouse; then
        echo "⚠️  Failed to create bucket, trying fallback method..."
        docker-compose exec minio mkdir -p /data/warehouse || echo "⚠️  Could not create warehouse directory"
    fi
    
    echo "🔍 Checking container status..."
    if ! docker-compose ps | grep -q "Up.*healthy.*trino"; then
        echo "⚠️  Trino may not be healthy. Checking logs..."
        docker-compose logs trino | tail -50
        sleep 30
    fi
}

# Function to display final info
show_info() {
    echo ""
    echo "✅ Setup complete!"
    echo "➡️  Trino UI:  http://localhost:8080"
    echo "➡️  MinIO UI:  http://localhost:9001 (minioadmin/minioadmin)"
    echo "➡️  Nessie API: http://localhost:19120/api/v1"
    echo ""
    echo "ℹ️  Example commands:"
    echo "   docker exec -it trino-coordinator trino"
    echo "   CREATE SCHEMA iceberg.nessie WITH (location = 's3://warehouse/')"
    echo "   CREATE TABLE iceberg.nessie.demo (id int, name varchar)"
    echo ""
    echo "🧹 Cleanup: docker-compose down -v && rm -rf $PROJECT_DIR"
}

# Main execution
main() {
    echo "🎯 Starting Trino + Iceberg + Nessie + MinIO setup"
    
    ORIGINAL_DIR=$(pwd)
    cd "$ORIGINAL_DIR"
    
    cleanup_previous
    create_structure
    create_docker_compose
    create_trino_configs
    start_containers
    show_info
    
    echo "🎉 Done! Trino environment is ready."
}

main
