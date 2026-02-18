# Cloud Desktop - Fish Shell Configuration
# Shares aliases with Zsh via /etc/profile.d/cloud-aliases.sh

# ============================================================================
# ENVIRONMENT
# ============================================================================

set -gx EDITOR nvim
set -gx VISUAL nvim
set -gx BROWSER brave
set -gx TERM xterm-256color

# XDG Base Directories
set -gx XDG_CONFIG_HOME $HOME/.config
set -gx XDG_DATA_HOME $HOME/.local/share
set -gx XDG_CACHE_HOME $HOME/.cache
set -gx XDG_STATE_HOME $HOME/.local/state

# ============================================================================
# PATH
# ============================================================================

fish_add_path $HOME/.local/bin
fish_add_path $HOME/.cargo/bin
fish_add_path $HOME/go/bin
fish_add_path $HOME/.npm-global/bin

# ============================================================================
# LOAD SHARED ALIASES
# ============================================================================

# Source the shared aliases file (bash format, convert to fish)
if test -f /etc/profile.d/cloud-aliases.sh
    # Parse and convert bash aliases to fish
    for line in (grep "^alias " /etc/profile.d/cloud-aliases.sh)
        set -l alias_def (string replace "alias " "" $line)
        set -l name (string split "=" $alias_def)[1]
        set -l value (string split "=" $alias_def)[2..-1]
        set value (string join "=" $value)
        set value (string trim -c "'" $value)
        alias $name $value 2>/dev/null
    end
end

# ============================================================================
# FISH-SPECIFIC ALIASES (override bash ones if needed)
# ============================================================================

# These work better in fish
alias ls 'eza --icons --group-directories-first'
alias l 'eza -l --icons --group-directories-first'
alias la 'eza -la --icons --group-directories-first'
alias ll 'eza -l --icons --group-directories-first'
alias lt 'eza -lT --icons --group-directories-first --level=2'

# ============================================================================
# ABBREVIATIONS (Fish-specific - expand on space)
# ============================================================================

abbr -a gco 'git checkout'
abbr -a gcb 'git checkout -b'
abbr -a gcm 'git commit -m'
abbr -a gp 'git push'
abbr -a gpl 'git pull'
abbr -a dc 'docker compose'

# ============================================================================
# FUNCTIONS
# ============================================================================

# Create directory and cd into it
function mkcd
    mkdir -p $argv[1] && cd $argv[1]
end

# Extract any archive
function extract
    switch $argv[1]
        case '*.tar.bz2'
            tar xjf $argv[1]
        case '*.tar.gz'
            tar xzf $argv[1]
        case '*.tar.xz'
            tar xJf $argv[1]
        case '*.bz2'
            bunzip2 $argv[1]
        case '*.gz'
            gunzip $argv[1]
        case '*.tar'
            tar xf $argv[1]
        case '*.tbz2'
            tar xjf $argv[1]
        case '*.tgz'
            tar xzf $argv[1]
        case '*.zip'
            unzip $argv[1]
        case '*.7z'
            7z x $argv[1]
        case '*.rar'
            unar $argv[1]
        case '*'
            echo "Unknown archive format: $argv[1]"
    end
end

# Quick backup
function backup
    cp $argv[1] $argv[1].bak.(date +%Y%m%d_%H%M%S)
end

# Git clone and cd
function gclone
    git clone $argv[1] && cd (basename $argv[1] .git)
end

# Search and replace in files
function replace
    if test (count $argv) -lt 3
        echo "Usage: replace <search> <replace> <files...>"
        return 1
    end
    set -l search $argv[1]
    set -l replace $argv[2]
    for file in $argv[3..-1]
        sed -i "s/$search/$replace/g" $file
    end
end

# ============================================================================
# INTERACTIVE SHELL SETUP
# ============================================================================

if status is-interactive
    # Disable greeting
    set -g fish_greeting

    # Starship prompt
    starship init fish | source

    # Zoxide (smart cd)
    zoxide init fish | source

    # FZF key bindings
    if type -q fzf
        fzf --fish | source
    end

    # Direnv (if installed)
    if type -q direnv
        direnv hook fish | source
    end
end

# ============================================================================
# COLORS
# ============================================================================

set -g fish_color_normal normal
set -g fish_color_command blue
set -g fish_color_keyword magenta
set -g fish_color_quote green
set -g fish_color_redirection cyan
set -g fish_color_end yellow
set -g fish_color_error red
set -g fish_color_param cyan
set -g fish_color_comment brblack
set -g fish_color_selection --background=brblack
set -g fish_color_search_match --background=brblack
set -g fish_color_operator yellow
set -g fish_color_escape magenta
set -g fish_color_autosuggestion brblack

# ============================================================================
# KEYBINDINGS
# ============================================================================

# Ctrl+F to accept autosuggestion
bind \cf forward-char

# Alt+Enter for newline (multiline commands)
bind \e\r 'commandline -i \n'

# Ctrl+Z to undo
bind \cz undo
