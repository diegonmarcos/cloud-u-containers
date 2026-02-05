#!/bin/sh
# Cloud Infrastructure - Nix Flake Build & Deploy Script
# Builds Docker Compose configs and deploys to VMs via SSH
# Configuration loaded from config.json
set -e

# =============================================================================
# Configuration
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CONFIG_FILE="$SCRIPT_DIR/config.json"

# Age key for sops decryption
: "${SOPS_AGE_KEY_FILE:=/home/diego/Mounts/Git/vault/A0_keys/age/keys.txt}"
export SOPS_AGE_KEY_FILE

# =============================================================================
# Dependency Management
# =============================================================================

# Required dependencies with descriptions
DEPS_REQUIRED="jq:JSON processor for config parsing
nix:Nix package manager for building flakes
rsync:File sync for deploying to VMs
ssh:SSH client for remote commands"

# Optional dependencies
DEPS_OPTIONAL="sops:Secret encryption/decryption (mozilla/sops)
yq:YAML processor for secrets conversion
gcloud:Google Cloud CLI (for GCP VMs)
docker:Docker client (for local testing)"

# Check if a command exists
cmd_exists() {
    command -v "$1" >/dev/null 2>&1
}

# Get version of a command (best effort)
get_version() {
    cmd="$1"
    case "$cmd" in
        jq)      jq --version 2>/dev/null | head -1 ;;
        nix)     nix --version 2>/dev/null | head -1 ;;
        rsync)   rsync --version 2>/dev/null | head -1 ;;
        ssh)     ssh -V 2>&1 | head -1 ;;
        sops)    sops --version 2>/dev/null | head -1 ;;
        yq)      yq --version 2>/dev/null | head -1 ;;
        gcloud)  gcloud --version 2>/dev/null | head -1 ;;
        docker)  docker --version 2>/dev/null | head -1 ;;
        *)       echo "unknown" ;;
    esac
}

# Check all dependencies
check_deps() {
    missing_required=0
    missing_optional=0

    # Check required
    echo "$DEPS_REQUIRED" | while IFS=: read -r cmd desc; do
        if ! cmd_exists "$cmd"; then
            log_error "Required: $cmd - $desc"
            missing_required=1
        fi
    done

    if [ "$missing_required" = "1" ]; then
        echo ""
        log_error "Missing required dependencies. Install them first."
        echo "  NixOS:  nix-shell -p jq rsync openssh"
        echo "  Ubuntu: apt install jq rsync openssh-client"
        echo "  Arch:   pacman -S jq rsync openssh"
        exit 1
    fi

    if [ ! -f "$CONFIG_FILE" ]; then
        log_error "Config file not found: $CONFIG_FILE"
        exit 1
    fi
}

# Show dependency status
cmd_deps() {
    echo ""
    echo "=== Required Dependencies ==="
    echo "$DEPS_REQUIRED" | while IFS=: read -r cmd desc; do
        if cmd_exists "$cmd"; then
            version=$(get_version "$cmd")
            printf "  ✓ %-10s %s\n" "$cmd" "$version"
        else
            printf "  ✗ %-10s MISSING - %s\n" "$cmd" "$desc"
        fi
    done

    echo ""
    echo "=== Optional Dependencies ==="
    echo "$DEPS_OPTIONAL" | while IFS=: read -r cmd desc; do
        if cmd_exists "$cmd"; then
            version=$(get_version "$cmd")
            printf "  ✓ %-10s %s\n" "$cmd" "$version"
        else
            printf "  ○ %-10s not installed - %s\n" "$cmd" "$desc"
        fi
    done

    echo ""
    echo "=== Configuration ==="
    printf "  %-20s %s\n" "Config file:" "$CONFIG_FILE"
    printf "  %-20s %s\n" "SSH key:" "$SSH_KEY"

    echo ""
    echo "=== Age/SOPS Encryption ==="
    printf "  %-20s %s\n" "Private key path:" "$SOPS_AGE_KEY_FILE"
    if [ -f "$SOPS_AGE_KEY_FILE" ]; then
        printf "  %-20s %s\n" "Private key:" "✓ Found"
        # Extract public key from file
        pub_key=$(grep "^# public key:" "$SOPS_AGE_KEY_FILE" 2>/dev/null | cut -d: -f2 | tr -d ' ')
        if [ -n "$pub_key" ]; then
            printf "  %-20s %s\n" "Public key:" "$pub_key"
        fi
    else
        printf "  %-20s %s\n" "Private key:" "✗ NOT FOUND"
        echo ""
        echo "  WARNING: Secrets cannot be decrypted without the age key!"
        echo "  Set path with: ./build.sh --key /path/to/keys.txt <command>"
    fi

    printf "  %-20s %s\n" "SOPS config:" "$SCRIPT_DIR/.sops.yaml"

    echo ""
    echo "=== Installation Help ==="
    echo "  NixOS/nix-shell:"
    echo "    nix-shell -p jq yq-go sops age rsync openssh google-cloud-sdk"
    echo ""
    echo "  Ubuntu/Debian:"
    echo "    apt install jq rsync openssh-client"
    echo "    # sops: https://github.com/getsops/sops/releases"
    echo "    # yq:   https://github.com/mikefarah/yq/releases"
    echo ""
    echo "  Arch Linux:"
    echo "    pacman -S jq rsync openssh sops"
    echo "    yay -S yq-bin"
    echo ""
}

