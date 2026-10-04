#!/bin/bash
# Cloud Desktop - Shared Shell Aliases
# This file is sourced by both Fish and Zsh for consistent experience

# ============================================================================
# NAVIGATION
# ============================================================================
alias ..='cd ..'
alias ...='cd ../..'
alias ....='cd ../../..'
alias ~='cd ~'
alias -- -='cd -'

# ============================================================================
# LISTING (using eza - modern ls replacement)
# ============================================================================
alias ls='eza --icons --group-directories-first'
alias l='eza -l --icons --group-directories-first'
alias la='eza -la --icons --group-directories-first'
alias ll='eza -l --icons --group-directories-first'
alias lt='eza -lT --icons --group-directories-first --level=2'
alias lta='eza -laT --icons --group-directories-first --level=2'

# ============================================================================
# FILE OPERATIONS
# ============================================================================
alias cp='cp -iv'
alias mv='mv -iv'
alias rm='rm -iv'
alias mkdir='mkdir -pv'
alias md='mkdir -pv'

# ============================================================================
# FILE VIEWING (using bat - modern cat replacement)
# ============================================================================
alias cat='bat --paging=never'
alias less='bat --paging=always'
alias more='bat --paging=always'

# ============================================================================
# SEARCH (using ripgrep and fd)
# ============================================================================
alias grep='rg'
alias find='fd'
alias ff='fd --type f'
alias fdir='fd --type d'

# ============================================================================
# FILE MANAGER
# ============================================================================
alias y='yazi'
alias fm='yazi'
alias files='dolphin .'

# ============================================================================
# EDITORS
# ============================================================================
alias v='nvim'
alias vim='nvim'
alias vi='nvim'
alias nano='nvim'
alias code='code --no-sandbox'
alias k='kate'

# ============================================================================
# GIT - Core Commands
# ============================================================================
alias g='git'
alias gs='git status'
alias ga='git add'
alias gaa='git add --all'
alias gc='git commit'
alias gcm='git commit -m'
alias gca='git commit --amend'
alias gp='git push'
alias gpf='git push --force-with-lease'
alias gpl='git pull'
alias gf='git fetch'
alias gfa='git fetch --all --prune'
alias gco='git checkout'
alias gcb='git checkout -b'
alias gsw='git switch'
alias gswc='git switch -c'
alias gb='git branch'
alias gba='git branch -a'
alias gbd='git branch -d'
alias gbD='git branch -D'
alias gd='git diff'
alias gds='git diff --staged'
alias gdw='git diff --word-diff'
alias gl='git log --oneline --graph --decorate -15'
alias gla='git log --oneline --graph --decorate --all'
alias glp='git log -p'
alias gst='git stash'
alias gstp='git stash pop'
alias gstl='git stash list'
alias gsts='git stash show -p'

# ============================================================================
# GIT - Advanced & Tools
# ============================================================================
alias lg='lazygit'
alias gui='gitui'
alias tig='tig'
alias tiga='tig --all'
alias gab='git absorb'
alias gabr='git absorb --and-rebase'
alias gcrypt='git-crypt'
alias gcl='git-crypt lock'
alias gcu='git-crypt unlock'

# Git utilities
alias gwip='git add -A && git commit -m "WIP"'
alias gunwip='git reset HEAD~1'
alias gclean='git clean -fd'
alias greset='git reset --hard HEAD'
alias gundo='git reset --soft HEAD~1'
alias gamend='git commit --amend --no-edit'
alias grebase='git rebase -i'
alias gcp='git cherry-pick'
alias gblame='git blame'
alias gbisect='git bisect'
alias gref='git reflog'
alias gtag='git tag'
alias gtagl='git tag -l'

# GitHub CLI
alias ghpr='gh pr create'
alias ghprl='gh pr list'
alias ghprv='gh pr view'
alias ghprc='gh pr checkout'
alias ghis='gh issue list'
alias ghic='gh issue create'
alias ghrepo='gh repo view --web'

# ============================================================================
# DOCKER
# ============================================================================
alias d='docker'
alias dc='docker compose'
alias dps='docker ps'
alias dpsa='docker ps -a'
alias di='docker images'
alias dex='docker exec -it'
alias dlog='docker logs -f'
alias drm='docker rm'
alias drmi='docker rmi'
alias dprune='docker system prune -af'

# ============================================================================
# RUST / CARGO
# ============================================================================
alias c='cargo'
alias cb='cargo build'
alias cr='cargo run'
alias ct='cargo test'
alias cc='cargo check'
alias ccl='cargo clippy'
alias cf='cargo fmt'
alias cw='cargo watch -x run'
alias cu='cargo update'

# ============================================================================
# PYTHON
# ============================================================================
alias py='python'
alias python='python3'
alias pip='pip3'
alias venv='python -m venv'
alias activate='source .venv/bin/activate'
alias deactivate='deactivate'
alias ipy='ipython'
alias jn='jupyter notebook'

