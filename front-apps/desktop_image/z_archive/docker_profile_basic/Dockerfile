# Cloud Connect - BASIC Profile
# Full tools installation (~20-30 min build)
# Graphics provided by host (Arch VM)
#
# Build: docker build -t cloud-connect:basic .
# Run: docker-compose up -d

FROM cloud-connect:minimum

LABEL maintainer="Diego Nepomuceno Marcos <me@diegonmarcos.com>"
LABEL description="Basic profile - full tools (no graphics)"
LABEL version="1.0"
LABEL profile="basic"

USER root

# ═══════════════════════════════════════════════════════════════════════════
# ADDITIONAL SHELLS & CLI TOOLS
# ═══════════════════════════════════════════════════════════════════════════

RUN pacman -S --noconfirm \
    # Additional shells
    fish \
    zsh \
    starship \
    # Modern CLI tools
    eza \
    bat \
    fd \
    ripgrep \
    fzf \
    zoxide \
    tree \
    bc \
    gawk

# ═══════════════════════════════════════════════════════════════════════════
# YAY (AUR HELPER)
# ═══════════════════════════════════════════════════════════════════════════

USER clouduser
WORKDIR /tmp

RUN git clone https://aur.archlinux.org/yay-bin.git && \
    cd yay-bin && \
    makepkg -si --noconfirm && \
    cd .. && rm -rf yay-bin

# ═══════════════════════════════════════════════════════════════════════════
# VPN & PRIVACY
# ═══════════════════════════════════════════════════════════════════════════

RUN yay -S --noconfirm protonvpn-cli cloudflared

USER root
RUN pacman -S --noconfirm \
    wireguard-tools \
    openvpn \
    openresolv \
    bind \
    net-tools

# ═══════════════════════════════════════════════════════════════════════════
# COMPILERS & RUNTIMES
# ═══════════════════════════════════════════════════════════════════════════

# C/C++
RUN pacman -S --noconfirm gcc clang cmake ninja make

# Rust
USER clouduser
RUN sudo pacman -S --noconfirm rustup && rustup default stable

# Go
RUN sudo pacman -S --noconfirm go

# Python
RUN sudo pacman -S --noconfirm python python-pip python-pipx

# Node.js
RUN sudo pacman -S --noconfirm nodejs pnpm

# ═══════════════════════════════════════════════════════════════════════════
# SANDBOXING PACKAGE MANAGERS
# ═══════════════════════════════════════════════════════════════════════════

# uv - Fast Python package manager
RUN curl -LsSf https://astral.sh/uv/install.sh | sh

# Nix - Universal package manager
RUN curl -L https://nixos.org/nix/install | sh -s -- --no-daemon && \
    echo '. ~/.nix-profile/etc/profile.d/nix.sh' >> ~/.bashrc && \
    echo '. ~/.nix-profile/etc/profile.d/nix.sh' >> ~/.zshrc && \
    mkdir -p ~/.config/fish && \
    echo 'source ~/.nix-profile/etc/profile.d/nix.sh' >> ~/.config/fish/config.fish

# Flatpak & Firejail
RUN sudo pacman -S --noconfirm flatpak firejail && \
    flatpak remote-add --user --if-not-exists flathub https://flathub.org/repo/flathub.flatpakrepo || true

# ═══════════════════════════════════════════════════════════════════════════
# AI CLI TOOLS
# ═══════════════════════════════════════════════════════════════════════════

# Claude Code CLI
RUN curl -fsSL https://claude.ai/install.sh | sh && \
    echo 'export PATH="$HOME/.local/bin:$PATH"' >> ~/.bashrc && \
    echo 'export PATH="$HOME/.local/bin:$PATH"' >> ~/.zshrc && \
    echo 'set -gx PATH $HOME/.local/bin $PATH' >> ~/.config/fish/config.fish

# Gemini CLI
RUN sudo pnpm add -g @google/gemini-cli

# ═══════════════════════════════════════════════════════════════════════════
# ADDITIONAL GUI APPS
# ═══════════════════════════════════════════════════════════════════════════

RUN sudo pacman -S --noconfirm \
    libreoffice-fresh

# ═══════════════════════════════════════════════════════════════════════════
# SHELL CONFIGURATION
# ═══════════════════════════════════════════════════════════════════════════

RUN echo 'eval "$(starship init bash)"' >> ~/.bashrc && \
    echo 'eval "$(zoxide init bash)"' >> ~/.bashrc && \
    echo 'alias ls="eza"' >> ~/.bashrc && \
    echo 'alias cat="bat"' >> ~/.bashrc && \
    echo 'alias find="fd"' >> ~/.bashrc && \
    echo 'alias grep="rg"' >> ~/.bashrc

# ═══════════════════════════════════════════════════════════════════════════
# GLOBAL SYMLINKS
# ═══════════════════════════════════════════════════════════════════════════

USER root
RUN ln -sf /home/clouduser/.local/bin/claude /usr/local/bin/claude 2>/dev/null || true

# ═══════════════════════════════════════════════════════════════════════════
# ENVIRONMENT
# ═══════════════════════════════════════════════════════════════════════════

ENV CLOUD_PROFILE=basic
ENV PATH="/home/clouduser/.local/bin:/home/clouduser/.cargo/bin:$PATH"

USER clouduser
WORKDIR /home/clouduser