# Load config values
load_config() {
    SSH_KEY=$(jq -r '.ssh_key' "$CONFIG_FILE")
    REMOTE_BASE=$(jq -r '.remote_base' "$CONFIG_FILE")
}

# =============================================================================
# Helper Functions
# =============================================================================

usage() {
    cat <<'EOF'
╔══════════════════════════════════════════════════════════════════════════════╗
║                    Container-Nix Build & Deploy System                       ║
╚══════════════════════════════════════════════════════════════════════════════╝

USAGE:
    ./build.sh <command> [options] [arguments]

COMMANDS:
    Building & Deploying:
        build [service]         Build Nix flakes locally
        deploy [service]        Build, inject secrets, and deploy to VM

    Infrastructure:
        list                    List all services with their VMs
        vms                     List all VMs with connection info
        ssh <vm>                SSH into a VM
        status <vm>             Show Docker container status on VM
        restart <service>       Restart a service (docker compose down/up)

    Secrets Management:
        secrets                 List services with secrets
        secrets <svc> encrypt   Encrypt service secrets.yaml with sops/age
        secrets <svc> decrypt   Decrypt to .env file (for testing)
        secrets <svc> edit      Edit encrypted secrets (sops edit)
        secrets <svc> show      Display decrypted secrets

    System:
        deps                    Check dependencies and show install help
        help                    Show this help message

OPTIONS:
    -n, --dry-run       Show what would be done without executing
    -v, --verbose       Enable verbose output (set -x)
    -k, --key <path>    Override age key path for sops decrypt
    -h, --help          Show this help

ENCRYPTION:
    Age key (private):  /home/diego/Mounts/Git/vault/A0_keys/age/keys.txt
    Age key (public):   age1u575hx8h4t5cgle2uznmyfy75e7cgd02h9t5dax506luz9e05vlqxtd7pq

    Override key path:
        ./build.sh --key /path/to/keys.txt secrets authelia decrypt
        SOPS_AGE_KEY_FILE=/path/to/keys.txt ./build.sh deploy authelia

EXAMPLES:
    # First time setup
    ./build.sh deps                         # Check dependencies
    ./build.sh secrets authelia edit        # Add real secrets
    ./build.sh secrets authelia encrypt     # Encrypt before committing

    # Building
    ./build.sh build                        # Build all services
    ./build.sh build authelia               # Build single service

    # Deploying
    ./build.sh deploy authelia              # Deploy single service
    ./build.sh deploy                       # Deploy everything
    ./build.sh -n deploy authelia           # Dry-run (show what would happen)

    # Managing VMs
    ./build.sh vms                          # List all VMs
    ./build.sh ssh gcp-f-micro_1            # SSH into GCP VM
    ./build.sh status oci-f-micro_1         # Check containers on Oracle VM

    # Service management
    ./build.sh restart photoprism           # Restart photoprism
    ./build.sh list                         # Show service → VM mapping

WORKFLOW:
    1. Edit secrets:     ./build.sh secrets <service> edit
    2. Encrypt:          ./build.sh secrets <service> encrypt
    3. Deploy:           ./build.sh deploy <service>
    4. Verify:           ./build.sh status <vm>

FILES:
    config.json         VM and service configuration
    .sops.yaml          SOPS encryption rules (age key)
    <service>/
      ├── flake.nix     Nix flake (generates docker-compose.yml)
      └── secrets.yaml  Encrypted secrets (→ .env at deploy)

EOF
    exit 0
}

