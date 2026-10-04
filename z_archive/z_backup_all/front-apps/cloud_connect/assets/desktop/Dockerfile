# Cloud Desktop - KDE Plasma in Docker
# Full development environment with KDE, dev tools, and security apps

FROM archlinux:latest

LABEL maintainer="Diego Nepomuceno Marcos <me@diegonmarcos.com>"
LABEL description="Portable KDE Desktop with full development environment"
LABEL version="2.0"

# ============================================================================
# SYSTEM SETUP
# ============================================================================

# Configure pacman for parallel downloads
RUN echo "ParallelDownloads = 10" >> /etc/pacman.conf && \
    pacman -Syu --noconfirm

# Install base system utilities
RUN pacman -S --noconfirm --needed \
    base-devel \
    git \
    sudo \
    which \
    nano \
    vim \
    neovim \
    htop \
    btop \
    wget \
    curl \
    unzip \
    p7zip \
    zip \
    tar \
    gzip \
    xz \
    networkmanager \
    openssh \
    man-db \
    man-pages \
    less \
    tree \
    jq \
    ripgrep \
    fd \
    bat \
    fzf \
    eza \
    zoxide \
    starship

# ============================================================================
# DISPLAY & GRAPHICS
# ============================================================================

RUN pacman -S --noconfirm --needed \
    xorg-server \
    xorg-xinit \
    xorg-xauth \
    xorg-xhost \
    mesa \
    vulkan-icd-loader \
    libva-mesa-driver \
    mesa-vdpau \
    xf86-video-amdgpu \
    xf86-video-intel

# ============================================================================
# KDE PLASMA DESKTOP
# ============================================================================

RUN pacman -S --noconfirm --needed \
    plasma-desktop \
    plasma-workspace \
    plasma-nm \
    plasma-pa \
    powerdevil \
    bluedevil \
    kscreen \
    kdeplasma-addons \
    sddm \
    sddm-kcm \
    breeze \
    breeze-gtk \
    kde-gtk-config \
    xdg-desktop-portal-kde \
    kwalletmanager \
    kwallet-pam \
    plasma-systemmonitor

# KDE Applications
RUN pacman -S --noconfirm --needed \
    dolphin \
    dolphin-plugins \
    konsole \
    kate \
    ark \
    spectacle \
    gwenview \
    okular \
    kcalc \
    kfind \
    filelight \
    partitionmanager \
    kdeconnect \
    yakuake

# ============================================================================
# FONTS
# ============================================================================

RUN pacman -S --noconfirm --needed \
    ttf-dejavu \
    ttf-liberation \
    noto-fonts \
    noto-fonts-emoji \
    noto-fonts-cjk \
    ttf-fira-code \
    ttf-fira-mono \
    ttf-jetbrains-mono \
    ttf-cascadia-code \
    ttf-hack

# ============================================================================
# AUDIO
# ============================================================================

RUN pacman -S --noconfirm --needed \
    pipewire \
    pipewire-pulse \
    pipewire-alsa \
    pipewire-jack \
    wireplumber

# ============================================================================
# NETWORKING & VPN
# ============================================================================

RUN pacman -S --noconfirm --needed \
    wireguard-tools \
    openvpn \
    networkmanager-openvpn \
    networkmanager-openconnect \
    openconnect \
    openresolv \
    bind \
    rclone

# ============================================================================
# SHELLS - Fish & Zsh with shared config
# ============================================================================

RUN pacman -S --noconfirm --needed \
    fish \
    zsh \
    zsh-completions \
    zsh-autosuggestions \
    zsh-syntax-highlighting

# ============================================================================
# FILE MANAGERS
# ============================================================================

RUN pacman -S --noconfirm --needed \
    yazi \
    ffmpegthumbnailer \
    unar \
    poppler \
    imagemagick

# ============================================================================
# DEVELOPMENT - Python
# ============================================================================

RUN pacman -S --noconfirm --needed \
    python \
    python-pip \
    python-pipx \
    python-virtualenv \
    python-poetry \
    python-numpy \
    python-pandas \
    python-matplotlib \
    python-requests \
    python-pytest \
    python-black \
    python-pylint \
    python-mypy \
    ipython \
    jupyter-notebook

# ============================================================================
# DEVELOPMENT - Node.js
# ============================================================================

RUN pacman -S --noconfirm --needed \
    nodejs \
    npm \
    pnpm \
    yarn \
    typescript

# Install global npm packages
RUN npm install -g \
    eslint \
    prettier \
    typescript-language-server \
    vscode-langservers-extracted \
    @biomejs/biome \
    @anthropic-ai/claude-code \
    @google/generative-ai

# ============================================================================
# DEVELOPMENT - Rust
# ============================================================================

RUN pacman -S --noconfirm --needed \
    rustup

# ============================================================================
# DEVELOPMENT - Other Languages & Tools
# ============================================================================

RUN pacman -S --noconfirm --needed \
    go \
    lua \
    luarocks \
    ruby \
    perl \
    cmake \
    meson \
    ninja \
    make \
    gcc \
    clang \
    llvm \
    gdb \
    valgrind

# ============================================================================
# DEVELOPMENT - Docker (for nested containers)
# ============================================================================

