#!/bin/bash
set -e

echo "=== MLOps Node Bootstrap Started ==="

# 1. Install & Connect Tailscale
if [ -n "$TAILSCALE_AUTHKEY" ]; then
    echo "Installing Tailscale for containers..."
    curl -fsSL https://tailscale.com/install.sh | sh
    
    # Create required directories
    mkdir -p /var/run/tailscale /var/cache/tailscale /var/lib/tailscale
    mkdir -p /workspace/logs
    
    echo "Starting Tailscale daemon in userspace mode..."
    
    # Start daemon in background with logging
    nohup tailscaled \
        --tun=userspace-networking \
        --socks5-server=localhost:1055 \
        --state=/var/lib/tailscale/tailscaled.state \
        --socket=/var/run/tailscale/tailscaled.sock \
        > /workspace/logs/tailscaled.log 2>&1 &
    
    TAILSCALED_PID=$!
    echo "Tailscaled started with PID: $TAILSCALED_PID"
    
    # Wait for daemon to be ready
    echo "Waiting for daemon to be ready..."
    for i in {1..30}; do
        if tailscale status >/dev/null 2>&1; then
            echo "Daemon ready!"
            break
        fi
        sleep 1
    done
    
    echo "Connecting to Tailscale network..."
    tailscale up \
        --authkey="$TAILSCALE_AUTHKEY" \
        --ssh \
        --hostname="$TAILSCALE_HOSTNAME" \
        --accept-routes \
        --accept-dns=false
    
    # Wait for connection to establish
    sleep 5
    
    # Get Tailscale IP
    TAILSCALE_IP=$(tailscale ip -4 2>/dev/null)
    
    if [ -n "$TAILSCALE_IP" ]; then
        echo "✓ Tailscale connected: $TAILSCALE_IP"
        echo "$TAILSCALE_IP" > /workspace/.tailscale_ip
        
        # Verify connectivity
        echo "Testing connectivity..."
        if ping -c 1 $TAILSCALE_IP >/dev/null 2>&1; then
            echo "✓ Tailscale network is working"
        else
            echo "⚠ Warning: Could not ping Tailscale IP"
        fi
    else
        echo "⚠ Warning: Could not get Tailscale IP"
        echo "Check logs: tail -f /workspace/logs/tailscaled.log"
    fi
else
    echo "⚠ No TAILSCALE_AUTHKEY provided, skipping mesh network setup"
fi

# 2. Install common ML dependencies
echo "Installing Python packages..."
pip install --upgrade pip
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