log() {
    printf "[%s] %s\n" "$(date '+%H:%M:%S')" "$1"
}

log_error() {
    printf "[%s] ERROR: %s\n" "$(date '+%H:%M:%S')" "$1" >&2
}

# Get VM property from config
get_vm_prop() {
    vm_name="$1"
    prop="$2"
    jq -r ".vms[\"$vm_name\"].$prop // empty" "$CONFIG_FILE"
}

# Get service property from config
get_svc_prop() {
    svc_name="$1"
    prop="$2"
    jq -r ".services[\"$svc_name\"].$prop // empty" "$CONFIG_FILE"
}

# Get all VM names
get_all_vms() {
    jq -r '.vms | keys[]' "$CONFIG_FILE"
}

# Get all service names
get_all_services() {
    jq -r '.services | keys[]' "$CONFIG_FILE"
}

# Get folder name for a service
get_service_folder() {
    service="$1"
    category=$(get_svc_prop "$service" "category")
    flake=$(get_svc_prop "$service" "flake")

    # Use flake name if specified, otherwise service name
    base_name="${flake:-$service}"

    # Map category to folder prefix (new naming convention)
    case "$category" in
        app)    echo "aa-sui_${base_name}" ;;
        tools)  echo "bc-obs_${base_name}" ;;
        sec)    echo "bb-sec_${base_name}" ;;
        cloud)  echo "ba-clo_${base_name}" ;;
        data)   echo "ca-dat_${base_name}" ;;
        *)      echo "$base_name" ;;
    esac
}

# SSH into a VM
ssh_cmd() {
    vm_name="$1"
    shift
    cmd="$*"

    method=$(get_vm_prop "$vm_name" "method")
    if [ -z "$method" ]; then
        log_error "Unknown VM: $vm_name"
        return 1
    fi

    ip=$(get_vm_prop "$vm_name" "ip")
    user=$(get_vm_prop "$vm_name" "user")

    if [ "$method" = "gcloud" ]; then
        instance=$(get_vm_prop "$vm_name" "gcloud_instance")
        zone=$(get_vm_prop "$vm_name" "gcloud_zone")
        if [ -n "$cmd" ]; then
            gcloud compute ssh "$user@$instance" --zone "$zone" --command "$cmd"
        else
            gcloud compute ssh "$user@$instance" --zone "$zone"
        fi
    else
        if [ -n "$cmd" ]; then
            ssh -i "$SSH_KEY" -o StrictHostKeyChecking=accept-new "$user@$ip" "$cmd"
        else
            ssh -i "$SSH_KEY" -o StrictHostKeyChecking=accept-new "$user@$ip"
        fi
    fi
}

# Rsync files to a VM
rsync_to_vm() {
    vm_name="$1"
    src="$2"
    dest="$3"

    method=$(get_vm_prop "$vm_name" "method")
    ip=$(get_vm_prop "$vm_name" "ip")
    user=$(get_vm_prop "$vm_name" "user")

    if [ "$method" = "gcloud" ]; then
        instance=$(get_vm_prop "$vm_name" "gcloud_instance")
        zone=$(get_vm_prop "$vm_name" "gcloud_zone")
        gcloud compute scp --recurse "$src" "$user@$instance:$dest" --zone "$zone"
    else
        rsync -avz --delete -e "ssh -i $SSH_KEY -o StrictHostKeyChecking=accept-new" \
            "$src" "$user@$ip:$dest"
    fi
}

