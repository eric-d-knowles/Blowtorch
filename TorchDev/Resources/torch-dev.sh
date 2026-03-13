#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
# torch-dev: allocate a Torch HPC compute node and open it in VS Code/Positron
#
# Can be run interactively OR with settings passed via environment variables
# from the TorchDev.app GUI.
# =============================================================================

# --- Config ---
CONFIG_DIR="$HOME/.config/torch"
PREFS_FILE="$CONFIG_DIR/last_job_prefs"
TUNNEL_PID_FILE="$CONFIG_DIR/tunnel.pid"
TUNNEL_PORT_FILE="$CONFIG_DIR/tunnel.port"
SSH_CONFIG="$HOME/.ssh/config"
mkdir -p "$CONFIG_DIR"

# Local port range to search for a free port
TUNNEL_PORT_MIN=52200
TUNNEL_PORT_MAX=52299

# --- Detect cluster username ---
LOCAL_USER="${USER:-$(whoami)}"
CLUSTER_USER=""

if [[ -f "$SSH_CONFIG" ]]; then
    # Extract User from Host torch block - handle various formats
    CLUSTER_USER=$(awk '
        /^Host[[:space:]]+torch[[:space:]]*$/ { in_block=1; next }
        /^Host[[:space:]]/ { in_block=0 }
        in_block && /^[[:space:]]*User[[:space:]]/ { print $2; exit }
    ' "$SSH_CONFIG" | tr -d '\r' || true)
fi

# Only try SSH if not running from app (app handles auth separately)
if [[ -z "$CLUSTER_USER" && -z "${TORCH_SKIP_PROMPTS:-}" ]]; then
    CLUSTER_USER=$(ssh torch 'printf "%s" "$USER"' 2>/dev/null || true)
fi

if [[ -z "$CLUSTER_USER" ]]; then
    if [[ -n "${TORCH_SKIP_PROMPTS:-}" ]]; then
        # Running from app - use local username as fallback
        CLUSTER_USER="$LOCAL_USER"
    else
        read -p "Cluster username for SSH host 'torch' (default: $LOCAL_USER): " input_cluster_user
        CLUSTER_USER="${input_cluster_user:-$LOCAL_USER}"
    fi
fi

# --- Helper: find a free local port ---
_find_free_port() {
    local port
    for port in $(seq "$TUNNEL_PORT_MIN" "$TUNNEL_PORT_MAX"); do
        if ! (echo > /dev/tcp/localhost/$port) 2>/dev/null; then
            echo "$port"
            return 0
        fi
    done
    echo -e "\033[1;31mNo free port found in range $TUNNEL_PORT_MIN-$TUNNEL_PORT_MAX.\033[0m" >&2
    exit 1
}

# --- Helper: check if existing tunnel is still alive ---
_tunnel_alive() {
    local pid port
    [[ -f "$TUNNEL_PID_FILE" ]] || return 1
    [[ -f "$TUNNEL_PORT_FILE" ]] || return 1
    pid=$(cat "$TUNNEL_PID_FILE")
    port=$(cat "$TUNNEL_PORT_FILE")
    kill -0 "$pid" 2>/dev/null || return 1
    (echo > /dev/tcp/localhost/$port) 2>/dev/null || return 1
    return 0
}

# --- Helper: kill existing tunnel ---
_kill_tunnel() {
    if [[ -f "$TUNNEL_PID_FILE" ]]; then
        local pid
        pid=$(cat "$TUNNEL_PID_FILE")
        kill "$pid" 2>/dev/null || true
    fi
    rm -f "$TUNNEL_PID_FILE" "$TUNNEL_PORT_FILE"
}

# --- Cleanup on exit ---
SCRIPT_SUCCESS=false
cleanup() {
    if [[ "$SCRIPT_SUCCESS" != "true" ]]; then
        printf '\033[1;31mCleaning up...\033[0m\n'
        _kill_tunnel
        if [[ -n "${JOB_ID:-}" ]]; then
            ssh torch "scancel $JOB_ID 2>/dev/null || true" 2>/dev/null || true
        fi
    fi
}
trap cleanup EXIT

# --- Defaults ---
DEFAULT_TIME_HOURS=2
DEFAULT_PARTITION=""
DEFAULT_CPUS=4
DEFAULT_RAM=32
DEFAULT_GPU=no
DEFAULT_PROJECT=""
DEFAULT_ACCOUNT="torch_pr_217_general"
DEFAULT_IDE="vscode"

[[ -f "$PREFS_FILE" ]] && source "$PREFS_FILE"

TIME_HOURS="${TIME_HOURS:-$DEFAULT_TIME_HOURS}"
PARTITION="${PARTITION:-$DEFAULT_PARTITION}"
CPUS="${CPUS:-$DEFAULT_CPUS}"
RAM="${RAM:-$DEFAULT_RAM}"
GPU="${GPU:-$DEFAULT_GPU}"
PROJECT="${PROJECT:-$DEFAULT_PROJECT}"
ACCOUNT="${ACCOUNT:-$DEFAULT_ACCOUNT}"
IDE="${IDE:-$DEFAULT_IDE}"

# =============================================================================
# Check for GUI-provided settings via environment variables
# =============================================================================
if [[ "${TORCH_SKIP_PROMPTS:-}" == "1" ]]; then
    # Settings passed from GUI
    ACCOUNT="${TORCH_ACCOUNT:-$ACCOUNT}"
    TIME_HOURS="${TORCH_HOURS:-$TIME_HOURS}"
    PARTITION="${TORCH_PARTITION-$PARTITION}"
    CPUS="${TORCH_CPUS:-$CPUS}"
    RAM="${TORCH_RAM:-$RAM}"
    GPU="${TORCH_GPU:-$GPU}"
    PROJECT="${TORCH_PROJECT:-$PROJECT}"
    IDE="${TORCH_IDE:-$IDE}"
    
    echo -e "\033[1;34mSettings from Torch Dev app:\033[0m"
    echo "  Account:   $ACCOUNT"
    echo "  Hours:     $TIME_HOURS"
    echo "  Partition: ${PARTITION:-default}"
    echo "  CPUs:      $CPUS"
    echo "  RAM:       ${RAM}G"
    echo "  GPU:       $GPU"
    echo "  Project:   ${PROJECT:-none}"
    echo "  IDE:       $IDE"
    echo
else
    # --- Interactive prompts ---
    printf '\033[1;34mResource request:\033[0m\n'
    RAM_DISPLAY="$RAM"
    if [[ -n "$RAM_DISPLAY" && ! "$RAM_DISPLAY" =~ [gGmMkKtT]$ ]]; then
        RAM_DISPLAY="${RAM_DISPLAY}G"
    fi
    read -p "  Account (default: $ACCOUNT): " input_account
    read -p "  Hours (default: $TIME_HOURS): " input_time
    read -p "  Partition [leave blank for default]: " input_partition
    read -p "  CPUs (default: $CPUS): " input_cpus
    read -p "  RAM in G (default: $RAM_DISPLAY): " input_ram
    read -p "  GPU? [yes/no] (default: $GPU): " input_gpu
    read -p "  Project path under /scratch/$CLUSTER_USER/ (default: ${PROJECT:-none}): " input_project
    read -p "  IDE [vscode/positron] (default: $IDE): " input_ide
    echo

    [[ -n "$input_account" ]]   && ACCOUNT="$input_account"
    [[ -n "$input_time" ]]      && TIME_HOURS="$input_time"
    [[ -n "$input_partition" ]] && PARTITION="$input_partition"
    [[ -n "$input_cpus" ]]      && CPUS="$input_cpus"
    [[ -n "$input_ram" ]]       && RAM="$input_ram"
    [[ -n "$input_gpu" ]]       && GPU="$input_gpu"
    [[ -n "$input_project" ]]   && PROJECT="$input_project"
    [[ -n "$input_ide" ]]       && IDE="$input_ide"
fi

# Normalize RAM
if [[ -n "$RAM" && ! "$RAM" =~ [gGmMkKtT]$ ]]; then
    RAM="${RAM}G"
fi

# Normalize IDE (tr for bash 3.2 compat on macOS)
IDE=$(echo "$IDE" | tr '[:upper:]' '[:lower:]')
if [[ "$IDE" != "positron" ]]; then
    IDE="vscode"
fi

# Save prefs
cat > "$PREFS_FILE" <<EOF
TIME_HOURS=$TIME_HOURS
PARTITION=$PARTITION
CPUS=$CPUS
RAM=$RAM
GPU=$GPU
PROJECT="$PROJECT"
ACCOUNT="$ACCOUNT"
IDE="$IDE"
EOF

# Build project path
if [[ -n "$PROJECT" ]]; then
    WORK_DIR="/scratch/$CLUSTER_USER/$PROJECT"
else
    WORK_DIR="/scratch/$CLUSTER_USER"
fi

# =============================================================================
# Step 1: Authenticate to login node via ControlMaster
# =============================================================================
echo -e "\033[1;34mChecking SSH connection to Torch login node...\033[0m"
if ssh -O check torch 2>/dev/null; then
    echo "Already authenticated (reusing existing session)."
else
    echo "NEEDS_AUTH"
    echo "Browser authentication required."
    echo "Complete the sign-in, then click Continue in the app."
    echo
    
    # ssh -fNM will show PIN, wait for Enter, then background after auth
    ssh -fNM torch
    
    # Check if it worked
    if ssh -O check torch 2>/dev/null; then
        echo "Authenticated successfully."
    else
        echo -e "\033[1;31mAuthentication failed. Please try again.\033[0m"
        exit 1
    fi
fi
echo

# =============================================================================
# Step 2: Cancel old jobs and submit a new one
# =============================================================================
echo -e "\033[1;34mCleaning up old jobs...\033[0m"
ssh torch "scancel -u $CLUSTER_USER --name=torchdev 2>/dev/null || true"
ssh torch "mkdir -p ~/.config/torch"

echo -e "\033[1;34mSubmitting job...\033[0m"

GPU_FLAG=""
[[ "$GPU" == "yes" ]] && GPU_FLAG="--gres=gpu:1"

PARTITION_FLAG=""
[[ -n "$PARTITION" ]] && PARTITION_FLAG="--partition=$PARTITION"

SBATCH_CMD="sbatch --parsable --job-name=torchdev --time=${TIME_HOURS}:00:00 --account=$ACCOUNT"
[[ -n "$PARTITION_FLAG" ]] && SBATCH_CMD="$SBATCH_CMD $PARTITION_FLAG"
SBATCH_CMD="$SBATCH_CMD --cpus-per-task=$CPUS --mem=$RAM"
[[ -n "$GPU_FLAG" ]] && SBATCH_CMD="$SBATCH_CMD $GPU_FLAG"
SBATCH_CMD="$SBATCH_CMD --wrap=\"sleep infinity\""

JOB_ID=$(ssh torch "$SBATCH_CMD")
echo "Submitted job $JOB_ID"

# =============================================================================
# Step 3: Wait for compute node allocation
# =============================================================================
echo -e "\033[1;34mWaiting for compute node...\033[0m"
COMPUTE_NODE=""
for i in {1..1800}; do
    COMPUTE_NODE=$(ssh torch "squeue -j $JOB_ID -h -o '%N' 2>/dev/null | grep -v '^$'" || true)
    if [[ -n "$COMPUTE_NODE" ]]; then
        break
    fi
    sleep 1
    printf "."
done
echo

if [[ -z "$COMPUTE_NODE" ]]; then
    echo -e "\033[1;31mTimed out waiting for allocation (30 minutes).\033[0m"
    echo "Cancelling job $JOB_ID..."
    ssh torch "scancel $JOB_ID 2>/dev/null" || true
    exit 1
fi

echo -e "\033[1;32mAllocated: $COMPUTE_NODE\033[0m"

# =============================================================================
# Step 4: Start a local port-forward tunnel to the compute node
# =============================================================================
echo -e "\033[1;34mStarting tunnel to compute node...\033[0m"
_kill_tunnel

TUNNEL_PORT=$(_find_free_port)

ssh -f -N \
    -L "${TUNNEL_PORT}:${COMPUTE_NODE}:22" \
    -o ExitOnForwardFailure=yes \
    -o ServerAliveInterval=60 \
    -o ServerAliveCountMax=120 \
    torch

# Give it a moment to bind
sleep 1

# Find the tunnel PID by matching the forwarding spec
TUNNEL_PID=$(pgrep -f "ssh.*-L ${TUNNEL_PORT}:${COMPUTE_NODE}:22" | head -1 || true)
if [[ -n "$TUNNEL_PID" ]]; then
    echo "$TUNNEL_PID" > "$TUNNEL_PID_FILE"
fi
echo "$TUNNEL_PORT" > "$TUNNEL_PORT_FILE"

# Verify the port is accepting connections
if ! (echo > /dev/tcp/localhost/$TUNNEL_PORT) 2>/dev/null; then
    echo -e "\033[1;31mTunnel failed to bind on localhost:$TUNNEL_PORT.\033[0m"
    exit 1
fi
echo "Tunnel active: localhost:$TUNNEL_PORT -> $COMPUTE_NODE:22"

# =============================================================================
# Step 5: Update SSH config with a clean torch-compute entry
# =============================================================================
echo -e "\033[1;34mUpdating SSH config...\033[0m"

TMPFILE=$(mktemp)
# Remove old torch-compute block and trailing blank lines
awk '
    /^Host torch-compute$/ { skip=1; next }
    skip && /^Host / { skip=0 }
    !skip { print }
' "$SSH_CONFIG" | perl -pe 'chomp if eof' | cat - <(echo) > "$TMPFILE"

# Ensure exactly one trailing newline, no blank lines at end
perl -i -pe 'chomp if eof' "$TMPFILE"

cat >> "$TMPFILE" <<EOF

Host torch-compute
    HostName localhost
    Port $TUNNEL_PORT
    User $CLUSTER_USER
    IdentityFile ~/.ssh/id_ed25519
    PreferredAuthentications publickey
    StrictHostKeyChecking no
    UserKnownHostsFile /dev/null
    ServerAliveInterval 60
    ServerAliveCountMax 120
EOF

cp "$SSH_CONFIG" "${SSH_CONFIG}.bak"
mv "$TMPFILE" "$SSH_CONFIG"
chmod 600 "$SSH_CONFIG"

# =============================================================================
# Step 6: Wait for SSH to be ready through the tunnel
# =============================================================================
echo -e "\033[1;34mWaiting for SSH on compute node...\033[0m"
for i in {1..30}; do
    if ssh -o ConnectTimeout=2 torch-compute 'true' 2>/dev/null; then
        break
    fi
    sleep 2
    printf "."
done
echo

# Pre-trigger automount on compute node so /scratch is ready before VS Code connects
ssh torch-compute "ls /scratch/\$USER > /dev/null 2>&1 || true" 2>/dev/null || true

# =============================================================================
# Step 7: Launch IDE
# =============================================================================
_launch_vscode() {
    local uri="vscode-remote://ssh-remote+torch-compute${WORK_DIR}"
    if command -v code >/dev/null 2>&1; then
        echo -e "\033[1;32mLaunching VS Code...\033[0m"
        code --folder-uri "$uri"
    else
        echo -e "\033[1;33m'code' CLI not found.\033[0m"
        echo "Install it from VS Code: Command Palette → 'Shell Command: Install code command in PATH'"
        echo "Or: brew install --cask visual-studio-code"
        echo
        echo "Then run:"
        echo "  code --folder-uri \"$uri\""
    fi
    echo -e "To reconnect: \033[1;33mcode --folder-uri \"$uri\"\033[0m"
}

_launch_positron() {
    local uri="vscode-remote://ssh-remote+torch-compute${WORK_DIR}"
    if command -v positron >/dev/null 2>&1; then
        echo -e "\033[1;32mLaunching Positron...\033[0m"
        positron --folder-uri "$uri"
    else
        echo -e "\033[1;33m'positron' CLI not found.\033[0m"
        echo "Install Positron from: https://positron.posit.co/download.html"
        echo "Then: Command Palette → 'Shell Command: Install positron command in PATH'"
        echo
        echo "To connect manually once Positron is open:"
        echo "  Command Palette → Remote SSH: Show Remote Menu → Connect to Host → torch-compute"
        echo "  Then open: $WORK_DIR"
    fi
    echo -e "To reconnect manually: open Positron → Remote Explorer → torch-compute"
}

if [[ "$IDE" == "positron" ]]; then
    _launch_positron
else
    _launch_vscode
fi

echo
echo -e "\033[1;34mSession info:\033[0m"
echo -e "  Job ID:        \033[1;33m$JOB_ID\033[0m"
echo -e "  Compute node:  \033[1;33m$COMPUTE_NODE\033[0m"
echo -e "  Tunnel:        \033[1;33mlocalhost:$TUNNEL_PORT -> $COMPUTE_NODE:22\033[0m"
echo -e "  Work dir:      \033[1;33m$WORK_DIR\033[0m"
echo -e "  Time limit:    \033[1;33m${TIME_HOURS}h\033[0m"
echo -e "  IDE:           \033[1;33m$IDE\033[0m"
echo
echo -e "To cancel job:   \033[1;33mssh torch 'scancel $JOB_ID'\033[0m"
echo -e "To kill tunnel:  \033[1;33mkill \$(cat ~/.config/torch/tunnel.pid)\033[0m"

SCRIPT_SUCCESS=true
