#!/bin/bash
# Cloud Desktop - Auto Clone Repositories
# This script runs on first login to set up user's repositories

REPOS_DIR="$HOME/Projects"
MARKER_FILE="$HOME/.repos-cloned"

# Skip if already cloned
if [[ -f "$MARKER_FILE" ]]; then
    exit 0
fi

# Create Projects directory
mkdir -p "$REPOS_DIR"

echo ""
echo "╔══════════════════════════════════════════════════════════════╗"
echo "║           Setting up your repositories...                    ║"
echo "╚══════════════════════════════════════════════════════════════╝"
echo ""

# Function to clone a repo with explicit URLs
clone_repo() {
    local name="$1"
    local target_dir="$2"
    local ssh_url="$3"
    local https_url="$4"

    if [[ -d "$target_dir" ]]; then
        echo "  ✓ $name already exists at $target_dir"
        return 0
    fi

    echo "  → Cloning $name..."

    # Try SSH first, fall back to HTTPS
    if git clone "$ssh_url" "$target_dir" 2>/dev/null; then
        echo "  ✓ $name cloned successfully (SSH)"
    elif git clone "$https_url" "$target_dir" 2>/dev/null; then
        echo "  ✓ $name cloned successfully (HTTPS)"
    else
        echo "  ✗ Failed to clone $name"
        echo "    Try manually: git clone $https_url $target_dir"
        return 1
    fi
}

# ============================================================================
# REPOSITORIES TO CLONE
# ============================================================================

# Cloud infrastructure and backend
clone_repo "cloud" \
    "$REPOS_DIR/cloud" \
    "git@github.com:diegonmarcos/cloud.git" \
    "https://github.com/diegonmarcos/cloud.git"

# Frontend / GitHub Pages projects
clone_repo "front-Github_io" \
    "$REPOS_DIR/front-Github_io" \
    "git@github.com:diegonmarcos/front-Github_io.git" \
    "https://github.com/diegonmarcos/front-Github_io.git"

# Ops tooling and utilities
clone_repo "ops-Tooling" \
    "$REPOS_DIR/ops-Tooling" \
    "git@github.com:diegonmarcos/ops-Tooling.git" \
    "https://github.com/diegonmarcos/ops-Tooling.git"

# MyVault - copy manually after deployment:
# scp -r /home/diego/Documents/Git/MyVault user@host:~/Projects/MyVault
mkdir -p "$REPOS_DIR/MyVault"
echo "MyVault placeholder - copy your vault here" > "$REPOS_DIR/MyVault/README.md"

# ============================================================================
# POST-CLONE SETUP
# ============================================================================

# Configure git (if not already configured)
if [[ -z "$(git config --global user.email)" ]]; then
    echo ""
    echo "  → Configuring git..."
    git config --global user.name "Diego Nepomuceno Marcos"
    git config --global user.email "me@diegonmarcos.com"
    git config --global init.defaultBranch main
    git config --global pull.rebase false
    git config --global core.editor nvim
    git config --global diff.tool delta
    git config --global merge.tool vimdiff
    echo "  ✓ Git configured"
fi

# Create marker file
touch "$MARKER_FILE"

echo ""
echo "╔══════════════════════════════════════════════════════════════╗"
echo "║           Repositories ready!                                ║"
echo "║                                                              ║"
echo "║   Projects location: ~/Projects                              ║"
echo "║                                                              ║"
echo "║   Quick access:                                              ║"
echo "║     cloud  → ~/Projects/cloud           # Backend/infra      ║"
echo "║     front  → ~/Projects/front-Github_io # Frontend           ║"
echo "║     ops    → ~/Projects/ops-Tooling     # DevOps tools       ║"
echo "║     vault  → ~/Projects/MyVault         # Personal vault     ║"
echo "║                                                              ║"
echo "╚══════════════════════════════════════════════════════════════╝"
echo ""
