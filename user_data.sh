#!/usr/bin/env bash
set -Eeuo pipefail

# ============ Terraform-injected variables ============
REPO_URL="${repo_url}"
BUCKET="${bucket_name}"
REGION="${region}"
API_PORT="${api_port}"
MLFLOW_PORT="${mlflow_port}"
REPO_REF="${repo_ref}"
# ======================================================

# Log everything to a dedicated file too
exec > >(tee -a /var/log/pricing-bootstrap.log) 2>&1
log() { echo "[$(date -Is)] $*"; }

log "---- Bootstrap start ----"
log "Repo: $REPO_URL  ref: $REPO_REF  Region: $REGION  Ports: API=$API_PORT, MLFLOW=$MLFLOW_PORT"

# ----- Base deps -----
apt-get update -y
apt-get install -y ca-certificates curl gnupg git unzip jq

# ----- Docker (official repo) -----
install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
chmod a+r /etc/apt/keyrings/docker.gpg
. /etc/os-release
echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu $${VERSION_CODENAME} stable" \
  > /etc/apt/sources.list.d/docker.list
apt-get update -y
apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
systemctl enable --now docker

# Let SSM and ubuntu users run docker
for U in ubuntu ssm-user; do id -u "$U" >/dev/null 2>&1 && usermod -aG docker "$U" || true; done

# ----- (Optional) SSM Agent on Ubuntu -----
if ! systemctl is-active --quiet snap.amazon-ssm-agent.amazon-ssm-agent.service 2>/dev/null; then
  snap install amazon-ssm-agent --classic || true
  systemctl enable --now snap.amazon-ssm-agent.amazon-ssm-agent.service || true
fi

# ----- Create a dedicated Docker network -----
docker network create pricing-net || true

# ----- Checkout app fresh -----
mkdir -p /opt/app
cd /opt/app
rm -rf app
git clone --depth 1 --branch "$REPO_REF" "$REPO_URL" app
cd app
log "Checked out commit: $(git rev-parse --short HEAD || echo unknown)"

# ----- Ensure Dockerfile uses up-to-date pip (idempotent) -----
if ! grep -q "pip install --upgrade pip" Dockerfile; then
  log "Injecting pip upgrade into Dockerfile for clean wheels"
  awk '
    /WORKDIR/ && c==0 { print; print "ENV PIP_NO_CACHE_DIR=1 PIP_DISABLE_PIP_VERSION_CHECK=1"; print "RUN python -m pip install --upgrade pip"; c=1; next }
    { print }
  ' Dockerfile > Dockerfile.tmp && mv Dockerfile.tmp Dockerfile
fi

# ----- Build image (no cache) -----
log "Building Docker image pricing-api:latest"
docker build --pull --no-cache -t pricing-api:latest .

log "Image built. Listing images:"
docker images | tee /var/log/pricing-images.txt

# ----- Persistent storage -----
mkdir -p /opt/app/app/models /opt/app/app/data /opt/mlflow /opt/nginx

# ----- Start MLflow (internal only; no public port here) -----
log "Starting MLflow..."
docker rm -f mlflow >/dev/null 2>&1 || true
docker run -d --name mlflow --restart unless-stopped \
  --network pricing-net \
  -e AWS_DEFAULT_REGION=$${REGION} \
  -v /opt/mlflow:/opt/mlflow \
  python:3.11-slim sh -lc "\
    python -m pip install --upgrade pip && \
    pip install --no-cache-dir mlflow boto3 && \
    mlflow server \
      --backend-store-uri sqlite:////opt/mlflow/mlruns.db \
      --default-artifact-root s3://$${BUCKET}/mlflow-artifacts \
      --host 0.0.0.0 --port 5000"

sleep 3
if ! docker ps --format '{{.Names}}' | grep -qx mlflow; then
  log "ERROR: mlflow container not running. Capturing logs..."
  docker logs mlflow > /var/log/mlflow-container.log 2>&1 || true
  exit 1
fi
log "MLflow listening on mlflow:5000 (Docker network)"

# ----- Nginx reverse proxy for MLflow (fix Host header) -----
log "Writing Nginx config for MLflow proxy..."
cat >/opt/nginx/mlflow.conf <<'NGINX'
events {}
http {
  server {
    listen 5001;
    location / {
      proxy_http_version 1.1;
      proxy_set_header Host localhost;         # <-- fixes "Invalid Host header"
      proxy_set_header X-Forwarded-For $remote_addr;
      proxy_set_header X-Forwarded-Proto $scheme;
      proxy_pass http://mlflow:5000;
    }
  }
}
NGINX

log "Starting mlflow-proxy..."
docker rm -f mlflow-proxy >/dev/null 2>&1 || true
docker run -d --name mlflow-proxy --restart unless-stopped \
  --network pricing-net \
  -p $${MLFLOW_PORT}:5001 \
  -v /opt/nginx/mlflow.conf:/etc/nginx/nginx.conf:ro \
  nginx:stable

sleep 2
if ! docker ps --format '{{.Names}}' | grep -qx mlflow-proxy; then
  log "ERROR: mlflow-proxy (nginx) not running. Capturing logs..."
  docker logs mlflow-proxy > /var/log/mlflow-proxy.log 2>&1 || true
  exit 1
fi
log "MLflow UI exposed at :$${MLFLOW_PORT} via nginx"

# ----- Run API (expose public port; talk to MLflow by name) -----
log "Starting pricing-api..."
docker rm -f pricing-api >/dev/null 2>&1 || true
docker run -d --name pricing-api --restart unless-stopped \
  --network pricing-net \
  -p $${API_PORT}:5000 \
  -v /opt/app/app/models:/app/models \
  -v /opt/app/app/data:/app/data \
  -e AWS_DEFAULT_REGION=$${REGION} \
  -e MLFLOW_TRACKING_URI="http://mlflow:5000" \
  pricing-api:latest

sleep 3
if ! docker ps --format '{{.Names}}' | grep -qx pricing-api; then
  log "ERROR: pricing-api container not running. Capturing logs..."
  docker logs pricing-api > /var/log/pricing-api-container.log 2>&1 || true
  exit 1
fi

# ----- Health check & one-shot training -----
log "Waiting for API health..."
for i in $(seq 1 30); do
  if curl -s "http://127.0.0.1:$${API_PORT}/health" | jq -e '.status=="healthy"' >/dev/null 2>&1; then
    log "API healthy."
    break
  fi
  sleep 2
done

if ! curl -s "http://127.0.0.1:$${API_PORT}/health" | jq -e '.status=="healthy"' >/dev/null 2>&1; then
  log "ERROR: API did not become healthy. Dumping container logs..."
  docker logs pricing-api > /var/log/pricing-api-container.log 2>&1 || true
  exit 1
fi

log "Triggering one-time training..."
curl -sf -X POST "http://127.0.0.1:$${API_PORT}/Model/v1/retrain" || log "Training endpoint returned non-200 (continuing)."

log "Containers:"
docker ps
log "---- Bootstrap finished OK ----"
