#!/usr/bin/env bash
#
# encrypt.sh - Manage SOPS encryption for all cloud service secrets
#
# Usage:
#   ./encrypt.sh encrypt [AGE_KEY_FILE]  # Encrypt all secrets.yaml files
#   ./encrypt.sh decrypt [AGE_KEY_FILE]  # Generate .env files from encrypted secrets.yaml (safe!)
#   ./encrypt.sh status                  # Show encryption status of all secrets
#   ./encrypt.sh list                    # List all secrets.yaml files
#   ./encrypt.sh check                   # CI-friendly: Check all secrets are encrypted (exit 1 if not)
#
# Environment:
#   SOPS_AGE_KEY_FILE - Path to age private key (default: vault location)
#   CI                - Set to 'true' for CI mode (exits with error codes)
#
# Exit codes:
#   0 - Success
#   1 - General error
#   2 - SOPS not installed
#   3 - Age key not found
#   4 - Unencrypted secrets found (check mode)
#   5 - Encryption failed
#
set -euo pipefail

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Default age key location (symlinked from ~/.config/sops/age/keys.txt)
DEFAULT_AGE_KEY="/home/diego/Mounts/Git/vault/A0_keys/system/oauth/age_keys.txt"

# Script directory (where secrets live)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# CI mode detection
IS_CI="${CI:-false}"

