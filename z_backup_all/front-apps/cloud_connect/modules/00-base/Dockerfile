# Cloud Connect - Base Image
# Anonymous isolated environment with ProtonVPN + Encrypted DNS + Brave
#
# Build: docker build -t cloud-connect:latest .
# Run: docker compose up -d

FROM archlinux:latest

LABEL maintainer="Diego Nepomuceno Marcos <me@diegonmarcos.com>"
LABEL description="Anonymous isolated environment"
LABEL version="2.0"

# ═══════════════════════════════════════════════════════════════════════════
# SYSTEM SETUP
# ═══════════════════════════════════════════════════════════════════════════

# Update system and install base packages
RUN pacman -Syu --noconfirm && \
    pacman -S --noconfirm \
    # Base system
    base-devel \
    git \
    sudo \
    which \
    curl \
    wget \
    # Shells
    bash \
    fish \
    zsh \
    # Core utilities
    coreutils \
    findutils \
    grep \
    sed \
    gawk \
    less \
    tree \
    htop \
    bc \
    jq \
    # Network tools
    iproute2 \
    iputils \
    bind \
    net-tools \
    openssh \
    # VPN & DNS
    wireguard-tools \
    openvpn \
    openresolv \
    # Certificates
    ca-certificates \
    && pacman -Scc --noconfirm

# ═══════════════════════════════════════════════════════════════════════════
# USER SETUP
# ═══════════════════════════════════════════════════════════════════════════

# Create non-root user
ARG USERNAME=clouduser
ARG USER_UID=1000
ARG USER_GID=1000

RUN groupadd --gid $USER_GID $USERNAME && \
    useradd --uid $USER_UID --gid $USER_GID -m $USERNAME && \
    echo "$USERNAME ALL=(ALL) NOPASSWD:ALL" >> /etc/sudoers.d/$USERNAME && \
    chmod 0440 /etc/sudoers.d/$USERNAME

# ═══════════════════════════════════════════════════════════════════════════
# YAY (AUR HELPER)
# ═══════════════════════════════════════════════════════════════════════════

# Install yay for AUR packages
USER $USERNAME
WORKDIR /tmp

RUN git clone https://aur.archlinux.org/yay-bin.git && \
    cd yay-bin && \
    makepkg -si --noconfirm && \
    cd .. && rm -rf yay-bin

# ═══════════════════════════════════════════════════════════════════════════
# PROTONVPN
# ═══════════════════════════════════════════════════════════════════════════

# Install ProtonVPN CLI
RUN yay -S --noconfirm protonvpn-cli

# ═══════════════════════════════════════════════════════════════════════════
# ENCRYPTED DNS
# ═══════════════════════════════════════════════════════════════════════════

# Install DNS-over-HTTPS client (cloudflared)
RUN yay -S --noconfirm cloudflared

# ═══════════════════════════════════════════════════════════════════════════
# BRAVE BROWSER
# ═══════════════════════════════════════════════════════════════════════════

# Install Brave
RUN yay -S --noconfirm brave-bin

# ═══════════════════════════════════════════════════════════════════════════
# SHELL CONFIGURATION
# ═══════════════════════════════════════════════════════════════════════════

# Install starship prompt
RUN sudo pacman -S --noconfirm starship

# Install modern CLI tools
RUN sudo pacman -S --noconfirm \
    eza \
    bat \
    fd \
    ripgrep \
    fzf \
    zoxide

# ═══════════════════════════════════════════════════════════════════════════
# AI CLI TOOLS
# ═══════════════════════════════════════════════════════════════════════════

# Install Node.js for npm packages
RUN sudo pacman -S --noconfirm nodejs npm

# Install Claude Code CLI
RUN curl -fsSL https://claude.ai/install.sh | sh && \
    echo 'export PATH="$HOME/.local/bin:$PATH"' >> ~/.bashrc && \
    echo 'export PATH="$HOME/.local/bin:$PATH"' >> ~/.zshrc && \
    mkdir -p ~/.config/fish && \
    echo 'set -gx PATH $HOME/.local/bin $PATH' >> ~/.config/fish/config.fish

# Install Gemini CLI
RUN sudo npm install -g @google/gemini-cli

# ═══════════════════════════════════════════════════════════════════════════
# VNC & DESKTOP ENVIRONMENT
# ═══════════════════════════════════════════════════════════════════════════

# Install VNC server and Openbox window manager
RUN sudo pacman -S --noconfirm \
    tigervnc \
    openbox \
    dmenu \
    xorg-server \
    xorg-xinit \
    xorg-fonts-misc \
    xorg-fonts-type1 \
    ttf-dejavu

# Install Qt-based apps (GTK apps crash in containers due to bwrap sandboxing)
RUN sudo pacman -S --noconfirm \
    dolphin \
    konsole \
    breeze-icons

# Create VNC config directory and set password
RUN mkdir -p ~/.vnc && \
    echo "cloudvnc" | vncpasswd -f > ~/.vnc/passwd && \
    chmod 600 ~/.vnc/passwd