# Decrypt service secrets.yaml to .env
decrypt_service_secrets() {
    service="$1"
    folder=$(get_service_folder "$service")
    secrets_file="$SCRIPT_DIR/$folder/secrets.yaml"
    env_file="$SCRIPT_DIR/$folder/.env"

    if [ ! -f "$secrets_file" ]; then
        # No secrets for this service
        return 0
    fi

    if ! command -v sops >/dev/null 2>&1; then
        log "Warning: sops not found, copying secrets as-is"
        # Convert YAML to .env format
        if command -v yq >/dev/null 2>&1; then
            yq -r 'to_entries | .[] | "\(.key)=\(.value)"' "$secrets_file" > "$env_file"
        fi
        return 0
    fi

    # Check if encrypted
    if grep -q "sops:" "$secrets_file" 2>/dev/null; then
        log "Decrypting secrets for $service..."
        sops -d "$secrets_file" | yq -r 'to_entries | .[] | "\(.key)=\(.value)"' > "$env_file"
    else
        log "Warning: $service secrets not encrypted"
        yq -r 'to_entries | .[] | "\(.key)=\(.value)"' "$secrets_file" > "$env_file"
    fi
}

# =============================================================================
# Commands
# =============================================================================

cmd_build() {
    service="$1"

    cd "$SCRIPT_DIR"

    if [ -n "$service" ]; then
        # Get the flake name (may differ from service name for syslog-*)
        flake=$(get_svc_prop "$service" "flake")
        flake_name="${flake:-$service}"

        log "Building $flake_name..."
        nix build ".#$flake_name" --out-link "result-$flake_name"
        log "Built: result-$flake_name"
    else
        log "Building all services..."
        nix build ".#all" --out-link "result"
        log "Built: result/"
    fi
}

cmd_deploy() {
    service="$1"

    cd "$SCRIPT_DIR"

    if [ -n "$service" ]; then
        deploy_service "$service"
    else
        log "Deploying all services..."
        get_all_services | while read -r svc; do
            deploy_service "$svc"
        done
    fi
}

deploy_service() {
    service="$1"

    vm=$(get_svc_prop "$service" "vm")
    if [ -z "$vm" ]; then
        log_error "No VM configured for service: $service"
        return 1
    fi

    # Skip local-only services (terraform)
    if [ "$vm" = "local" ]; then
        log "Skipping $service (local-only)"
        return 0
    fi

    subfolder=$(get_svc_prop "$service" "subfolder")
    flake=$(get_svc_prop "$service" "flake")
    flake_name="${flake:-$service}"
    folder=$(get_service_folder "$service")

    # 1. Build the flake
    log "Building $flake_name..."
    nix build ".#$flake_name" --out-link "result-$flake_name"

    # 2. Decrypt secrets to .env
    decrypt_service_secrets "$service"

    # 3. Prepare deploy directory
    deploy_dir="$SCRIPT_DIR/.deploy-$service"
    rm -rf "$deploy_dir"

    # Determine source path
    if [ -n "$subfolder" ]; then
        src_path="$SCRIPT_DIR/result-$flake_name/$subfolder"
    else
        src_path="$SCRIPT_DIR/result-$flake_name"
    fi

    # Copy built files (dereferencing symlinks)
    cp -rL "$src_path" "$deploy_dir"
    chmod -R u+w "$deploy_dir"

    # 4. Add .env if it exists
    if [ -f "$SCRIPT_DIR/$folder/.env" ]; then
        cp "$SCRIPT_DIR/$folder/.env" "$deploy_dir/.env"
        log "Added .env for $service"
    fi

    remote_name="$service"

    log "Deploying $service to $vm..."

    if [ "$DRY_RUN" = "1" ]; then
        log "[DRY-RUN] Would sync $deploy_dir to $vm:$REMOTE_BASE/$remote_name/"
    else
        # Create remote directory
        ssh_cmd "$vm" "sudo mkdir -p $REMOTE_BASE/$remote_name && sudo chown \$(whoami):\$(whoami) $REMOTE_BASE/$remote_name"

        # Sync files
        rsync_to_vm "$vm" "$deploy_dir/" "$REMOTE_BASE/$remote_name/"
        log "Deployed $service to $vm:$REMOTE_BASE/$remote_name/"

        # Clean up
        rm -rf "$deploy_dir"
        rm -f "$SCRIPT_DIR/$folder/.env"
    fi
}

