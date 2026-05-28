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
        # Remove conda settings on failure
        if [[ -n "${CONDA_ENV:-}" ]]; then
            ssh torch-compute "
                rm -f ~/.vscode-server/data/Machine/settings.json 2>/dev/null
                rm -f ~/.positron-server/data/Machine/settings.json 2>/dev/null
            " 2>/dev/null || true
        fi
        if [[ -n "${JOB_ID:-}" ]]; then
            ssh torch "bash -lc 'scancel $JOB_ID 2>/dev/null || true'" 2>/dev/null || true
        fi
    fi
    # On success, the tunnel and Machine settings.json are intentionally left
    # in place. The Blowtorch app cleans them when the session ends (cancel
    # job, new connect, or app quit).
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
DEFAULT_CONDA_ENV=""

[[ -f "$PREFS_FILE" ]] && source "$PREFS_FILE"

TIME_HOURS="${TIME_HOURS:-$DEFAULT_TIME_HOURS}"
PARTITION="${PARTITION:-$DEFAULT_PARTITION}"
CPUS="${CPUS:-$DEFAULT_CPUS}"
RAM="${RAM:-$DEFAULT_RAM}"
GPU="${GPU:-$DEFAULT_GPU}"
PROJECT="${PROJECT:-$DEFAULT_PROJECT}"
ACCOUNT="${ACCOUNT:-$DEFAULT_ACCOUNT}"
IDE="${IDE:-$DEFAULT_IDE}"
CONDA_ENV="${CONDA_ENV:-$DEFAULT_CONDA_ENV}"

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
    CONDA_ENV="${TORCH_CONDA_ENV:-$CONDA_ENV}"
    
    echo -e "\033[1;34mSettings from Torch Dev app:\033[0m"
    echo "  Account:   $ACCOUNT"
    echo "  Hours:     $TIME_HOURS"
    echo "  Partition: ${PARTITION:-default}"
    echo "  CPUs:      $CPUS"
    echo "  RAM:       ${RAM}G"
    echo "  GPU:       $GPU"
    echo "  Project:   ${PROJECT:-none}"
    echo "  IDE:       $IDE"
    echo "  Conda env: ${CONDA_ENV:-none}"
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
    read -p "  Conda environment (optional): " input_conda_env
    echo

    [[ -n "$input_account" ]]   && ACCOUNT="$input_account"
    [[ -n "$input_time" ]]      && TIME_HOURS="$input_time"
    [[ -n "$input_partition" ]] && PARTITION="$input_partition"
    [[ -n "$input_cpus" ]]      && CPUS="$input_cpus"
    [[ -n "$input_ram" ]]       && RAM="$input_ram"
    [[ -n "$input_gpu" ]]       && GPU="$input_gpu"
    [[ -n "$input_project" ]]   && PROJECT="$input_project"
    [[ -n "$input_ide" ]]       && IDE="$input_ide"
    [[ -n "$input_conda_env" ]] && CONDA_ENV="$input_conda_env"
fi

# Normalize RAM
if [[ -n "$RAM" && ! "$RAM" =~ [gGmMkKtT]$ ]]; then
    RAM="${RAM}G"
fi

# Normalize IDE (tr for bash 3.2 compat on macOS)
IDE=$(echo "$IDE" | tr '[:upper:]' '[:lower:]')
if [[ "$IDE" != "positron" && "$IDE" != "none" ]]; then
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
CONDA_ENV="$CONDA_ENV"
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
ssh torch "bash -lc 'scancel -u $CLUSTER_USER --name=torchdev 2>/dev/null || true'"
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

JOB_ID=$(ssh torch "bash -lc '$SBATCH_CMD'")
echo "Submitted job $JOB_ID"

# =============================================================================
# Step 3: Wait for compute node allocation
# =============================================================================
echo -e "\033[1;34mWaiting for compute node...\033[0m"
COMPUTE_NODE=""
for i in {1..1800}; do
    COMPUTE_NODE=$(ssh torch "bash -lc \"squeue -j $JOB_ID -h -o '%N' 2>/dev/null | grep -v '^\$'\"" || true)
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
    ssh torch "bash -lc 'scancel $JOB_ID 2>/dev/null'" || true
    exit 1
