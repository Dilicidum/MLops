#!/usr/bin/env bash
set -euxo pipefail

# ----- Terraform-injected vars (DO NOT escape these) -----
REPO_URL="${repo_url}"
BUCKET="${bucket_name}"
REGION="${region}"
API_PORT="${api_port}"
MLFLOW_PORT="${mlflow_port}"

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

# Let common users use docker (for SSM sessions, etc.)
for U in ubuntu ssm-user; do id -u $U >/dev/null 2>&1 && usermod -aG docker $U || true; done

# ----- (Optional) SSM agent on Ubuntu -----
if ! systemctl is-active --quiet snap.amazon-ssm-agent.amazon-ssm-agent.service 2>/dev/null; then
  snap install amazon-ssm-agent --classic || true
  systemctl enable --now snap.amazon-ssm-agent.amazon-ssm-agent.service || true
fi

# ----- Checkout app -----
mkdir -p /opt/app
cd /opt/app
if [ ! -d "/opt/app/app/.git" ]; then
  git clone "$REPO_URL" app
else
  cd app
  git fetch --all
  git reset --hard origin/main || true
  cd ..
fi
cd app

# ----- Build fresh image (avoid stale bases) -----
# Also upgrade pip in the image so wheels resolve cleanly
cat > /tmp/Dockerfile.patch <<'EOF'
RUN python -m pip install --upgrade pip
EOF
# Insert the pip-upgrade line after WORKDIR if not present already (idempotent)
if ! grep -q "pip install --upgrade pip" Dockerfile; then
  awk '
    /WORKDIR/ && c==0 { print; print "ENV PIP_NO_CACHE_DIR=1 PIP_DISABLE_PIP_VERSION_CHECK=1"; print "RUN python -m pip install --upgrade pip"; c=1; next }
    { print }
  ' Dockerfile > Dockerfile.tmp && mv Dockerfile.tmp Dockerfile
fi

docker build --pull --no-cache -t pricing-api:latest .

# ----- Persistent storage -----
mkdir -p /opt/app/app/models /opt/app/app/data /opt/mlflow

# ----- Run MLflow -----
docker rm -f mlflow 2>/dev/null || true
docker run -d --name mlflow --restart unless-stopped \
  -p $${MLFLOW_PORT}:5000 \
  -e AWS_DEFAULT_REGION=$${REGION} \
  -v /opt/mlflow:/opt/mlflow \
  python:3.11-slim sh -lc "\
    python -m pip install --upgrade pip && \
    pip install --no-cache-dir mlflow boto3 && \
    mlflow server \
      --backend-store-uri sqlite:////opt/mlflow/mlruns.db \
      --default-artifact-root s3://$${BUCKET}/mlflow-artifacts \
      --host 0.0.0.0 --port 5000"

# ----- Run API -----
docker rm -f pricing-api 2>/dev/null || true
docker run -d --name pricing-api --restart unless-stopped \
  -p $${API_PORT}:5000 \
  -v /opt/app/app/models:/app/models \
  -v /opt/app/app/data:/app/data \
  -e AWS_DEFAULT_REGION=$${REGION} \
  -e MLFLOW_TRACKING_URI="http://127.0.0.1:$${MLFLOW_PORT}" \
  pricing-api:latest

# ----- Wait for API then trigger one training -----
for i in $(seq 1 30); do
  if curl -s "http://127.0.0.1:$${API_PORT}/health" | jq -e '.status=="healthy"' >/dev/null 2>&1; then
    break
  fi
  sleep 2
done

# Fire-and-forget baseline training (creates models/pricing_model.pkl etc.)
curl -sf -X POST "http://127.0.0.1:$${API_PORT}/Model/v1/retrain" || true
