#!/usr/bin/env bash
# Cloud Connect - Logging Functions

_LOGGING_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$_LOGGING_DIR/colors.sh"

# Log levels
log_info() {
    echo -e "${BLUE}[INFO]${NC} $*"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $*"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $*" >&2
}

log_success() {
    echo -e "${GREEN}[OK]${NC} $*"
}

log_debug() {
    if [[ "${CLOUD_DEBUG:-0}" == "1" ]]; then
        echo -e "${DIM}[DEBUG]${NC} $*"
    fi
}

# Progress indicators
log_step() {
    local current=$1
    local total=$2
    local message=$3
    echo -e "${CYAN}[$current/$total]${NC} $message"
}

log_header() {
    echo ""
    echo -e "${BOLD}${CYAN}═══ $* ═══${NC}"
    echo ""
}

log_subheader() {
    echo -e "${BOLD}─── $* ───${NC}"
}

# Status indicators
status_ok() {
    echo -e "  ${GREEN}✓${NC} $*"
}

status_fail() {
    echo -e "  ${RED}✗${NC} $*"
}

status_skip() {
    echo -e "  ${YELLOW}○${NC} $*"
}

status_pending() {
    echo -e "  ${DIM}◌${NC} $*"
}

# Die with error message
die() {
    log_error "$*"
    exit 1
}

# Export functions
export -f log_info log_warn log_error log_success log_debug
export -f log_step log_header log_subheader
export -f status_ok status_fail status_skip status_pending
export -f die