fi

echo -e "\033[1;32mAllocated: $COMPUTE_NODE\033[0m"

# =============================================================================
# Step 4: Start tunnel and update SSH config
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
    StrictHostKeyChecking no
    UserKnownHostsFile /dev/null
    ServerAliveInterval 60
    ServerAliveCountMax 120
EOF

cp "$SSH_CONFIG" "${SSH_CONFIG}.bak"
mv "$TMPFILE" "$SSH_CONFIG"
chmod 600 "$SSH_CONFIG"

# =============================================================================
# Step 5: Wait for SSH to be ready on compute node
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
# Step 6: Activate conda environment on compute node (if requested)
# =============================================================================
if [[ -n "${CONDA_ENV:-}" ]]; then
    echo -e "\033[1;34mActivating conda environment: $CONDA_ENV\033[0m"

    # Discover the conda module name on the login node
    CONDA_MODULE=$(ssh torch "bash -lc 'module avail conda 2>&1'" | \
        grep -oE 'anaconda3/[0-9]{4}\.[0-9]{2}' | sort | tail -1)
    CONDA_MODULE="${CONDA_MODULE:-anaconda3}"

    # Find the conda binary path on the compute node
    CONDA_EXE_PATH=$(ssh torch-compute "bash -lc 'module load ${CONDA_MODULE} 2>/dev/null; echo \$CONDA_EXE'" 2>/dev/null | tr -d '[:space:]')
    if [[ -z "$CONDA_EXE_PATH" ]]; then
        # Fallback: probe common install locations
        CONDA_EXE_PATH=$(ssh torch-compute "for p in /share/apps/anaconda3/*/bin/conda /opt/conda/bin/conda; do [ -f \"\$p\" ] && echo \"\$p\" && break; done" 2>/dev/null | tr -d '[:space:]')
    fi

    if [[ -z "$CONDA_EXE_PATH" ]]; then
        echo -e "\033[1;31mCould not locate conda on the compute node.\033[0m"
        exit 1
    fi
    CONDA_ROOT=$(dirname "$(dirname "$CONDA_EXE_PATH")")
    echo "  conda: $CONDA_EXE_PATH"

    # Verify the environment exists; fall back to base if not found
    ENV_EXISTS=$(ssh torch-compute "bash -lc 'export CONDA_PLUGINS_AUTO_ACCEPT_TOS=yes; module load ${CONDA_MODULE} 2>&1 && conda env list 2>/dev/null'" | \
        awk '{print $1}' | grep -x "${CONDA_ENV}" || true)
    if [[ -z "$ENV_EXISTS" ]]; then
        echo -e "\033[1;33mConda environment '${CONDA_ENV}' not found. Falling back to base.\033[0m"
        echo "Available environments:"
        ssh torch-compute "bash -lc 'export CONDA_PLUGINS_AUTO_ACCEPT_TOS=yes; module load ${CONDA_MODULE} 2>&1 && conda env list 2>/dev/null'" | grep -v '^#' | grep -v '^$' || true
        CONDA_ENV="base"
    fi

    # Find the environment's prefix path
    if [[ "$CONDA_ENV" == "base" ]]; then
        ENV_PREFIX="$CONDA_ROOT"
    else
        ENV_PREFIX=$(ssh torch-compute "bash -lc 'export CONDA_PLUGINS_AUTO_ACCEPT_TOS=yes; module load ${CONDA_MODULE} 2>/dev/null; conda env list 2>/dev/null'" | \
            awk -v env="$CONDA_ENV" '$1 == env {print $NF}' | tr -d '[:space:]')
        ENV_PREFIX="${ENV_PREFIX:-/scratch/${CLUSTER_USER}/.conda/envs/${CONDA_ENV}}"
    fi

    # Check which language runtimes the env has
    ENV_CHECKS=$(ssh torch-compute "
        [ -x '${ENV_PREFIX}/bin/python' ] && echo HAS_PYTHON || true
        [ -x '${ENV_PREFIX}/bin/R' ] && echo HAS_R || true
    " 2>/dev/null)
    HAS_PYTHON=$(echo "$ENV_CHECKS" | grep -c HAS_PYTHON || true)
    HAS_R=$(echo "$ENV_CHECKS" | grep -c HAS_R || true)

    BASE_PYTHON="${CONDA_ROOT}/bin/python"
    if [[ "$HAS_PYTHON" -gt 0 ]]; then
        PYTHON_PATH="${ENV_PREFIX}/bin/python"
        echo "  python: $PYTHON_PATH"
    else
        PYTHON_PATH="$BASE_PYTHON"
        echo "  python: $PYTHON_PATH (base — env has no Python)"
    fi
    if [[ "$HAS_R" -gt 0 ]]; then
        R_PATH="${ENV_PREFIX}/bin/R"
        echo "  R: $R_PATH"
    fi

    # Determine which server directory to use
    if [[ "$IDE" == "positron" ]]; then
        SERVER_DIR_NAME=".positron-server"
    else
        SERVER_DIR_NAME=".vscode-server"
    fi

    # Write Machine settings.json with conda paths.
    # VS Code reads ~/.vscode-server/data/Machine/settings.json for remote
    # machine-level settings. Positron reads ~/.positron-server/data/Machine/settings.json.
    # This tells the Python/R extensions where to find interpreters and conda,
    # and enables terminal auto-activation via a custom profile.
    #
    # Build the settings JSON dynamically based on IDE and env contents.
    SETTINGS_ENTRIES=""
    SETTINGS_ENTRIES="${SETTINGS_ENTRIES}    \"python.defaultInterpreterPath\": \"${PYTHON_PATH}\",\n"
    SETTINGS_ENTRIES="${SETTINGS_ENTRIES}    \"python.condaPath\": \"${CONDA_EXE_PATH}\",\n"
    SETTINGS_ENTRIES="${SETTINGS_ENTRIES}    \"python.terminal.activateEnvironment\": true,\n"

    # Positron R interpreter settings
    if [[ "$IDE" == "positron" && "$HAS_R" -gt 0 ]]; then
        SETTINGS_ENTRIES="${SETTINGS_ENTRIES}    \"positron.r.interpreters.default\": \"${R_PATH}\",\n"
        SETTINGS_ENTRIES="${SETTINGS_ENTRIES}    \"positron.r.customBinaries\": [\"${R_PATH}\"],\n"
    fi

    SETTINGS_ENTRIES="${SETTINGS_ENTRIES}    \"terminal.integrated.profiles.linux\": {\n"
    SETTINGS_ENTRIES="${SETTINGS_ENTRIES}        \"conda-bash\": {\n"
    SETTINGS_ENTRIES="${SETTINGS_ENTRIES}            \"path\": \"bash\",\n"
    SETTINGS_ENTRIES="${SETTINGS_ENTRIES}            \"args\": [\"--init-file\", \"/tmp/torch-conda-init.sh\"]\n"
    SETTINGS_ENTRIES="${SETTINGS_ENTRIES}        }\n"
    SETTINGS_ENTRIES="${SETTINGS_ENTRIES}    },\n"
    SETTINGS_ENTRIES="${SETTINGS_ENTRIES}    \"terminal.integrated.defaultProfile.linux\": \"conda-bash\""

    # Write the settings JSON to a local temp file, then include it in the setup script
    SETTINGS_JSON=$(mktemp)
    {
        echo "{"
        echo -e "$SETTINGS_ENTRIES"
        echo "}"
    } > "$SETTINGS_JSON"

    # Build the conda init script content
    INIT_SCRIPT="# Source system profile for module/slurm commands
[ -f /etc/profile ] && . /etc/profile
# Source user bashrc for any custom settings
[ -f ~/.bashrc ] && . ~/.bashrc
# Activate conda environment
. ${CONDA_ROOT}/etc/profile.d/conda.sh 2>/dev/null || true
conda activate ${CONDA_ENV} 2>/dev/null || true"

    SETUP_SCRIPT=$(mktemp)
    cat > "$SETUP_SCRIPT" <<LOCALEOF
#!/bin/bash
SERVER_DIR="\$HOME/${SERVER_DIR_NAME}"
SETTINGS_DIR="\$SERVER_DIR/data/Machine"
mkdir -p "\$SETTINGS_DIR"

# Write Machine settings
cat > "\$SETTINGS_DIR/settings.json" <<'SETTINGSEOF'
$(cat "$SETTINGS_JSON")
SETTINGSEOF

# Write terminal init script
cat > /tmp/torch-conda-init.sh <<'INITEOF'
${INIT_SCRIPT}
INITEOF

# Clean up legacy blocks from previous approaches
sed -i '/# >>> torch-conda-env >>>/,/# <<< torch-conda-env <<</d' ~/.bashrc 2>/dev/null || true
sed -i '/# >>> torch-conda-env >>>/,/# <<< torch-conda-env <<</d' ~/.bash_profile 2>/dev/null || true
sed -i '/# >>> torch-conda-env >>>/,/# <<< torch-conda-env <<</d' "\$SERVER_DIR/server-env-setup" 2>/dev/null || true
LOCALEOF
    rm -f "$SETTINGS_JSON"

    SETUP_RC=0
    scp -q "$SETUP_SCRIPT" torch-compute:/tmp/torch-conda-setup.sh 2>&1 || {
        SETUP_RC=$?
        echo -e "\033[1;31mFailed to copy conda setup script to compute node (scp exit $SETUP_RC).\033[0m"
        rm -f "$SETUP_SCRIPT"
        exit 1
    }
    SETUP_RC=0
    ssh torch-compute "bash /tmp/torch-conda-setup.sh && rm -f /tmp/torch-conda-setup.sh" 2>/dev/null || SETUP_RC=$?
    rm -f "$SETUP_SCRIPT"

    if [[ $SETUP_RC -ne 0 ]]; then
        echo -e "\033[1;31mFailed to write conda settings to compute node.\033[0m"
        exit 1
    fi

    # Verify settings were written
    if ssh torch-compute "[ -f ~/${SERVER_DIR_NAME}/data/Machine/settings.json ]" 2>/dev/null; then
        echo -e "\033[1;32mConda environment configured: $CONDA_ENV\033[0m"
    else
        echo -e "\033[1;33mWarning: failed to write conda settings.\033[0m"
    fi

    # Kill any stale VS Code / Positron server processes so the IDE launches a
    # fresh server that reads the new settings.
    ssh torch-compute "pkill -f '\.vscode-server.*node' 2>/dev/null; pkill -f '\.positron-server.*node' 2>/dev/null" || true
fi

# =============================================================================
# Step 7: Launch IDE

# =============================================================================
# --- Helper: find a CLI by name, checking PATH and common install locations ---
_find_cli() {
    local name="$1"
    shift
    # Check PATH first
    if command -v "$name" >/dev/null 2>&1; then
        echo "$(command -v "$name")"
        return 0
    fi
    # Check each candidate path provided
    for candidate in "$@"; do
        if [[ -x "$candidate" ]]; then
            echo "$candidate"
            return 0
        fi
    done
    return 1
}

_install_cli_symlink() {
    local name="$1"
    local bundle_bin="$2"
    local symlink_path="/usr/local/bin/$name"
    if [[ -x "$bundle_bin" && ! -e "$symlink_path" ]]; then
        ln -sf "$bundle_bin" "$symlink_path" 2>/dev/null || true
    fi
}

_launch_vscode() {
    local uri="vscode-remote://ssh-remote+torch-compute${WORK_DIR}"
    
    # Auto-install CLI symlink if app bundle exists but CLI is missing
    for bundle in \
        "/Applications/Visual Studio Code.app/Contents/Resources/app/bin/code" \
        "$HOME/Applications/Visual Studio Code.app/Contents/Resources/app/bin/code"
    do
        if [[ -x "$bundle" ]]; then
            _install_cli_symlink "code" "$bundle"
            break
        fi
    done
    
    local code_cli
    code_cli=$(_find_cli code \
        "/usr/local/bin/code" \
        "/opt/homebrew/bin/code" \
        "/Applications/Visual Studio Code.app/Contents/Resources/app/bin/code" \
        "$HOME/Applications/Visual Studio Code.app/Contents/Resources/app/bin/code")
    if [[ -n "$code_cli" ]]; then
        echo -e "\033[1;32mLaunching VS Code...\033[0m"
        "$code_cli" --folder-uri "$uri"
    else
        echo -e "\033[1;33mVS Code not found.\033[0m"
        echo "Install VS Code: brew install --cask visual-studio-code"
        echo
        echo "To connect manually once installed:"
        echo "  code --folder-uri \"$uri\""
    fi
    echo -e "To reconnect: \033[1;33mcode --folder-uri \"$uri\"\033[0m"
}

_launch_positron() {
    local uri="vscode-remote://ssh-remote+torch-compute${WORK_DIR}"
    
    # Auto-install CLI symlink if app bundle exists but CLI is missing
    for bundle in \
        "/Applications/Positron.app/Contents/Resources/app/bin/positron" \
        "$HOME/Applications/Positron.app/Contents/Resources/app/bin/positron"
    do
        if [[ -x "$bundle" ]]; then
            _install_cli_symlink "positron" "$bundle"
            break
        fi
    done
    
    local positron_cli
    positron_cli=$(_find_cli positron \
        "/usr/local/bin/positron" \
        "/opt/homebrew/bin/positron" \
        "/Applications/Positron.app/Contents/Resources/app/bin/positron" \
        "$HOME/Applications/Positron.app/Contents/Resources/app/bin/positron")
    if [[ -n "$positron_cli" ]]; then
        echo -e "\033[1;32mLaunching Positron...\033[0m"
        "$positron_cli" --folder-uri "$uri"
    else
        echo -e "\033[1;33mPositron not found.\033[0m"
        echo "Install Positron from: https://positron.posit.co/download.html"
        echo
        echo "To connect manually once Positron is open:"
        echo "  Command Palette → Remote SSH: Connect to Host → torch-compute"
        echo "  Then open: $WORK_DIR"
    fi
    echo -e "To reconnect manually: open Positron → Remote Explorer → torch-compute"
}

if [[ "$IDE" == "positron" ]]; then
    _launch_positron
elif [[ "$IDE" == "none" ]]; then
    echo -e "\033[1;32mNode ready. No IDE launched.\033[0m"
    echo "SSH host: torch-compute"
else
    _launch_vscode
fi

echo
echo -e "\033[1;34mSession info:\033[0m"
echo -e "  Job ID:        \033[1;33m$JOB_ID\033[0m"
echo -e "  Compute node:  \033[1;33m$COMPUTE_NODE\033[0m"
echo -e "  Access:        \033[1;33mlocalhost:$TUNNEL_PORT -> $COMPUTE_NODE\033[0m"
echo -e "  Work dir:      \033[1;33m$WORK_DIR\033[0m"
echo -e "  Time limit:    \033[1;33m${TIME_HOURS}h\033[0m"
echo -e "  IDE:           \033[1;33m$IDE\033[0m"
echo -e "  Conda env:    \033[1;33m${CONDA_ENV:-none}\033[0m"
echo
echo -e "To cancel job:   \033[1;33mssh torch 'scancel $JOB_ID'\033[0m"
echo -e "To close session: \033[1;33mssh -O exit torch\033[0m"

SCRIPT_SUCCESS=true