cmd_list() {
    printf "\n%-25s %-8s %-15s %-20s %s\n" "SERVICE" "TYPE" "VM" "IP" "DESCRIPTION"
    printf "%s\n" "-------------------------------------------------------------------------------------"

    get_all_services | while read -r svc; do
        category=$(get_svc_prop "$svc" "category")
        vm=$(get_svc_prop "$svc" "vm")
        desc=$(get_svc_prop "$svc" "description")
        ip=$(get_vm_prop "$vm" "ip")
        printf "%-25s %-8s %-15s %-20s %s\n" "$svc" "$category" "$vm" "$ip" "$desc"
    done | sort

    printf "\n"
}

cmd_vms() {
    printf "\n%-15s %-20s %-10s %-10s %s\n" "VM" "IP" "USER" "METHOD" "DESCRIPTION"
    printf "%s\n" "--------------------------------------------------------------------------------"

    get_all_vms | while read -r vm; do
        ip=$(get_vm_prop "$vm" "ip")
        user=$(get_vm_prop "$vm" "user")
        method=$(get_vm_prop "$vm" "method")
        desc=$(get_vm_prop "$vm" "description")
        printf "%-15s %-20s %-10s %-10s %s\n" "$vm" "$ip" "$user" "$method" "$desc"
    done

    printf "\n"
}

cmd_ssh() {
    vm_name="$1"
    if [ -z "$vm_name" ]; then
        log_error "VM name required. Available VMs:"
        get_all_vms | while read -r vm; do
            printf "  - %s\n" "$vm"
        done
        exit 1
    fi

    log "Connecting to $vm_name..."
    ssh_cmd "$vm_name"
}

cmd_restart() {
    service="$1"
    if [ -z "$service" ]; then
        log_error "Service name required"
        usage
    fi

    vm=$(get_svc_prop "$service" "vm")
    if [ -z "$vm" ]; then
        log_error "Unknown service: $service"
        return 1
    fi

    log "Restarting $service on $vm..."
    ssh_cmd "$vm" "cd $REMOTE_BASE/$service && docker compose down && docker compose up -d"
    log "Restarted $service"
}

cmd_status() {
    vm_name="$1"
    if [ -z "$vm_name" ]; then
        log_error "VM name required"
        exit 1
    fi

    log "Docker status on $vm_name:"
    ssh_cmd "$vm_name" "docker ps --format 'table {{.Names}}\t{{.Status}}\t{{.Ports}}'"
}