# ============================================================================
# NODE.JS / NPM
# ============================================================================
alias ni='npm install'
alias nid='npm install -D'
alias nr='npm run'
alias nrd='npm run dev'
alias nrb='npm run build'
alias nrt='npm run test'
alias pni='pnpm install'
alias pnr='pnpm run'
alias pnrd='pnpm run dev'

# ============================================================================
# SYSTEM MONITORING
# ============================================================================
alias top='btop'
alias htop='btop'
alias ps='procs'
alias du='dust'
alias df='df -h'
alias free='free -h'
alias mem='free -h'

# ============================================================================
# NETWORK
# ============================================================================
alias ip='ip -c'
alias ping='ping -c 5'
alias ports='ss -tulpn'
alias myip='curl -s ifconfig.me'
alias speedtest='curl -s https://raw.githubusercontent.com/sivel/speedtest-cli/master/speedtest.py | python -'

# ============================================================================
# VPN
# ============================================================================
alias vpnc='protonvpn-cli connect'
alias vpnd='protonvpn-cli disconnect'
alias vpns='protonvpn-cli status'
alias wgup='sudo wg-quick up wg0'
alias wgdown='sudo wg-quick down wg0'
alias wgs='sudo wg show'

# ============================================================================
# BITWARDEN (Secrets Management)
# ============================================================================
alias bw='bw'
alias bwl='bw login'
alias bwu='bw unlock'
alias bwsync='bw sync'
alias bwls='bw list items'
alias bwget='bw get item'
alias bwpass='bw get password'
alias bwuser='bw get username'
alias bwnote='bw get notes'
alias bwsearch='bw list items --search'

# ============================================================================
# AI ASSISTANTS (Claude & Gemini)
# ============================================================================
alias claude='claude'
alias ai='claude'
alias gemini='gemini'

# ============================================================================
# RCLONE (Cloud Storage Sync)
# ============================================================================
alias rc='rclone'
alias rcls='rclone ls'
alias rclsd='rclone lsd'
alias rccopy='rclone copy'
alias rcsync='rclone sync'
alias rcmount='rclone mount'
alias rcconfig='rclone config'
alias rccheck='rclone check'
alias rcsize='rclone size'

# ============================================================================
# PACKAGE MANAGEMENT (Arch)
# ============================================================================
alias pac='sudo pacman'
alias pacs='sudo pacman -S'
alias pacr='sudo pacman -Rns'
alias pacu='sudo pacman -Syu'
alias pacq='pacman -Q'
alias pacqs='pacman -Qs'
alias pacf='pacman -F'
alias ya='yay'
alias yas='yay -S'
alias yau='yay -Syu'

# ============================================================================
# APPLICATIONS
# ============================================================================
alias browser='brave'
alias notes='obsidian'
alias music='spotify'
alias mail='proton-mail'
alias secrets='bitwarden'
alias vault='bitwarden'
alias term='konsole &'

# ============================================================================
# UTILITIES
# ============================================================================
alias c='clear'
alias cls='clear'
alias h='history'
alias hg='history | grep'
alias path='echo $PATH | tr ":" "\n"'
alias now='date +"%Y-%m-%d %H:%M:%S"'
alias week='date +%V'
alias reload='source ~/.zshrc 2>/dev/null || source ~/.config/fish/config.fish 2>/dev/null'

# ============================================================================
# CLIPBOARD (requires xclip)
# ============================================================================
alias copy='xclip -selection clipboard'
alias paste='xclip -selection clipboard -o'

# ============================================================================
# SAFETY
# ============================================================================
alias chown='chown --preserve-root'
alias chmod='chmod --preserve-root'
alias chgrp='chgrp --preserve-root'

# ============================================================================
# SHORTCUTS
# ============================================================================
alias q='exit'
alias :q='exit'
alias e='exit'

# ============================================================================
# PROJECT NAVIGATION
# ============================================================================
alias proj='cd ~/Projects'
alias docs='cd ~/Documents'
alias dl='cd ~/Downloads'
alias desk='cd ~/Desktop'

# Main repositories
alias cloud='cd ~/Projects/cloud'
alias front='cd ~/Projects/front-Github_io'
alias ops='cd ~/Projects/ops-Tooling'
alias vault='cd ~/Projects/MyVault'
alias infra='cd ~/Projects/cloud'
alias web='cd ~/Projects/front-Github_io'
alias tools='cd ~/Projects/ops-Tooling'
alias keys='cd ~/Projects/MyVault'

# Quick project access
alias pcloud='cd ~/Projects/cloud && ls'
alias pfront='cd ~/Projects/front-Github_io && ls'
alias pops='cd ~/Projects/ops-Tooling && ls'
alias pvault='cd ~/Projects/MyVault && ls'

# Clone/sync repos
alias repos='setup-repos'
alias sync-all='cd ~/Projects && for d in */; do echo "=== $d ===" && cd "$d" && git pull && cd ..; done'