# Check if required tools are installed
check_dependencies() {
    local missing=()

    if ! command -v sops &>/dev/null; then
        missing+=("sops")
    fi

    if ! command -v age &>/dev/null; then
        missing+=("age")
    fi

    if [[ ${#missing[@]} -gt 0 ]]; then
        echo -e "${RED}Error: Missing required tools: ${missing[*]}${NC}" >&2
        echo "" >&2
        echo "Install them with:" >&2
        for tool in "${missing[@]}"; do
            case "$tool" in
                sops)
                    echo "  # SOPS (Secrets OPerationS)" >&2
                    echo "  curl -LO https://github.com/getsops/sops/releases/download/v3.8.1/sops-v3.8.1.linux.amd64" >&2
                    echo "  sudo mv sops-v3.8.1.linux.amd64 /usr/local/bin/sops" >&2
                    echo "  sudo chmod +x /usr/local/bin/sops" >&2
                    ;;
                age)
                    echo "  # age (encryption tool)" >&2
                    echo "  sudo apt install age   # Debian/Ubuntu" >&2
                    echo "  brew install age       # macOS" >&2
                    ;;
            esac
        done
        return 2
    fi
    return 0
}

# Find all secrets.yaml files (use command to bypass fd alias)
find_secrets() {
    command find "$SCRIPT_DIR" -name "secrets.yaml" -type f 2>/dev/null | sort
}

# Check if a file is encrypted with SOPS
is_encrypted() {
    local file="$1"
    # SOPS encrypted files have a 'sops:' key with metadata
    grep -q "^sops:" "$file" 2>/dev/null
}

# Check all secrets are encrypted (CI mode)
check_encryption() {
    if ! check_dependencies; then
        return $?
    fi

    echo -e "${BLUE}=== Checking Secrets Encryption ===${NC}\n"

    local unencrypted_files=()
    local encrypted=0
    local unencrypted=0

    while IFS= read -r file; do
        local rel_path="${file#$SCRIPT_DIR/}"
        if is_encrypted "$file"; then
            if [[ "$IS_CI" == "false" ]]; then
                echo -e "${GREEN}[ENCRYPTED]${NC} $rel_path"
            fi
            ((encrypted++)) || true
        else
            echo -e "${RED}[PLAINTEXT]${NC} $rel_path" >&2
            unencrypted_files+=("$rel_path")
            ((unencrypted++)) || true
        fi
    done < <(find_secrets)

    echo ""
    echo -e "${BLUE}Summary:${NC}"
    echo -e "  Encrypted: ${GREEN}$encrypted${NC}"

    if [[ $unencrypted -gt 0 ]]; then
        echo -e "  Plaintext: ${RED}$unencrypted${NC}" >&2
        echo "" >&2
        echo -e "${RED}ERROR: Found $unencrypted unencrypted secret file(s):${NC}" >&2
        for file in "${unencrypted_files[@]}"; do
            echo -e "  ${RED}✗${NC} $file" >&2
        done
        echo "" >&2
        echo -e "${YELLOW}Action required:${NC}" >&2
        echo -e "  Run: ${GREEN}./encrypt.sh encrypt${NC}" >&2
        echo "" >&2

        if [[ "$IS_CI" == "true" ]]; then
            echo -e "${RED}CI FAILURE: Secrets must be encrypted before push!${NC}" >&2
        fi

        return 4  # Exit code 4 = unencrypted secrets found
    fi

    echo -e "${GREEN}✓ All secrets are encrypted${NC}"
    return 0
}

# Show status of all secrets files
show_status() {
    echo -e "${BLUE}=== Secrets Encryption Status ===${NC}\n"

    local encrypted=0
    local unencrypted=0

    while IFS= read -r file; do
        local rel_path="${file#$SCRIPT_DIR/}"
        if is_encrypted "$file"; then
            echo -e "${GREEN}[ENCRYPTED]${NC} $rel_path"
            ((encrypted++)) || true
        else
            echo -e "${RED}[PLAINTEXT]${NC} $rel_path"
            ((unencrypted++)) || true
        fi
    done < <(find_secrets)

    echo ""
    echo -e "${BLUE}Summary:${NC}"
    echo -e "  Encrypted: ${GREEN}$encrypted${NC}"
    echo -e "  Plaintext: ${RED}$unencrypted${NC}"

    if [[ $unencrypted -gt 0 ]]; then
        echo ""
        echo -e "${YELLOW}Warning: $unencrypted file(s) contain plaintext secrets!${NC}"
        echo -e "Run '${GREEN}./encrypt.sh encrypt${NC}' to encrypt them."
    fi
    return 0
}

# List all secrets files
list_secrets() {
    echo -e "${BLUE}=== All secrets.yaml files ===${NC}\n"

    while IFS= read -r file; do
        echo "${file#$SCRIPT_DIR/}"
    done < <(find_secrets)
}

# Encrypt all unencrypted secrets files
encrypt_all() {
    if ! check_dependencies; then
        exit $?
    fi

    local age_key="${1:-${SOPS_AGE_KEY_FILE:-$DEFAULT_AGE_KEY}}"

    if [[ ! -f "$age_key" ]]; then
        echo -e "${RED}Error: Age key file not found: $age_key${NC}" >&2
        echo "" >&2
        echo "Please provide the age key file:" >&2
        echo "  ./encrypt.sh encrypt /path/to/age-key.txt" >&2
        echo "" >&2
        echo "Or set SOPS_AGE_KEY_FILE environment variable" >&2
        return 3
    fi

    export SOPS_AGE_KEY_FILE="$age_key"

    echo -e "${BLUE}=== Encrypting secrets ===${NC}"
    echo -e "Using age key: ${YELLOW}$age_key${NC}\n"

    local encrypted=0
    local skipped=0
    local failed=0

    while IFS= read -r file; do
        local rel_path="${file#$SCRIPT_DIR/}"

        if is_encrypted "$file"; then
            echo -e "${YELLOW}[SKIP]${NC} Already encrypted: $rel_path"
            ((skipped++)) || true
        else
            echo -n "Encrypting: $rel_path ... "
            if sops -e -i "$file" 2>/dev/null; then
                echo -e "${GREEN}OK${NC}"
                ((encrypted++)) || true
            else
                echo -e "${RED}FAILED${NC}"
                ((failed++)) || true
            fi
        fi
    done < <(find_secrets)

    echo ""
    echo -e "${BLUE}Summary:${NC}"
    echo -e "  Encrypted: ${GREEN}$encrypted${NC}"
    echo -e "  Skipped:   ${YELLOW}$skipped${NC}"

    if [[ $failed -gt 0 ]]; then
        echo -e "  Failed:    ${RED}$failed${NC}" >&2
        echo "" >&2
        echo -e "${RED}ERROR: Encryption failed for $failed file(s)${NC}" >&2
        return 5
    fi

    if [[ $encrypted -gt 0 ]]; then
        echo ""
        echo -e "${GREEN}✓ Successfully encrypted $encrypted file(s)${NC}"
    fi

    return 0
}

# URL-encode a string (for passwords in DATABASE_URL)
urlencode() {
    local string="${1}"
    local strlen=${#string}
    local encoded=""
    local pos c o

    for (( pos=0 ; pos<strlen ; pos++ )); do
        c=${string:$pos:1}
        case "$c" in
            [-_.~a-zA-Z0-9] ) o="${c}" ;;
            * ) printf -v o '%%%02X' "'$c"
        esac
        encoded+="${o}"
    done
    echo "${encoded}"
}