# Create Openbox config
RUN mkdir -p ~/.config/openbox && \
    echo '<?xml version="1.0" encoding="UTF-8"?>' > ~/.config/openbox/menu.xml && \
    echo '<openbox_menu xmlns="http://openbox.org/3.4/menu">' >> ~/.config/openbox/menu.xml && \
    echo '  <menu id="root-menu" label="Applications">' >> ~/.config/openbox/menu.xml && \
    echo '    <item label="Brave Browser"><action name="Execute"><execute>/usr/sbin/brave</execute></action></item>' >> ~/.config/openbox/menu.xml && \
    echo '    <item label="Dolphin Files"><action name="Execute"><execute>dolphin</execute></action></item>' >> ~/.config/openbox/menu.xml && \
    echo '    <item label="Konsole Terminal"><action name="Execute"><execute>konsole</execute></action></item>' >> ~/.config/openbox/menu.xml && \
    echo '    <separator/>' >> ~/.config/openbox/menu.xml && \
    echo '    <item label="Run... (Alt+F2)"><action name="Execute"><execute>dmenu_run</execute></action></item>' >> ~/.config/openbox/menu.xml && \
    echo '    <separator/>' >> ~/.config/openbox/menu.xml && \
    echo '    <item label="Reconfigure"><action name="Reconfigure"/></item>' >> ~/.config/openbox/menu.xml && \
    echo '  </menu>' >> ~/.config/openbox/menu.xml && \
    echo '</openbox_menu>' >> ~/.config/openbox/menu.xml

# Create Openbox rc.xml with working maximize button
RUN echo '<?xml version="1.0" encoding="UTF-8"?>' > ~/.config/openbox/rc.xml && \
    echo '<openbox_config xmlns="http://openbox.org/3.5/rc">' >> ~/.config/openbox/rc.xml && \
    echo '  <theme><titleLayout>NLIMC</titleLayout></theme>' >> ~/.config/openbox/rc.xml && \
    echo '  <keyboard>' >> ~/.config/openbox/rc.xml && \
    echo '    <keybind key="A-Tab"><action name="NextWindow"/></keybind>' >> ~/.config/openbox/rc.xml && \
    echo '    <keybind key="A-F4"><action name="Close"/></keybind>' >> ~/.config/openbox/rc.xml && \
    echo '    <keybind key="A-F2"><action name="Execute"><execute>dmenu_run</execute></action></keybind>' >> ~/.config/openbox/rc.xml && \
    echo '    <keybind key="A-F10"><action name="ToggleMaximize"/></keybind>' >> ~/.config/openbox/rc.xml && \
    echo '  </keyboard>' >> ~/.config/openbox/rc.xml && \
    echo '  <mouse>' >> ~/.config/openbox/rc.xml && \
    echo '    <context name="Titlebar"><mousebind button="Left" action="DoubleClick"><action name="ToggleMaximize"/></mousebind></context>' >> ~/.config/openbox/rc.xml && \
    echo '    <context name="Root"><mousebind button="Right" action="Press"><action name="ShowMenu"><menu>root-menu</menu></action></mousebind></context>' >> ~/.config/openbox/rc.xml && \
    echo '    <context name="Maximize"><mousebind button="Left" action="Click"><action name="ToggleMaximize"/></mousebind></context>' >> ~/.config/openbox/rc.xml && \
    echo '  </mouse>' >> ~/.config/openbox/rc.xml && \
    echo '</openbox_config>' >> ~/.config/openbox/rc.xml

# Create VNC xstartup script
RUN echo '#!/bin/bash' > ~/.vnc/xstartup && \
    echo 'export DISPLAY=:1' >> ~/.vnc/xstartup && \
    echo 'openbox &' >> ~/.vnc/xstartup && \
    echo 'konsole &' >> ~/.vnc/xstartup && \
    chmod +x ~/.vnc/xstartup

# ═══════════════════════════════════════════════════════════════════════════
# GLOBAL CLI SYMLINKS
# ═══════════════════════════════════════════════════════════════════════════

USER root

# Make Claude CLI globally accessible
RUN ln -sf /home/clouduser/.local/bin/claude /usr/local/bin/claude

# ═══════════════════════════════════════════════════════════════════════════
# HOME FOLDER STRUCTURE
# ═══════════════════════════════════════════════════════════════════════════

# Create home folder structure (mirrors host layout)
RUN mkdir -p /home/clouduser/{apps,git,mnt,syncs,sys,user,vault} && \
    chown -R clouduser:clouduser /home/clouduser

# ═══════════════════════════════════════════════════════════════════════════
# CLOUD CONNECT SETUP
# ═══════════════════════════════════════════════════════════════════════════

# Create directories
RUN mkdir -p /opt/cloud-connect/{modules,configs,lib} && \
    chown -R $USERNAME:$USERNAME /opt/cloud-connect

# Copy base module files
COPY --chown=$USERNAME:$USERNAME . /opt/cloud-connect/modules/00-base/

# Make scripts executable
RUN chmod +x /opt/cloud-connect/modules/00-base/*.sh 2>/dev/null || true

# ═══════════════════════════════════════════════════════════════════════════
# ENVIRONMENT
# ═══════════════════════════════════════════════════════════════════════════

ENV CLOUD_IN_CONTAINER=1
ENV CLOUD_ROOT=/opt/cloud-connect
ENV PATH="/home/clouduser/.local/bin:/opt/cloud-connect:$PATH"
ENV SHELL=/bin/bash

# Set user
USER $USERNAME
WORKDIR /home/$USERNAME

# ═══════════════════════════════════════════════════════════════════════════
# ENTRYPOINT
# ═══════════════════════════════════════════════════════════════════════════

COPY --chown=$USERNAME:$USERNAME entrypoint.sh /entrypoint.sh
RUN sudo chmod +x /entrypoint.sh

ENTRYPOINT ["/entrypoint.sh"]
CMD ["/bin/bash"]