RUN pacman -S --noconfirm --needed \
    docker \
    docker-compose \
    podman \
    buildah

# ============================================================================
# DEVELOPMENT - Database Clients
# ============================================================================

RUN pacman -S --noconfirm --needed \
    sqlite \
    postgresql-libs \
    mariadb-clients \
    redis

# ============================================================================
# DEVELOPMENT - Version Control & Git Tools
# ============================================================================

RUN pacman -S --noconfirm --needed \
    git \
    git-lfs \
    git-crypt \
    github-cli \
    lazygit \
    delta \
    difftastic \
    tig \
    git-absorb \
    gitui

# ============================================================================
# USER SETUP
# ============================================================================

ARG USERNAME=diegonmarcos
ARG USER_UID=1000
ARG USER_GID=1000

RUN groupadd --gid $USER_GID $USERNAME && \
    useradd --uid $USER_UID --gid $USER_GID -m -s /usr/bin/fish $USERNAME && \
    echo "$USERNAME:changeme" | chpasswd && \
    chage -d 0 $USERNAME && \
    echo "$USERNAME ALL=(ALL) NOPASSWD: ALL" >> /etc/sudoers.d/$USERNAME && \
    chmod 0440 /etc/sudoers.d/$USERNAME

# Add user to required groups
RUN usermod -aG wheel,video,audio,input,docker $USERNAME

# ============================================================================
# AUR HELPER & AUR PACKAGES
# ============================================================================

USER $USERNAME
WORKDIR /tmp

# Install yay
RUN git clone https://aur.archlinux.org/yay-bin.git && \
    cd yay-bin && \
    makepkg -si --noconfirm && \
    cd .. && rm -rf yay-bin

# Install AUR packages
RUN yay -S --noconfirm --needed \
    brave-bin \
    obsidian \
    visual-studio-code-bin \
    protonvpn-cli \
    proton-mail \
    spotify \
    bitwarden \
    bitwarden-cli

# ============================================================================
# RUST SETUP (as user)
# ============================================================================

RUN rustup default stable && \
    rustup component add rust-analyzer rust-src clippy rustfmt && \
    cargo install \
        cargo-edit \
        cargo-watch \
        cargo-expand \
        cargo-outdated \
        tokei \
        hyperfine \
        du-dust \
        procs \
        bottom

# ============================================================================
# SHELL CONFIGURATION
# ============================================================================

USER root

# Create shared aliases file
COPY --chmod=644 shell-aliases.sh /etc/profile.d/cloud-aliases.sh

# Fish configuration
RUN mkdir -p /home/$USERNAME/.config/fish/conf.d
COPY --chmod=644 fish-config.fish /home/$USERNAME/.config/fish/config.fish
RUN chown -R $USERNAME:$USERNAME /home/$USERNAME/.config

# Zsh configuration
COPY --chmod=644 zshrc /home/$USERNAME/.zshrc
RUN chown $USERNAME:$USERNAME /home/$USERNAME/.zshrc

# Starship prompt (shared between fish/zsh)
COPY --chmod=644 starship.toml /home/$USERNAME/.config/starship.toml
RUN chown $USERNAME:$USERNAME /home/$USERNAME/.config/starship.toml

# ============================================================================
# YAZI CONFIGURATION
# ============================================================================

RUN mkdir -p /home/$USERNAME/.config/yazi
COPY --chmod=644 yazi.toml /home/$USERNAME/.config/yazi/yazi.toml
RUN chown -R $USERNAME:$USERNAME /home/$USERNAME/.config/yazi

# ============================================================================
# SYSTEM CONFIGURATION
# ============================================================================

# Create runtime directory
RUN mkdir -p /tmp/runtime-$USERNAME && \
    chown $USERNAME:$USERNAME /tmp/runtime-$USERNAME && \
    chmod 700 /tmp/runtime-$USERNAME

# Configure SDDM for auto-login
RUN mkdir -p /etc/sddm.conf.d && \
    echo "[Autologin]" > /etc/sddm.conf.d/autologin.conf && \
    echo "User=$USERNAME" >> /etc/sddm.conf.d/autologin.conf && \
    echo "Session=plasma" >> /etc/sddm.conf.d/autologin.conf

# Configure systemd
RUN systemctl set-default graphical.target && \
    systemctl enable sddm NetworkManager docker

# First login password change script
COPY --chmod=755 first-login.sh /etc/profile.d/first-login.sh

# Auto-clone repositories script
COPY --chmod=755 setup-repos.sh /usr/local/bin/setup-repos
RUN echo '/usr/local/bin/setup-repos' >> /etc/profile.d/99-setup-repos.sh && \
    chmod +x /etc/profile.d/99-setup-repos.sh

# Create Projects directory
RUN mkdir -p /home/$USERNAME/Projects && \
    chown $USERNAME:$USERNAME /home/$USERNAME/Projects

# Startup script
COPY --chmod=755 entrypoint.sh /entrypoint.sh

# ============================================================================
# FINAL SETUP
# ============================================================================

WORKDIR /home/$USERNAME

# Expose ports
EXPOSE 5900 3389

ENTRYPOINT ["/entrypoint.sh"]
CMD ["startplasma-x11"]