# Generate .env and secrets/*.txt files from secrets.yaml
generate_env_files() {
    local secrets_file="$1"
    local service_dir="$(dirname "$secrets_file")"
    local service_name="$(basename "$service_dir")"

    if ! is_encrypted "$secrets_file"; then
        echo -e "${YELLOW}[SKIP]${NC} Not encrypted: $secrets_file" >&2
        return 0
    fi

    # Decrypt to memory and parse
    local decrypted_content
    if ! decrypted_content=$(sops -d "$secrets_file" 2>/dev/null); then
        echo -e "${RED}[FAIL]${NC} Cannot decrypt: $secrets_file" >&2
        return 1
    fi

    # Create env directory if needed
    local env_dir="$service_dir/env"
    mkdir -p "$env_dir"

    # Create secrets directory if needed
    local secrets_dir="$service_dir/secrets"
    mkdir -p "$secrets_dir"

    # Parse YAML and generate .env file
    local env_file="$env_dir/${service_name}.env"
    local generated_count=0

    # Extract key-value pairs (simple YAML parser)
    while IFS=': ' read -r key value; do
        # Skip empty lines, comments, and SOPS metadata
        [[ -z "$key" ]] && continue
        [[ "$key" =~ ^#.* ]] && continue
        [[ "$key" == "sops" ]] && break  # Stop at SOPS metadata

        # Remove quotes from value
        value="${value#\"}"
        value="${value%\"}"

        # Write to .env file
        if [[ $generated_count -eq 0 ]]; then
            # First entry, create file with header
            cat > "$env_file" << EOF
# Auto-generated from secrets.yaml
# DO NOT EDIT - Changes will be overwritten
# Run: ./encrypt.sh decrypt to regenerate

EOF
        fi

        echo "${key}=${value}" >> "$env_file"

        # Special handling for DB_PASSWORD - also create secrets/db_password.txt
        if [[ "$key" == "DB_PASSWORD" && -n "$value" ]]; then
            echo "$value" > "$secrets_dir/db_password.txt"
            chmod 600 "$secrets_dir/db_password.txt"

            # Add URL-encoded version for DATABASE_URL
            local encoded_password=$(urlencode "$value")
            echo "DB_PASSWORD_URLENCODED=${encoded_password}" >> "$env_file"
        fi

        ((generated_count++)) || true
    done <<< "$decrypted_content"

    if [[ $generated_count -gt 0 ]]; then
        chmod 600 "$env_file"
        echo -e "${GREEN}  → Generated: ${env_file#$SCRIPT_DIR/}${NC}"
        [[ -f "$secrets_dir/db_password.txt" ]] && echo -e "${GREEN}  → Generated: ${secrets_dir#$SCRIPT_DIR/}/db_password.txt${NC}"
        return 0
    else
        echo -e "${YELLOW}  → No secrets found in: ${secrets_file#$SCRIPT_DIR/}${NC}"
        return 0
    fi
}

# Decrypt all encrypted secrets files and generate derivative files
decrypt_all() {
    if ! check_dependencies; then
        exit $?
    fi

    local age_key="${1:-${SOPS_AGE_KEY_FILE:-$DEFAULT_AGE_KEY}}"

    if [[ ! -f "$age_key" ]]; then
        echo -e "${RED}Error: Age key file not found: $age_key${NC}" >&2
        echo "" >&2
        echo "Please provide the age key file:" >&2
        echo "  ./encrypt.sh decrypt /path/to/age-key.txt" >&2
        echo "" >&2
        echo "Or set SOPS_AGE_KEY_FILE environment variable" >&2
        return 3
    fi

    export SOPS_AGE_KEY_FILE="$age_key"

    echo -e "${BLUE}=== Generating env files from encrypted secrets ===${NC}"
    echo -e "Using age key: ${YELLOW}$age_key${NC}\n"

    local processed=0
    local skipped=0
    local failed=0

    while IFS= read -r file; do
        local rel_path="${file#$SCRIPT_DIR/}"

        echo "Processing: $rel_path"
        if generate_env_files "$file"; then
            ((processed++)) || true
        else
            ((failed++)) || true
        fi
    done < <(find_secrets)

    echo ""
    echo -e "${BLUE}Summary:${NC}"
    echo -e "  Processed: ${GREEN}$processed${NC}"

    if [[ $failed -gt 0 ]]; then
        echo -e "  Failed:    ${RED}$failed${NC}" >&2
        echo "" >&2
        echo -e "${RED}ERROR: Generation failed for $failed file(s)${NC}" >&2
        return 5
    fi

    echo ""
    echo -e "${GREEN}✓ Successfully generated .env and secrets/*.txt files${NC}"
    echo -e "${YELLOW}⚠ Note: secrets.yaml files remain ENCRYPTED (safe)${NC}"
    echo -e "${YELLOW}⚠ Generated files are gitignored and ephemeral${NC}"
    return 0
}

# Show usage
usage() {
    echo "Usage: $0 <command> [age_key_file]"
    echo ""
    echo "Commands:"
    echo "  encrypt [key]  Encrypt all plaintext secrets.yaml files"
    echo "  decrypt [key]  Generate .env files from encrypted secrets.yaml (secrets.yaml stays encrypted!)"
    echo "  check          Check all secrets are encrypted (CI-friendly, exits 4 if not)"
    echo "  status         Show encryption status of all secrets"
    echo "  list           List all secrets.yaml files"
    echo ""
    echo "Options:"
    echo "  key            Path to age private key file"
    echo "                 Default: $DEFAULT_AGE_KEY"
    echo ""
    echo "Environment:"
    echo "  SOPS_AGE_KEY_FILE  Override default age key path"
    echo "  CI                 Set to 'true' for CI mode"
    echo ""
    echo "Exit Codes:"
    echo "  0  Success"
    echo "  1  General error"
    echo "  2  SOPS/age not installed"
    echo "  3  Age key not found"
    echo "  4  Unencrypted secrets found (check mode)"
    echo "  5  Encryption/decryption failed"
    echo ""
    echo "Examples:"
    echo "  $0 check                              # CI check - verify all encrypted"
    echo "  $0 status                             # Show encryption status"
    echo "  $0 encrypt                            # Encrypt all secrets.yaml files"
    echo "  $0 encrypt /path/to/my-age-key.txt    # Encrypt with custom key"
    echo "  $0 decrypt                            # Generate .env files (secrets.yaml stays encrypted)"
    echo ""
    echo "Typical workflow:"
    echo "  1. Edit secrets.yaml (plaintext)      # Make changes"
    echo "  2. ./encrypt.sh encrypt                # Encrypt before commit"
    echo "  3. git commit & push                   # Push encrypted version"
    echo "  4. On server: ./encrypt.sh decrypt     # Generate .env files for docker-compose"
}

# Main
case "${1:-}" in
    encrypt)
        encrypt_all "${2:-}"
        ;;
    decrypt)
        decrypt_all "${2:-}"
        ;;
    check)
        check_encryption
        ;;
    status)
        show_status
        ;;
    list)
        list_secrets
        ;;
    -h|--help|help)
        usage
        ;;
    *)
        usage
        exit 1
        ;;
esac
