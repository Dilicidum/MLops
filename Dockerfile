# Dockerfile
FROM python:3.11-slim-bookworm

WORKDIR /app

# System deps for scientific libs
RUN apt-get update && apt-get install -y gcc && rm -rf /var/lib/apt/lists/*

# Use a recent pip
ENV PIP_NO_CACHE_DIR=1 PIP_DISABLE_PIP_VERSION_CHECK=1
RUN python -m pip install --upgrade pip

# Install Python deps first (layer cache)
COPY requirements.txt .
RUN pip install -r requirements.txt

# Copy app
COPY . .

# Runtime dirs (models are created at runtime)
RUN mkdir -p data models mlruns

EXPOSE 5000
CMD ["python", "api.py"]
