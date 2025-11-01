#!/usr/bin/env bash
set -euo pipefail

REPO_URL="${repo_url}"
BUCKET="${bucket_name}"
REGION="${region}"
API_PORT="${api_port}"
MLFLOW_PORT="${mlflow_port}"

# Install basics + SSM Agent
apt-get update -y
apt-get install -y docker.io docker-compose-plugin git curl unzip
systemctl enable docker
systemctl start docker
usermod -aG docker ubuntu || true

# Install/ensure SSM Agent (Ubuntu)
snap install amazon-ssm-agent --classic || true
systemctl enable snap.amazon-ssm-agent.amazon-ssm-agent.service || true
systemctl start snap.amazon-ssm-agent.amazon-ssm-agent.service || true

# App checkout
mkdir -p /opt/app
cd /opt/app

# If an S3 bundle was provided, download & unpack it. Otherwise use repo_url.
if [ -n "${app_key:-}" ] && [ "${app_key}" != "null" ]; then
  apt-get update -y && apt-get install -y unzip awscli
  aws s3 cp "s3://${BUCKET}/${app_key}" /opt/app/app.zip
  rm -rf /opt/app/app
  mkdir -p /opt/app/app
  unzip -q /opt/app/app.zip -d /opt/app/app
else
  if [ -n "${REPO_URL}" ] && [ "${REPO_URL}" != "null" ]; then
    apt-get install -y git
    git clone "$REPO_URL" app || (echo "Repo clone failed"; exit 1)
  else
    echo "No S3 bundle and no repo_url provided"; exit 1
  fi
fi

cd /opt/app/app

# Pull base images to avoid flaky builds
docker pull python:3.9-slim || true
docker pull python:3.11-slim || true

# Build API image from your Dockerfile
docker build -t pricing-api:latest .

# Persistent dirs
mkdir -p /opt/app/app/models /opt/app/app/data /opt/mlflow

# Start MLflow server (artifacts -> S3, backend -> sqlite)
docker rm -f mlflow 2>/dev/null || true
docker run -d --name mlflow \
  --restart unless-stopped \
  -p ${MLFLOW_PORT}:5000 \
  -e AWS_DEFAULT_REGION=${REGION} \
  -v /opt/mlflow:/opt/mlflow \
  python:3.11-slim sh -lc "\
     pip install --no-cache-dir mlflow boto3 && \
     mlflow server \
       --backend-store-uri sqlite:////opt/mlflow/mlruns.db \
       --default-artifact-root s3://${BUCKET}/mlflow-artifacts \
       --host 0.0.0.0 --port 5000"

# Run your API (env var points training code at MLflow)
docker rm -f pricing-api 2>/dev/null || true
docker run -d --name pricing-api \
  --restart unless-stopped \
  -p ${API_PORT}:5000 \
  -v /opt/app/app/models:/app/models \
  -v /opt/app/app/data:/app/data \
  -e AWS_DEFAULT_REGION=${REGION} \
  -e MLFLOW_TRACKING_URI="http://127.0.0.1:${MLFLOW_PORT}" \
  pricing-api:latest
