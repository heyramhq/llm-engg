#!/bin/bash
set -e

echo "=== MLOps Node Bootstrap Started ==="

# 1. Install & Connect Tailscale
if [ -n "$TAILSCALE_AUTHKEY" ]; then
    echo "Installing Tailscale..."
    curl -fsSL https://tailscale.com/install.sh | sh
    
    echo "Connecting to Tailscale network..."
    # Use provided hostname or fallback to system hostname
    TS_HOSTNAME="${TAILSCALE_HOSTNAME:-mlops-$(hostname)}"
    tailscale up --authkey="$TAILSCALE_AUTHKEY" --ssh --hostname="$TS_HOSTNAME"
    
    # Wait for connection
    sleep 5
    TAILSCALE_IP=$(tailscale ip -4)
    echo "✓ Tailscale connected: $TAILSCALE_IP"
    
    # Save IP for later reference
    echo "$TAILSCALE_IP" > /workspace/.tailscale_ip
else
    echo "⚠ No TAILSCALE_AUTHKEY provided, skipping mesh network setup"
fi

# 2. Install common ML dependencies
echo "Installing Python packages..."
pip install --upgrade pip
pip install torch torchvision torchaudio --index-url https://download.pytorch.org/whl/cu121
pip install transformers datasets accelerate bitsandbytes
pip install wandb tensorboard jupyterlab

# 3. Configure Docker registry access (if credentials provided)
if [ -n "$GCR_SERVICE_ACCOUNT_JSON" ]; then
    echo "Configuring Docker registry access..."
    echo "$GCR_SERVICE_ACCOUNT_JSON" | docker login -u _json_key --password-stdin https://gcr.io
    echo "✓ Docker registry configured"
fi

# 4. Create workspace directories
mkdir -p /workspace/data
mkdir -p /workspace/models
mkdir -p /workspace/logs
mkdir -p /workspace/checkpoints
mkdir -p /workspace/scripts

# 5. Set up SSH keys (if provided)
if [ -n "$SSH_PUBLIC_KEY" ]; then
    echo "Adding SSH public key..."
    mkdir -p ~/.ssh
    echo "$SSH_PUBLIC_KEY" >> ~/.ssh/authorized_keys
    chmod 600 ~/.ssh/authorized_keys
    chmod 700 ~/.ssh
fi

# 6. Install common utilities
apt-get update -qq
apt-get install -y -qq htop nvtop tmux git-lfs vim curl wget

# 7. Configure git (if credentials provided)
if [ -n "$GIT_USER_NAME" ] && [ -n "$GIT_USER_EMAIL" ]; then
    git config --global user.name "$GIT_USER_NAME"
    git config --global user.email "$GIT_USER_EMAIL"
fi

# 8. Start Jupyter Lab (accessible via Tailscale)
if [ "$START_JUPYTER" = "true" ]; then
    echo "Starting Jupyter Lab..."
    nohup jupyter lab --ip=0.0.0.0 --port=8888 --no-browser --allow-root \
        --NotebookApp.token='' --NotebookApp.password='' \
        > /workspace/logs/jupyter.log 2>&1 &
    echo "✓ Jupyter Lab started on port 8888"
fi

# 9. Signal readiness
echo "=== Bootstrap Complete ==="
echo "Node ID: $(hostname)"
if [ -n "$TAILSCALE_IP" ]; then
    echo "Tailscale IP: $TAILSCALE_IP"
    echo "SSH Access: ssh root@$TAILSCALE_IP"
    echo "Jupyter: http://$TAILSCALE_IP:8888"
fi
echo "GPU Info:"
nvidia-smi --query-gpu=name,memory.total --format=csv,noheader

# Create ready file
touch /workspace/.mlops_ready
date > /workspace/.mlops_ready
