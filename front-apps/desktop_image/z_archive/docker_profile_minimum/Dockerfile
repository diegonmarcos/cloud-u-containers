# Cloud Connect - MINIMUM Profile
# Fast boot (~2-3 min) with basic apps
# Graphics provided by host (Arch VM)
#
# Build: docker build -t cloud-connect:minimum .
# Run: docker-compose up -d

FROM archlinux:latest

LABEL maintainer="Diego Nepomuceno Marcos <me@diegonmarcos.com>"
LABEL description="Minimum profile - basic apps (no graphics)"
LABEL version="1.0"
LABEL profile="minimum"

# ═══════════════════════════════════════════════════════════════════════════
# BASE SYSTEM (essentials only)
# ═══════════════════════════════════════════════════════════════════════════

RUN pacman -Syu --noconfirm && \
    pacman -S --noconfirm \
    # Base (minimal)
    base-devel \
    git \
    sudo \
    curl \
    wget \
    # Shell
    bash \
    # Core utilities
    coreutils \
    findutils \
    grep \
    sed \
    less \
    htop \
    jq \
    # Network
    iproute2 \
    iputils \
    openssh \
    ca-certificates \
    # Fonts (for GUI apps)
    ttf-dejavu \
    && pacman -Scc --noconfirm

# ═══════════════════════════════════════════════════════════════════════════
# USER SETUP
# ═══════════════════════════════════════════════════════════════════════════

ARG USERNAME=clouduser
ARG USER_UID=1000
ARG USER_GID=1000

RUN groupadd --gid $USER_GID $USERNAME && \
    useradd --uid $USER_UID --gid $USER_GID -m $USERNAME && \
    echo "$USERNAME ALL=(ALL) NOPASSWD:ALL" >> /etc/sudoers.d/$USERNAME && \
    chmod 0440 /etc/sudoers.d/$USERNAME

# ═══════════════════════════════════════════════════════════════════════════
# GUI APPS (run on host's X server)
# ═══════════════════════════════════════════════════════════════════════════

RUN pacman -S --noconfirm \
    konsole \
    falkon \
    dolphin \
    breeze-icons

# ═══════════════════════════════════════════════════════════════════════════
# HOME FOLDER STRUCTURE
# ═══════════════════════════════════════════════════════════════════════════

RUN mkdir -p /home/$USERNAME/{apps,git,mnt,syncs,sys,user,vault} && \
    chown -R $USERNAME:$USERNAME /home/$USERNAME

# ═══════════════════════════════════════════════════════════════════════════
# ENVIRONMENT
# ═══════════════════════════════════════════════════════════════════════════

ENV CLOUD_IN_CONTAINER=1
ENV CLOUD_PROFILE=minimum
ENV SHELL=/bin/bash

USER $USERNAME
WORKDIR /home/$USERNAME

# ═══════════════════════════════════════════════════════════════════════════
# ENTRYPOINT
# ═══════════════════════════════════════════════════════════════════════════

COPY --chown=$USERNAME:$USERNAME entrypoint.sh /entrypoint.sh
RUN sudo chmod +x /entrypoint.sh

ENTRYPOINT ["/entrypoint.sh"]
CMD ["/bin/bash"]