cmd_secrets() {
    service="$1"
    action="$2"

    if [ -z "$service" ]; then
        echo ""
        echo "=== Secrets Status ==="
        printf "  %-25s %-12s %s\n" "SERVICE" "STATUS" "FILE"
        printf "  %s\n" "------------------------------------------------------------"

        for folder in "$SCRIPT_DIR"/*/; do
            secrets_file="$folder/secrets.yaml"
            if [ -f "$secrets_file" ]; then
                svc_name=$(basename "$folder")
                if grep -q "sops:" "$secrets_file" 2>/dev/null; then
                    status="✓ encrypted"
                else
                    status="✗ PLAINTEXT"
                fi
                printf "  %-25s %-12s %s\n" "$svc_name" "$status" "secrets.yaml"
            fi
        done

        echo ""
        echo "=== Commands ==="
        echo "  ./build.sh secrets <service> encrypt   Encrypt secrets"
        echo "  ./build.sh secrets <service> decrypt   Decrypt to .env"
        echo "  ./build.sh secrets <service> edit      Edit (auto-decrypt/encrypt)"
        echo "  ./build.sh secrets <service> show      Display decrypted"
        echo "  ./build.sh secrets encrypt-all         Encrypt all plaintext secrets"
        echo ""
        exit 0
    fi

    # Handle encrypt-all special case
    if [ "$service" = "encrypt-all" ]; then
        log "Encrypting all plaintext secrets..."
        encrypted=0
        for folder in "$SCRIPT_DIR"/*/; do
            secrets_file="$folder/secrets.yaml"
            if [ -f "$secrets_file" ]; then
                if ! grep -q "sops:" "$secrets_file" 2>/dev/null; then
                    svc_name=$(basename "$folder")
                    log "Encrypting $svc_name..."
                    sops -e -i "$secrets_file"
                    encrypted=$((encrypted + 1))
                fi
            fi
        done
        log "Encrypted $encrypted secrets files"
        exit 0
    fi

    folder=$(get_service_folder "$service")
    secrets_file="$SCRIPT_DIR/$folder/secrets.yaml"

    if [ ! -f "$secrets_file" ]; then
        log_error "No secrets.yaml found for $service"
        log_error "Expected: $secrets_file"
        echo ""
        echo "Services with secrets:"
        for f in "$SCRIPT_DIR"/*/secrets.yaml; do
            [ -f "$f" ] && basename "$(dirname "$f")"
        done | sort | sed 's/^/  /'
        exit 1
    fi

    case "$action" in
        encrypt)
            if grep -q "sops:" "$secrets_file" 2>/dev/null; then
                log "$service secrets already encrypted"
            else
                if ! cmd_exists sops; then
                    log_error "sops not installed. Run './build.sh deps' for install help."
                    exit 1
                fi
                log "Encrypting $service secrets..."
                sops -e -i "$secrets_file"
                log "Encrypted: $secrets_file"
            fi
            ;;
        decrypt)
            decrypt_service_secrets "$service"
            log "Decrypted to: $SCRIPT_DIR/$folder/.env"
            ;;
        edit)
            if ! cmd_exists sops; then
                log_error "sops not installed. Run './build.sh deps' for install help."
                exit 1
            fi
            log "Editing $service secrets..."
            sops "$secrets_file"
            ;;
        show)
            if grep -q "sops:" "$secrets_file" 2>/dev/null; then
                if ! cmd_exists sops; then
                    log_error "sops not installed - cannot decrypt"
                    exit 1
                fi
                sops -d "$secrets_file"
            else
                echo "# WARNING: File is not encrypted!"
                cat "$secrets_file"
            fi
            ;;
        "")
            # No action - show status for this service
            echo ""
            echo "=== $service secrets ==="
            if grep -q "sops:" "$secrets_file" 2>/dev/null; then
                echo "Status: ✓ Encrypted"
                echo "File:   $secrets_file"
                echo ""
                echo "Keys:"
                sops -d "$secrets_file" 2>/dev/null | grep -v "^#" | grep -v "^$" | cut -d: -f1 | sed 's/^/  /'
            else
                echo "Status: ✗ PLAINTEXT (run: ./build.sh secrets $service encrypt)"
                echo "File:   $secrets_file"
                echo ""
                echo "Keys:"
                grep -v "^#" "$secrets_file" | grep -v "^$" | cut -d: -f1 | sed 's/^/  /'
            fi
            echo ""
            ;;
        *)
            log_error "Unknown action: $action"
            echo "Actions: encrypt, decrypt, edit, show"
            exit 1
            ;;
    esac
}

# =============================================================================
# Main
# =============================================================================

DRY_RUN=0
VERBOSE=0

# Parse global options
while [ $# -gt 0 ]; do
    case "$1" in
        -n|--dry-run)
            DRY_RUN=1
            shift
            ;;
        -v|--verbose)
            VERBOSE=1
            set -x
            shift
            ;;
        -k|--key)
            if [ -z "$2" ] || [ "${2#-}" != "$2" ]; then
                log_error "--key requires a path argument"
                exit 1
            fi
            SOPS_AGE_KEY_FILE="$2"
            export SOPS_AGE_KEY_FILE
            log "Using age key: $SOPS_AGE_KEY_FILE"
            shift 2
            ;;
        -h|--help)
            usage
            ;;
        -*)
            log_error "Unknown option: $1"
            echo "Run '$0 help' for usage information."
            exit 1
            ;;
        *)
            break
            ;;
    esac
done

command="${1:-}"
shift 2>/dev/null || true

# Initialize
check_deps
load_config

case "$command" in
    build)
        cmd_build "$@"
        ;;
    deploy)
        cmd_deploy "$@"
        ;;
    list)
        cmd_list
        ;;
    vms)
        cmd_vms
        ;;
    ssh)
        cmd_ssh "$@"
        ;;
    restart)
        cmd_restart "$@"
        ;;
    status)
        cmd_status "$@"
        ;;
    secrets)
        cmd_secrets "$@"
        ;;
    deps|check)
        cmd_deps
        ;;
    ""|help|-h|--help)
        usage
        ;;
    *)
        log_error "Unknown command: $command"
        echo "Run '$0 help' for usage information."
        exit 1
        ;;
esac
