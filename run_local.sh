#!/bin/bash

echo "Dynamic Pricing Model - Local Setup"
echo "===================================="

# Create necessary directories
echo "Creating directories..."
mkdir -p data models mlruns

# Install dependencies
echo "Installing dependencies..."
pip install -r requirements.txt

# Train initial model
echo "Training baseline model..."
python train_model.py

# Start API
echo "Starting API..."
python api.py &
API_PID=$!

# Wait for API to start
sleep 3

# Run demo
echo "Running demo..."
python demo.py

# Optional: Kill API after demo
# kill $API_PID

echo "Setup complete!"
echo "API is running on http://localhost:5000"
echo "To stop API, use: kill $API_PID"