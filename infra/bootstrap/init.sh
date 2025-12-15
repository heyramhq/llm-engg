#!/bin/bash
set -e

echo "=== MLOps Node Bootstrap v2.0 Started ==="
echo "Timestamp: $(date)"
echo "Hostname: $(hostname)"
echo ""

# ============================================
# STEP 1: Fetch Secrets from Doppler
# ============================================
if [ -n "$DOPPLER_TOKEN" ]; then
    echo "Fetching secrets from Doppler..."
    
    # Install Doppler CLI
    (curl -Ls --tlsv1.2 --proto "=https" --retry 3 https://cli.doppler.com/install.sh || \
     wget -t 3 -qO- https://cli.doppler.com/install.sh) | sh
    
    # Export all secrets as environment variables
    export $(doppler secrets download --no-file --format env --token="$DOPPLER_TOKEN")
    
    echo "✓ Secrets loaded from Doppler"
else
    echo "⚠ No DOPPLER_TOKEN provided, using environment variables directly"
fi

# ============================================
# STEP 2: Install & Connect Tailscale (Container Mode)
# ============================================
if [ -n "$TAILSCALE_AUTHKEY" ]; then
    echo ""
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
            echo "✓ Daemon ready!"
            break
        fi
        echo -n "."
        sleep 1
    done
    echo ""
    
    echo "Connecting to Tailscale network..."
    tailscale up \
        --authkey="$TAILSCALE_AUTHKEY" \
        --ssh \
        --hostname="mlops-$(hostname)" \
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
        if ping -c 1 -W 2 $TAILSCALE_IP >/dev/null 2>&1; then
            echo "✓ Tailscale network is working"
        else
            echo "⚠ Warning: Could not ping Tailscale IP (may be normal for userspace mode)"
        fi
    else
        echo "⚠ Warning: Could not get Tailscale IP"
        echo "Check logs: tail -f /workspace/logs/tailscaled.log"
    fi
else
    echo "⚠ No TAILSCALE_AUTHKEY provided, skipping mesh network setup"
fi

# ============================================
# STEP 3: Configure Docker Registry
# ============================================
echo ""
if [ -n "$GCR_SERVICE_ACCOUNT_JSON" ]; then
    echo "Configuring Docker registry..."
    echo "$GCR_SERVICE_ACCOUNT_JSON" | docker login -u _json_key --password-stdin https://gcr.io
    echo "✓ Docker registry configured"
fi

# Configure Docker Hub if needed
if [ -n "$DOCKER_USERNAME" ] && [ -n "$DOCKER_PASSWORD" ]; then
    echo "$DOCKER_PASSWORD" | docker login -u "$DOCKER_USERNAME" --password-stdin
    echo "✓ Docker Hub configured"
fi

# # # ============================================
# # # STEP 4: Setup Rclone for Datasets
# # # ============================================
# # echo ""
# # echo "Installing rclone..."
# # curl -s https://rclone.org/install.sh | bash

# # # Configure rclone for S3
# # if [ -n "$AWS_ACCESS_KEY_ID" ] && [ -n "$AWS_SECRET_ACCESS_KEY" ]; then
# #     echo "Configuring rclone..."
# #     mkdir -p ~/.config/rclone

# #     cat > ~/.config/rclone/rclone.conf << EOF
# # [s3]
# # type = s3
# # provider = AWS
# # access_key_id = ${AWS_ACCESS_KEY_ID}
# # secret_access_key = ${AWS_SECRET_ACCESS_KEY}
# # region = us-east-1
# # endpoint = ${S3_ENDPOINT:-s3.amazonaws.com}

# # [datasets]
# # type = s3
# # provider = AWS
# # access_key_id = ${AWS_ACCESS_KEY_ID}
# # secret_access_key = ${AWS_SECRET_ACCESS_KEY}
# # region = us-east-1
# # EOF

# #     # Add bucket if specified
# #     if [ -n "$S3_BUCKET_NAME" ]; then
# #         echo "bucket = ${S3_BUCKET_NAME}" >> ~/.config/rclone/rclone.conf
# #     fi

# #     echo "✓ Rclone configured"
# # else
# #     echo "⚠ AWS credentials not provided, skipping rclone configuration"
# # fi

# # ============================================
# # STEP 5: Install ML Dependencies
# # ============================================
# echo ""
# echo "Installing Python packages..."
# pip install --upgrade pip -q

# # Core ML packages
# echo "  - Installing PyTorch..."
# pip install torch torchvision torchaudio --index-url https://download.pytorch.org/whl/cu118 -q

# echo "  - Installing Transformers & ML tools..."
# pip install transformers datasets accelerate bitsandbytes -q
# pip install huggingface_hub -q

# # Experiment tracking
# echo "  - Installing experiment tracking tools..."
# pip install wandb tensorboard -q
# pip install mlflow -q

# # Serving
# echo "  - Installing serving tools..."
# pip install vllm -q
# pip install fastapi uvicorn -q

# # Utilities
# echo "  - Installing utilities..."
# pip install jupyterlab ipywidgets -q
# pip install rclone-python -q

# echo "✓ Python packages installed"

# # Configure Weights & Biases
# if [ -n "$WANDB_API_KEY" ]; then
#     echo "Configuring W&B..."
#     wandb login "$WANDB_API_KEY" 2>/dev/null
#     echo "✓ W&B configured"
# fi

# # Configure HuggingFace
# if [ -n "$HF_TOKEN" ]; then
#     echo "Configuring HuggingFace..."
#     huggingface-cli login --token "$HF_TOKEN" 2>/dev/null
#     echo "✓ HuggingFace configured"
# fi

# # ============================================
# # STEP 6: Create Workspace Directories
# # ============================================
# echo ""
# echo "Creating workspace directories..."
# mkdir -p /workspace/data/{raw,processed,cache}
# mkdir -p /workspace/models/{pretrained,finetuned}
# mkdir -p /workspace/logs/{training,inference}
# mkdir -p /workspace/checkpoints
# mkdir -p /workspace/scripts
# mkdir -p /workspace/notebooks
# mkdir -p /workspace/outputs

# echo "✓ Workspace directories created"

# # ============================================
# # STEP 7: Setup SSH
# # ============================================
# if [ -n "$SSH_PUBLIC_KEY" ]; then
#     echo ""
#     echo "Configuring SSH..."
#     mkdir -p ~/.ssh
#     echo "$SSH_PUBLIC_KEY" >> ~/.ssh/authorized_keys
#     chmod 600 ~/.ssh/authorized_keys
#     chmod 700 ~/.ssh
#     echo "✓ SSH configured"
# fi

# # ============================================
# # STEP 8: Configure Git
# # ============================================
# if [ -n "$GIT_USER_NAME" ] && [ -n "$GIT_USER_EMAIL" ]; then
#     echo ""
#     echo "Configuring Git..."
#     git config --global user.name "$GIT_USER_NAME"
#     git config --global user.email "$GIT_USER_EMAIL"
#     echo "✓ Git configured"
# fi

# # Setup Git LFS
# git lfs install 2>/dev/null || echo "⚠ Git LFS not available"

# # ============================================
# # STEP 9: Install System Utilities
# # ============================================
# echo ""
# echo "Installing system utilities..."
# apt-get update -qq
# apt-get install -y -qq htop nvtop tmux vim curl wget tree jq unzip zip screen 2>/dev/null

# echo "✓ System utilities installed"

# # ============================================
# # STEP 10: Setup Dataset Sync Script
# # ============================================
# echo ""
# echo "Creating helper scripts..."

# cat > /usr/local/bin/sync-dataset << 'SYNCSCRIPT'
# #!/bin/bash
# # Usage: sync-dataset <dataset-name>
# DATASET_NAME=$1
# if [ -z "$DATASET_NAME" ]; then
#     echo "Usage: sync-dataset <dataset-name>"
#     echo ""
#     echo "Available datasets (from S3):"
#     rclone lsd datasets: 2>/dev/null | awk '{print "  - " $5}'
#     exit 1
# fi

# echo "Syncing dataset: $DATASET_NAME"
# rclone sync datasets:$DATASET_NAME /workspace/data/raw/$DATASET_NAME -P --transfers 8
# echo "✓ Dataset synced to /workspace/data/raw/$DATASET_NAME"
# SYNCSCRIPT

# chmod +x /usr/local/bin/sync-dataset

# # ============================================
# # STEP 11: Upload Checkpoints Script
# # ============================================

# cat > /usr/local/bin/upload-checkpoint << 'UPLOADSCRIPT'
# #!/bin/bash
# # Usage: upload-checkpoint <checkpoint-dir>
# CHECKPOINT_DIR=$1
# if [ -z "$CHECKPOINT_DIR" ]; then
#     echo "Usage: upload-checkpoint <checkpoint-dir>"
#     exit 1
# fi

# if [ ! -d "$CHECKPOINT_DIR" ]; then
#     echo "Error: Directory $CHECKPOINT_DIR does not exist"
#     exit 1
# fi

# CHECKPOINT_NAME=$(basename $CHECKPOINT_DIR)
# echo "Uploading checkpoint: $CHECKPOINT_NAME"
# rclone sync $CHECKPOINT_DIR datasets:checkpoints/$CHECKPOINT_NAME -P --transfers 8
# echo "✓ Checkpoint uploaded to s3://checkpoints/$CHECKPOINT_NAME"
# UPLOADSCRIPT

# chmod +x /usr/local/bin/upload-checkpoint

# # ============================================
# # STEP 12: Download Model Script
# # ============================================

# cat > /usr/local/bin/download-model << 'DOWNLOADSCRIPT'
# #!/bin/bash
# # Usage: download-model <model-name>
# MODEL_NAME=$1
# if [ -z "$MODEL_NAME" ]; then
#     echo "Usage: download-model <model-name>"
#     echo ""
#     echo "Example: download-model meta-llama/Llama-2-7b-hf"
#     exit 1
# fi

# echo "Downloading model: $MODEL_NAME"
# MODEL_DIR="/workspace/models/pretrained/$(echo $MODEL_NAME | sed 's/\//-/g')"
# mkdir -p "$MODEL_DIR"

# huggingface-cli download $MODEL_NAME --local-dir "$MODEL_DIR" --local-dir-use-symlinks False

# echo "✓ Model downloaded to $MODEL_DIR"
# DOWNLOADSCRIPT

# chmod +x /usr/local/bin/download-model

# # ============================================
# # STEP 13: List Available Datasets Script
# # ============================================

# cat > /usr/local/bin/list-datasets << 'LISTSCRIPT'
# #!/bin/bash
# # Usage: list-datasets
# echo "Available datasets in S3:"
# echo ""
# rclone lsd datasets: 2>/dev/null | awk '{print "  - " $5 " (" $4 " " $3 ")"}'
# echo ""
# echo "Cached datasets locally:"
# echo ""
# if [ -d "/workspace/data/raw" ]; then
#     ls -lh /workspace/data/raw | grep "^d" | awk '{print "  - " $9 " (" $5 ")"}'
# else
#     echo "  (none)"
# fi
# LISTSCRIPT

# chmod +x /usr/local/bin/list-datasets

# echo "✓ Helper scripts created"

# # ============================================
# # STEP 14: Start Jupyter Lab (Optional)
# # ============================================
# if [ "$START_JUPYTER" = "true" ]; then
#     echo ""
#     echo "Starting Jupyter Lab..."
    
#     # Generate config if doesn't exist
#     jupyter lab --generate-config 2>/dev/null || true
    
#     # Set password if provided, otherwise use token
#     if [ -n "$JUPYTER_PASSWORD" ]; then
#         JUPYTER_HASH=$(python3 -c "from jupyter_server.auth import passwd; print(passwd('$JUPYTER_PASSWORD'))")
#         echo "c.ServerApp.password = '$JUPYTER_HASH'" >> ~/.jupyter/jupyter_lab_config.py
#     else
#         echo "c.ServerApp.token = ''" >> ~/.jupyter/jupyter_lab_config.py
#         echo "c.ServerApp.password = ''" >> ~/.jupyter/jupyter_lab_config.py
#     fi
    
#     # Start Jupyter Lab
#     nohup jupyter lab \
#         --ip=0.0.0.0 \
#         --port=8888 \
#         --no-browser \
#         --allow-root \
#         --notebook-dir=/workspace \
#         > /workspace/logs/jupyter.log 2>&1 &
    
#     JUPYTER_PID=$!
#     echo "✓ Jupyter Lab started (PID: $JUPYTER_PID)"
    
#     if [ -n "$TAILSCALE_IP" ]; then
#         echo "  Access at: http://$TAILSCALE_IP:8888"
#     else
#         echo "  Access at: http://localhost:8888"
#     fi
# fi

# # ============================================
# # STEP 15: Keep Tailscale Alive (Watchdog)
# # ============================================
# if [ -n "$TAILSCALE_AUTHKEY" ]; then
#     echo ""
#     echo "Setting up Tailscale watchdog..."
    
#     cat > /usr/local/bin/tailscale-keepalive << 'KEEPALIVE'
# #!/bin/bash
# # Tailscale keepalive watchdog
# while true; do
#     if ! pgrep -x tailscaled > /dev/null; then
#         echo "[$(date)] Tailscaled died, restarting..." >> /workspace/logs/tailscale-keepalive.log
        
#         tailscaled \
#             --tun=userspace-networking \
#             --socks5-server=localhost:1055 \
#             --state=/var/lib/tailscale/tailscaled.state \
#             --socket=/var/run/tailscale/tailscaled.sock \
#             >> /workspace/logs/tailscaled.log 2>&1 &
        
#         sleep 5
        
#         # Reconnect
#         TAILSCALE_AUTHKEY=$(cat /workspace/.tailscale_authkey 2>/dev/null)
#         if [ -n "$TAILSCALE_AUTHKEY" ]; then
#             tailscale up --authkey="$TAILSCALE_AUTHKEY" --ssh >> /workspace/logs/tailscale-keepalive.log 2>&1
#         fi
#     fi
#     sleep 30
# done
# KEEPALIVE

#     chmod +x /usr/local/bin/tailscale-keepalive
    
#     # Save auth key for keepalive script
#     echo "$TAILSCALE_AUTHKEY" > /workspace/.tailscale_authkey
#     chmod 600 /workspace/.tailscale_authkey
    
#     # Start keepalive in background
#     nohup /usr/local/bin/tailscale-keepalive > /dev/null 2>&1 &
    
#     echo "✓ Tailscale watchdog started"
# fi

# # ============================================
# # STEP 16: Signal Readiness
# # ============================================
# echo ""
# echo "======================================================"
# echo "           Bootstrap Complete!                        "
# echo "======================================================"
# echo ""
# echo "Node Information:"
# echo "  Node ID: $(hostname)"
# echo "  Timestamp: $(date)"

# if [ -n "$TAILSCALE_IP" ]; then
#     echo ""
#     echo "Network:"
#     echo "  Tailscale IP: $TAILSCALE_IP"
#     echo "  SSH: ssh root@$TAILSCALE_IP"
    
#     if [ "$START_JUPYTER" = "true" ]; then
#         echo "  Jupyter: http://$TAILSCALE_IP:8888"
#     fi
# fi

# echo ""
# echo "GPU Information:"
# nvidia-smi --query-gpu=index,name,memory.total,memory.free --format=csv,noheader 2>/dev/null || echo "  GPU info not available"

# echo ""
# echo "Available Commands:"
# echo "  sync-dataset <name>      - Download dataset from S3"
# echo "  list-datasets            - List available datasets"
# echo "  upload-checkpoint <dir>  - Upload checkpoint to S3"
# echo "  download-model <name>    - Download model from HuggingFace"

# echo ""
# echo "Logs:"
# echo "  Tailscale: tail -f /workspace/logs/tailscaled.log"
# echo "  Jupyter: tail -f /workspace/logs/jupyter.log"

# echo ""
# echo "Workspace:"
# echo "  Data: /workspace/data"
# echo "  Models: /workspace/models"
# echo "  Checkpoints: /workspace/checkpoints"
# echo "  Notebooks: /workspace/notebooks"

# # Create ready marker
# cat > /workspace/.mlops_ready << EOF
# Bootstrap completed at: $(date)
# Node ID: $(hostname)
# Tailscale IP: ${TAILSCALE_IP:-N/A}
# Python: $(python3 --version)
# PyTorch: $(python3 -c "import torch; print(torch.__version__)" 2>/dev/null || echo "N/A")
# CUDA: $(python3 -c "import torch; print(torch.version.cuda)" 2>/dev/null || echo "N/A")
# EOF

# # Log bootstrap completion to S3 (if configured)
# if command -v rclone &> /dev/null && [ -n "$S3_BUCKET_NAME" ]; then
#     echo "Node $(hostname) bootstrapped at $(date)" | \
#         rclone rcat datasets:logs/bootstrap/$(hostname)-$(date +%s).log 2>/dev/null || true
# fi

echo ""
echo "✓ Node is ready for ML workloads!"
echo "======================================================"

# ============================================
# STEP 17: Keep Container Alive
# ============================================
echo ""
echo "Keeping container alive..."
echo "Press Ctrl+C to stop (or terminate via RunPod)"

# Keep container running indefinitely
tail -f /dev/null
