#!/bin/sh
#═══════════════════════════════════════════════════════════════
# Universal Build Engine v1.0
# Configured by build.json — identical in every project
#═══════════════════════════════════════════════════════════════
# Usage: ./build.sh [command] [options]
# Commands: build, dev, stop, clean, deploy, deps, status, help

set -e

# ─── PATHS ──────────────────────────────────────────────────
PROJECT_DIR="$(cd "$(dirname "$0")" && pwd)"
CONFIG_FILE="$PROJECT_DIR/build.json"
PID_FILE="$PROJECT_DIR/.build.pid"

# ─── COLORS ─────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; CYAN='\033[0;36m'; MAGENTA='\033[0;35m'
BOLD='\033[1m'; DIM='\033[2m'; NC='\033[0m'

# ─── OPTIONS ────────────────────────────────────────────────
OPT_VERBOSE=false
OPT_DRY_RUN=false
OPT_NO_DEPS=false

# ─── EXIT CODES ─────────────────────────────────────────────
EXIT_OK=0; EXIT_CONFIG=1; EXIT_DEPS=2; EXIT_BUILD=3
EXIT_SERVER=4; EXIT_DEPLOY=5

# ─── LOGGING ────────────────────────────────────────────────
log_info()    { printf "${BLUE}▶${NC} %s\n" "$1"; }
log_success() { printf "${GREEN}✓${NC} %s\n" "$1"; }
log_error()   { printf "${RED}✗${NC} %s\n" "$1" >&2; }
log_warn()    { printf "${YELLOW}!${NC} %s\n" "$1"; }
log_step()    { printf "  ${CYAN}→${NC} %s\n" "$1"; }
log_verbose() { [ "$OPT_VERBOSE" = true ] && printf "  ${DIM}%s${NC}\n" "$1" || true; }

# ─── ERROR HANDLING ─────────────────────────────────────────
cleanup() {
    _exit_code=$?
    if [ $_exit_code -ne 0 ] && [ $_exit_code -ne 130 ]; then
        log_error "Exited with code $_exit_code"
    fi
}
trap cleanup EXIT

# ─── CONFIG PARSER ──────────────────────────────────────────
# Reads build.json into CFG_* shell variables using node or python3
parse_config() {
    [ -f "$CONFIG_FILE" ] || {
        log_error "build.json not found in $PROJECT_DIR"
        exit $EXIT_CONFIG
    }

    _parsed=""

    # Try node first (always available for Node.js projects)
    if command -v node >/dev/null 2>&1; then
        _parsed="$(CF="$CONFIG_FILE" node -e '
var c = JSON.parse(require("fs").readFileSync(process.env.CF, "utf8"));
function p(k, v) {
    v = String(v == null ? "" : v).replace(/\\/g,"\\\\").replace(/"/g,"\\\"").replace(/\$/g,"\\$").replace(/`/g,"\\`");
    console.log(k + "=\"" + v + "\"");
}
p("CFG_NAME", c.name);
p("CFG_FW", c.framework || "vanilla");
p("CFG_PORT", c.port || 8000);
p("CFG_SRC", c.src || "src");
p("CFG_DIST", c.dist || "dist");
var b = c.build || [];
p("CFG_BN", b.length);
b.forEach(function(s, i) {
    var x = "CFG_B" + i + "_";
    ["mod","input","output","files","format","target","html","css","js","from","exclude","script","dir"].forEach(function(k) {
        p(x + k.toUpperCase(), s[k]);
    });
});
var sv = c.serve || {};
p("CFG_SM", sv.mode || "auto");
p("CFG_SD", sv.dir || c.src || "src");
var w = sv.watch || [];
p("CFG_WN", w.length);
w.forEach(function(s, i) {
    var x = "CFG_W" + i + "_";
    ["mod","input","output","format","target"].forEach(function(k) {
        p(x + k.toUpperCase(), s[k]);
    });
});
var d = c.deploy && c.deploy.targets || {};
var tn = Object.keys(d);
p("CFG_DN", tn.length);
tn.forEach(function(n, i) {
    var x = "CFG_D" + i + "_";
    p(x + "NAME", n);
    ["method","host","path","remote","profile"].forEach(function(k) {
        p(x + k.toUpperCase(), d[n][k]);
    });
});
        ' 2>/dev/null)" || _parsed=""
    fi

    # Fallback to python3
    if [ -z "$_parsed" ] && command -v python3 >/dev/null 2>&1; then
        _parsed="$(CF="$CONFIG_FILE" python3 -c '
import json, os
c = json.load(open(os.environ["CF"]))
def p(k, v):
    v = str(v if v is not None else "").replace("\\\\","\\\\\\\\").replace("\"","\\\\\"").replace("$","\\\\$").replace("`","\\\\`")
    print(f"{k}=\"{v}\"")
p("CFG_NAME", c.get("name"))
p("CFG_FW", c.get("framework","vanilla"))
p("CFG_PORT", c.get("port",8000))
p("CFG_SRC", c.get("src","src"))
p("CFG_DIST", c.get("dist","dist"))
b = c.get("build",[])
p("CFG_BN", len(b))
for i,s in enumerate(b):
    x = f"CFG_B{i}_"
    for k in ["mod","input","output","files","format","target","html","css","js","from","exclude","script","dir"]:
        v = s.get(k,"")
        if isinstance(v, list): v = ",".join(str(x) for x in v)
        p(x + k.upper(), v)
sv = c.get("serve",{})
p("CFG_SM", sv.get("mode","auto"))
p("CFG_SD", sv.get("dir", c.get("src","src")))
w = sv.get("watch",[])
p("CFG_WN", len(w))
for i,s in enumerate(w):
    x = f"CFG_W{i}_"
    for k in ["mod","input","output","format","target"]:
        p(x + k.upper(), s.get(k,""))
d = c.get("deploy",{}).get("targets",{})
tn = list(d.keys())
p("CFG_DN", len(tn))
for i,n in enumerate(tn):
    x = f"CFG_D{i}_"
    p(x + "NAME", n)
    for k in ["method","host","path","remote","profile"]:
        p(x + k.upper(), d[n].get(k,""))
        ' 2>/dev/null)" || _parsed=""
    fi

    [ -n "$_parsed" ] || {
        log_error "Cannot parse build.json (need node or python3)"
        exit $EXIT_CONFIG
    }

    eval "$_parsed"
}

# ─── DEP RESOLUTION ─────────────────────────────────────────

# Check which deps from a package.json are missing in a node_modules dir
# Outputs missing package names (with @version) one per line
_check_missing_deps() {
    local pkg_json="$1" nm_dir="$2"
    [ -f "$pkg_json" ] || return 0
    [ -d "$nm_dir" ] || return 0

    node -e "
const p=JSON.parse(require('fs').readFileSync('$pkg_json','utf8'));
const all={...(p.dependencies||{}),...(p.devDependencies||{})};
for(const [k,v] of Object.entries(all)){
  try{require.resolve(k+'/package.json',{paths:['$nm_dir']})}
  catch(e){console.log(k+'@'+v)}
}" 2>/dev/null || python3 -c "
import json,os
p=json.load(open('$pkg_json'))
deps={**p.get('dependencies',{}),**p.get('devDependencies',{})}
for k,v in deps.items():
    if not os.path.isdir(os.path.join('$nm_dir',k)):
        print(k+'@'+v)
" 2>/dev/null || true
}

resolve_deps() {
    [ "$OPT_NO_DEPS" = true ] && return 0
    local pkg_dir="${1:-$PROJECT_DIR}"

    # Find repo root (install target for shared deps)
    local repo_root
    repo_root="$(cd "$pkg_dir" && git rev-parse --show-toplevel 2>/dev/null)" || repo_root=""
    local nm_dir="${repo_root:+$repo_root/node_modules}"
    [ -n "$nm_dir" ] || nm_dir="$pkg_dir/node_modules"

    # Check if project deps are satisfied
    if [ -f "$pkg_dir/package.json" ]; then
        local missing
        missing="$(_check_missing_deps "$pkg_dir/package.json" "$nm_dir")"
        if [ -n "$missing" ]; then
            local install_dir="${repo_root:-$pkg_dir}"
            log_info "Installing missing deps at $install_dir..."
            log_verbose "missing: $missing"
            if command -v npm >/dev/null 2>&1; then
                (cd "$install_dir" && npm install --save-dev --no-fund --no-audit $missing 2>&1 | tail -5) || true
            else
                log_error "npm not found -- cannot install: $missing"
                return $EXIT_DEPS
            fi
        fi
    fi

    # Export paths to repo root node_modules
    if [ -n "$repo_root" ] && [ -d "$repo_root/node_modules" ]; then
        export NODE_PATH="${repo_root}/node_modules${NODE_PATH:+:$NODE_PATH}"
        export PATH="${repo_root}/node_modules/.bin:$PATH"
        log_success "deps: repo root ($repo_root/node_modules)"
        return 0
    fi

    # Fallback: local node_modules
    if [ -d "$pkg_dir/node_modules" ]; then
        log_verbose "deps: local $pkg_dir/node_modules"
        return 0
    fi

    # Last resort: full install at repo root
    if command -v npm >/dev/null 2>&1 && [ -f "$pkg_dir/package.json" ]; then
        local install_dir="${repo_root:-$pkg_dir}"
        log_info "Installing all dependencies in $install_dir..."
        (cd "$install_dir" && npm install --no-fund --no-audit 2>&1 | tail -3)
        if [ -d "$install_dir/node_modules" ]; then
            [ -n "$repo_root" ] && {
                export NODE_PATH="${repo_root}/node_modules${NODE_PATH:+:$NODE_PATH}"
                export PATH="${repo_root}/node_modules/.bin:$PATH"
            }
            log_success "deps: installed in $install_dir"
            return 0
        fi
    fi

    log_error "Dependencies not resolved for $pkg_dir"
    return $EXIT_DEPS
}

# ─── TOOL RUNNER ─────────────────────────────────────────────
# Run a tool: PATH first (Nix / node_modules/.bin), npx fallback
run_tool() {
    local tool="$1"; shift
    if command -v "$tool" >/dev/null 2>&1; then
        "$tool" "$@"
    else
        log_verbose "fallback: npx $tool"
        npx "$tool" "$@"
    fi
}

# ─── BUILD MODULES ──────────────────────────────────────────

# Sass: compile SCSS to CSS
mod_sass() {
    local input="$PROJECT_DIR/$1"
    local output="$DIST_DIR/$2"
    local mode="${3:-prod}"

    [ -f "$input" ] || { log_error "sass: input not found: $input"; return $EXIT_BUILD; }
    mkdir -p "$(dirname "$output")"

    if [ "$mode" = "dev" ]; then
        run_tool sass "$input" "$output" --style=expanded --source-map
    else
        run_tool sass "$input" "$output" --style=compressed --no-source-map
    fi
    [ -f "$output" ] || { log_error "sass produced no output"; return $EXIT_BUILD; }
    log_success "sass: $(basename "$2")"
}

# Esbuild: bundle TypeScript/JavaScript
mod_esbuild() {
    local input="$PROJECT_DIR/$1"
    local output="$DIST_DIR/$2"
    local mode="${3:-prod}"
    local format="${4:-iife}"
    local target="${5:-es2020}"

    [ -f "$input" ] || { log_error "esbuild: input not found: $input"; return $EXIT_BUILD; }
    mkdir -p "$(dirname "$output")"

    local args="--bundle --format=$format --target=$target --outfile=$output"
    if [ "$mode" = "dev" ]; then
        args="$args --sourcemap"
    else
        args="$args --minify"
    fi

    run_tool esbuild "$input" $args
    [ -f "$output" ] || { log_error "esbuild produced no output"; return $EXIT_BUILD; }
    log_success "esbuild: $(basename "$2")"
}

# TypeScript compiler
mod_tsc() {
    local dir="$PROJECT_DIR/$1"
    local output_file="$2"
    local mode="${3:-prod}"

    [ -d "$dir" ] || { log_error "tsc: dir not found: $dir"; return $EXIT_BUILD; }

    cd "$dir"
    if [ "$mode" = "dev" ]; then
        run_tool tsc --sourceMap
    else
        run_tool tsc
    fi

    # Move output to dist if specified
    if [ -n "$output_file" ] && [ -f "$dir/$output_file" ]; then
        mv "$dir/$output_file" "$DIST_DIR/$output_file"
        [ -f "$dir/${output_file}.map" ] && mv "$dir/${output_file}.map" "$DIST_DIR/${output_file}.map"
    fi
    cd "$PROJECT_DIR"
    log_success "tsc: compiled"
}

# Vite build
mod_vite() {
    cd "$PROJECT_DIR"
    log_info "Running vite build..."
    run_tool vite build
    [ -d "$DIST_DIR" ] || { log_error "vite produced no output"; return $EXIT_BUILD; }
    log_success "vite: build complete"
}

# SvelteKit / npm run build
mod_sveltekit() {
    cd "$PROJECT_DIR"
    log_info "Running npm build..."
    npm run build 2>&1 || { log_error "npm build failed"; return $EXIT_BUILD; }
    log_success "build: complete"
}

# npm run <script>
mod_npm() {
    local script="${1:-build}"
    cd "$PROJECT_DIR"
    npm run "$script" 2>&1 || { log_error "npm run $script failed"; return $EXIT_BUILD; }
    log_success "npm: $script complete"
}

# Copy files to dist
mod_copy() {
    local files="$1"
    local from_dir="${2:-}"
    local exclude="${3:-}"

    local src_base="$PROJECT_DIR"
    [ -n "$from_dir" ] && src_base="$PROJECT_DIR/$from_dir"

    mkdir -p "$DIST_DIR"

    # Handle comma-separated file list or glob
    _IFS="$IFS"; IFS=","
    for pattern in $files; do
        IFS="$_IFS"
        pattern="$(echo "$pattern" | sed 's/^ *//;s/ *$//')"
        for file in "$src_base"/$pattern; do
            [ -f "$file" ] || continue
            _basename="$(basename "$file")"
            # Skip excluded files
            if [ -n "$exclude" ]; then
                case ",$exclude," in
                    *",$_basename,"*) continue ;;
                esac
            fi
            cp "$file" "$DIST_DIR/$_basename"
            log_step "copy: $_basename"
        done
    done
    IFS="$_IFS"
}

# Inline CSS and JS into HTML
mod_inline() {
    local html_file="$DIST_DIR/$1"
    local css_file="$DIST_DIR/$2"
    local js_file="$DIST_DIR/$3"

    [ -f "$html_file" ] || { log_error "inline: $1 not found in dist"; return $EXIT_BUILD; }

    # Strip BOM from CSS
    [ -f "$css_file" ] && sed -i '1s/^\xEF\xBB\xBF//' "$css_file"

    local css_base js_base
    css_base="$(basename "$css_file")"
    js_base="$(basename "$js_file")"
    local tmp_file="$DIST_DIR/.inline_tmp.html"

    awk '
    /<link[^>]*href="'"$css_base"'"[^>]*>/ {
        print "<style>"
        while ((getline line < "'"$css_file"'") > 0) print line
        close("'"$css_file"'")
        print "</style>"
        next
    }
    /<link[^>]*href="styles\.css"[^>]*>/ {
        print "<style>"
        while ((getline line < "'"$css_file"'") > 0) print line
        close("'"$css_file"'")
        print "</style>"
        next
    }
    /<script[^>]*src="'"$js_base"'"[^>]*><\/script>/ {
        print "<script>"
        while ((getline line < "'"$js_file"'") > 0) print line
        close("'"$js_file"'")
        print "</script>"
        next
    }
    /<script[^>]*src="script\.js"[^>]*><\/script>/ {
        print "<script>"
        while ((getline line < "'"$js_file"'") > 0) print line
        close("'"$js_file"'")
        print "</script>"
        next
    }
    { print }
    ' "$html_file" > "$tmp_file"

    mv "$tmp_file" "$html_file"
    rm -f "$css_file" "$js_file" "${css_file}.map" "${js_file}.map"
    log_success "inline: CSS+JS → $(basename "$html_file")"
}

# Strip type="module" and crossorigin for file:// protocol
mod_strip_module() {
    local files="$1"
    _IFS="$IFS"; IFS=","
    for f in $files; do
        IFS="$_IFS"
        f="$(echo "$f" | sed 's/^ *//;s/ *$//')"
        local target="$DIST_DIR/$f"
        [ -f "$target" ] || continue
        sed -i 's/ type="module"//g' "$target"
        sed -i 's/ crossorigin//g' "$target"
        sed -i 's/<script src="/<script defer src="/g' "$target"
        log_step "strip-module: $f"
    done
    IFS="$_IFS"
}

# Create symlink
mod_symlink() {
    local target="$1"
    local link_name="${2:-$(basename "$target")}"
    if [ -d "$PROJECT_DIR/$target" ]; then
        ln -sf "../$target" "$DIST_DIR/$link_name" 2>/dev/null || \
            cp -r "$PROJECT_DIR/$target" "$DIST_DIR/$link_name"
        log_step "symlink: $link_name → $target"
    fi
}

# ─── BUILD RUNNER ───────────────────────────────────────────
run_build() {
    local i=0
    local step_n="$CFG_BN"

    # Prepare dist
    mkdir -p "$DIST_DIR"

    while [ "$i" -lt "$step_n" ]; do
        local _n=$((i + 1))
        eval "local _mod=\$CFG_B${i}_MOD"
        eval "local _input=\$CFG_B${i}_INPUT"
        eval "local _output=\$CFG_B${i}_OUTPUT"
        eval "local _files=\$CFG_B${i}_FILES"
        eval "local _format=\$CFG_B${i}_FORMAT"
        eval "local _target=\$CFG_B${i}_TARGET"
        eval "local _html=\$CFG_B${i}_HTML"
        eval "local _css=\$CFG_B${i}_CSS"
        eval "local _js=\$CFG_B${i}_JS"
        eval "local _from=\$CFG_B${i}_FROM"
        eval "local _exclude=\$CFG_B${i}_EXCLUDE"
        eval "local _script=\$CFG_B${i}_SCRIPT"
        eval "local _dir=\$CFG_B${i}_DIR"

        log_info "Step $_n/$step_n: $_mod"

        if [ "$OPT_DRY_RUN" = true ]; then
            log_step "[dry-run] would run: $_mod $_input → $_output"
            i=$((i + 1))
            continue
        fi

        case "$_mod" in
            sass)         mod_sass "$_input" "$_output" "prod" ;;
            esbuild)      mod_esbuild "$_input" "$_output" "prod" "$_format" "$_target" ;;
            tsc)          mod_tsc "$_dir" "$_output" "prod" ;;
            vite)         mod_vite ;;
            sveltekit)    mod_sveltekit ;;
            npm)          mod_npm "$_script" ;;
            copy)         mod_copy "$_files" "$_from" "$_exclude" ;;
            inline)       mod_inline "$_html" "$_css" "$_js" ;;
            strip-module) mod_strip_module "$_files" ;;
            symlink)      mod_symlink "$_files" "$_output" ;;
            *)            log_warn "Unknown module: $_mod" ;;
        esac

        i=$((i + 1))
    done
}

# ─── DEV SERVER ─────────────────────────────────────────────

# Node.js static file server (no dependencies)
_node_static_server() {
    local dir="$1" port="$2"
    node -e '
var h=require("http"),f=require("fs"),p=require("path"),d=process.argv[1],port=process.argv[2];
var m={"html":"text/html","css":"text/css","js":"application/javascript","json":"application/json",
"png":"image/png","jpg":"image/jpeg","jpeg":"image/jpeg","gif":"image/gif","svg":"image/svg+xml",
"ico":"image/x-icon","woff":"font/woff","woff2":"font/woff2","ttf":"font/ttf","map":"application/json"};
h.createServer(function(req,res){
    var u=decodeURIComponent(req.url.split("?")[0]);
    var fp=p.join(d,u);
    try{if(f.statSync(fp).isDirectory())fp=p.join(fp,"index.html")}catch(e){}
    if(!f.existsSync(fp)){res.writeHead(404);res.end("Not Found");return}
    var ext=p.extname(fp).slice(1);
    res.writeHead(200,{"Content-Type":m[ext]||"application/octet-stream","Cache-Control":"no-cache"});
    f.createReadStream(fp).pipe(res);
}).listen(port,function(){console.log("Serving "+d+" on http://localhost:"+port)});
    ' "$dir" "$port"
}

# Start dev server with fallback chain
start_server() {
    local serve_dir="$PROJECT_DIR/$CFG_SD"
    local port="$CFG_PORT"
    local mode="$CFG_SM"

    # Detect mode if auto
    if [ "$mode" = "auto" ]; then
        if [ -f "$PROJECT_DIR/vite.config.ts" ] || [ -f "$PROJECT_DIR/vite.config.js" ]; then
            if [ -f "$PROJECT_DIR/svelte.config.js" ] || [ -f "$PROJECT_DIR/svelte.config.ts" ]; then
                mode="sveltekit"
            else
                mode="vite"
            fi
        elif command -v live-server >/dev/null 2>&1; then
            mode="live-server"
        elif command -v node >/dev/null 2>&1; then
            mode="node-static"
        elif command -v python3 >/dev/null 2>&1; then
            mode="python"
        elif command -v busybox >/dev/null 2>&1; then
            mode="busybox"
        elif command -v php >/dev/null 2>&1; then
            mode="php"
        else
            log_error "No HTTP server found. Install one of: node, python3, busybox, php"
            return $EXIT_SERVER
        fi
    fi

    # Check if port is already in use
    if command -v lsof >/dev/null 2>&1; then
        local existing_pid
        existing_pid="$(lsof -ti :$port 2>/dev/null | head -1)" || existing_pid=""
        if [ -n "$existing_pid" ]; then
            log_error "Port $port already in use (pid $existing_pid)"
            log_step "Run: ./build.sh stop  or  kill $existing_pid"
            return $EXIT_SERVER
        fi
    fi

    log_info "Starting dev server ($mode) on port $port..."

    case "$mode" in
        vite)
            cd "$PROJECT_DIR"
            nohup npm run dev > /dev/null 2>&1 &
            _write_pid "$!" "$port" "vite"
            ;;
        sveltekit)
            cd "$PROJECT_DIR"
            nohup npm run dev > /dev/null 2>&1 &
            _write_pid "$!" "$port" "sveltekit"
            ;;
        live-server)
            [ -d "$serve_dir" ] || serve_dir="$PROJECT_DIR"
            nohup live-server "$serve_dir" --port="$port" --no-browser --quiet > /dev/null 2>&1 &
            _write_pid "$!" "$port" "live-server"
            ;;
        node-static)
            [ -d "$serve_dir" ] || serve_dir="$PROJECT_DIR"
            nohup sh -c '_node_static_server "$1" "$2"' _ "$serve_dir" "$port" > /dev/null 2>&1 &
            # Use inline approach since function won't be available in nohup subshell
            nohup node -e '
var h=require("http"),f=require("fs"),p=require("path"),d=process.argv[1],port=process.argv[2];
var m={"html":"text/html","css":"text/css","js":"application/javascript","json":"application/json",
"png":"image/png","jpg":"image/jpeg","svg":"image/svg+xml","ico":"image/x-icon"};
h.createServer(function(req,res){
    var u=decodeURIComponent(req.url.split("?")[0]);var fp=p.join(d,u);
    try{if(f.statSync(fp).isDirectory())fp=p.join(fp,"index.html")}catch(e){}
    if(!f.existsSync(fp)){res.writeHead(404);res.end("Not Found");return}
    var ext=p.extname(fp).slice(1);
    res.writeHead(200,{"Content-Type":m[ext]||"application/octet-stream"});
    f.createReadStream(fp).pipe(res);
}).listen(port,function(){});
            ' "$serve_dir" "$port" > /dev/null 2>&1 &
            _write_pid "$!" "$port" "node-static"
            ;;
        python)
            [ -d "$serve_dir" ] || serve_dir="$PROJECT_DIR"
            nohup python3 -m http.server "$port" --directory "$serve_dir" > /dev/null 2>&1 &
            _write_pid "$!" "$port" "python3"
            ;;
        busybox)
            [ -d "$serve_dir" ] || serve_dir="$PROJECT_DIR"
            nohup busybox httpd -f -p "$port" -h "$serve_dir" > /dev/null 2>&1 &
            _write_pid "$!" "$port" "busybox"
            ;;
        php)
            [ -d "$serve_dir" ] || serve_dir="$PROJECT_DIR"
            nohup php -S "localhost:$port" -t "$serve_dir" > /dev/null 2>&1 &
            _write_pid "$!" "$port" "php"
            ;;
        *)
            log_error "Unknown serve mode: $mode"
            return $EXIT_SERVER
            ;;
    esac
}

# Start file watchers for dev mode
start_watchers() {
    local i=0
    local serve_dir="$PROJECT_DIR/$CFG_SD"

    while [ "$i" -lt "$CFG_WN" ]; do
        eval "local _mod=\$CFG_W${i}_MOD"
        eval "local _input=\$CFG_W${i}_INPUT"
        eval "local _output=\$CFG_W${i}_OUTPUT"
        eval "local _format=\$CFG_W${i}_FORMAT"
        eval "local _target=\$CFG_W${i}_TARGET"

        case "$_mod" in
            sass)
                nohup sass "$serve_dir/$_input" "$serve_dir/$_output" --watch --style=expanded --source-map > /dev/null 2>&1 &
                _append_pid "$!" "sass"
                log_step "watcher: sass"
                ;;
            esbuild)
                local fmt="${_format:-iife}"
                local tgt="${_target:-es2020}"
                nohup esbuild "$serve_dir/$_input" --bundle --outfile="$serve_dir/$_output" --format="$fmt" --target="$tgt" --sourcemap --watch=forever > /dev/null 2>&1 &
                _append_pid "$!" "esbuild"
                log_step "watcher: esbuild"
                ;;
            tsc)
                local tsc_dir="$serve_dir"
                [ -n "$_input" ] && tsc_dir="$serve_dir/$_input"
                cd "$tsc_dir"
                nohup tsc --watch > /dev/null 2>&1 &
                _append_pid "$!" "tsc"
                cd "$PROJECT_DIR"
                log_step "watcher: tsc"
                ;;
        esac

        i=$((i + 1))
    done
}

# ─── SERVER MANAGEMENT ──────────────────────────────────────

# Write PID file (JSON)
_write_pid() {
    local pid="$1" port="$2" server_type="$3"
    local now
    now="$(date -u +%Y-%m-%dT%H:%M:%S 2>/dev/null || date +%s)"

    printf '{"port":%s,"server":"%s","started":"%s","pids":{"%s":%s}}\n' \
        "$port" "$server_type" "$now" "$server_type" "$pid" > "$PID_FILE"
}

# Append a PID to existing pidfile
_append_pid() {
    local pid="$1" name="$2"
    if [ -f "$PID_FILE" ] && command -v node >/dev/null 2>&1; then
        node -e '
var fs=require("fs"),f=process.argv[1],p=JSON.parse(fs.readFileSync(f,"utf8"));
p.pids[process.argv[2]]=parseInt(process.argv[3]);
fs.writeFileSync(f,JSON.stringify(p)+"\n");
        ' "$PID_FILE" "$name" "$pid" 2>/dev/null || true
    fi
}

# Check if server is running
check_server() {
    if [ ! -f "$PID_FILE" ]; then
        echo "stopped"
        return 1
    fi

    # Read PIDs and check if alive
    local all_alive=true
    if command -v node >/dev/null 2>&1; then
        local pids
        pids="$(node -e '
var p=JSON.parse(require("fs").readFileSync(process.argv[1],"utf8"));
Object.entries(p.pids).forEach(function(e){console.log(e[0]+":"+e[1])});
        ' "$PID_FILE" 2>/dev/null)" || { echo "stopped"; return 1; }

        echo "$pids" | while IFS=: read -r name pid; do
            if kill -0 "$pid" 2>/dev/null; then
                printf "  ${GREEN}✓${NC} %-12s pid %s\n" "$name" "$pid"
            else
                printf "  ${RED}✗${NC} %-12s pid %s (dead)\n" "$name" "$pid"
                all_alive=false
            fi
        done

        local port
        port="$(node -p 'JSON.parse(require("fs").readFileSync(process.argv[1],"utf8")).port' "$PID_FILE" 2>/dev/null)" || port=""
        [ -n "$port" ] && printf "  ${CYAN}→${NC} http://localhost:%s/\n" "$port"
    fi

    return 0
}

# Stop server and all watchers
stop_server() {
    if [ ! -f "$PID_FILE" ]; then
        log_warn "No server running (.build.pid not found)"
        return 0
    fi

    log_info "Stopping server..."

    if command -v node >/dev/null 2>&1; then
        node -e '
var fs=require("fs"),p=JSON.parse(fs.readFileSync(process.argv[1],"utf8"));
Object.entries(p.pids).forEach(function(e){
    try{process.kill(parseInt(e[1]),"SIGTERM");console.log("Stopped "+e[0]+" (pid "+e[1]+")")}
    catch(err){console.log("Already stopped: "+e[0]+" (pid "+e[1]+")")}
});
        ' "$PID_FILE" 2>/dev/null || true
    else
        # Fallback: try to kill known PIDs from file
        grep -oE '"[a-z]+": *[0-9]+' "$PID_FILE" 2>/dev/null | grep -oE '[0-9]+' | while read -r pid; do
            kill "$pid" 2>/dev/null || true
        done
    fi

    rm -f "$PID_FILE"
    log_success "Server stopped"
}

# ─── DEPLOYMENT ─────────────────────────────────────────────

deploy_rsync() {
    local host="$1" path="$2"
    [ -d "$DIST_DIR" ] || { log_error "dist/ is empty — build first"; return $EXIT_DEPLOY; }
    command -v rsync >/dev/null 2>&1 || { log_error "rsync not found"; return $EXIT_DEPLOY; }

    log_info "Deploying via rsync to $host:$path..."
    rsync -avz --delete "$DIST_DIR/" "${host}:${path}" 2>&1 || {
        log_error "rsync failed"
        return $EXIT_DEPLOY
    }
    log_success "Deployed via rsync"
}

deploy_scp() {
    local host="$1" path="$2"
    [ -d "$DIST_DIR" ] || { log_error "dist/ is empty — build first"; return $EXIT_DEPLOY; }

    log_info "Deploying via scp to $host:$path..."
    scp -r "$DIST_DIR/"* "${host}:${path}" 2>&1 || {
        log_error "scp failed"
        return $EXIT_DEPLOY
    }
    log_success "Deployed via scp"
}

deploy_rclone() {
    local remote="$1"
    [ -d "$DIST_DIR" ] || { log_error "dist/ is empty — build first"; return $EXIT_DEPLOY; }
    command -v rclone >/dev/null 2>&1 || { log_error "rclone not found"; return $EXIT_DEPLOY; }

    log_info "Deploying via rclone to $remote..."
    rclone sync "$DIST_DIR/" "$remote" --progress 2>&1 || {
        log_error "rclone failed"
        return $EXIT_DEPLOY
    }
    log_success "Deployed via rclone"
}

deploy_unison() {
    local profile="$1"
    command -v unison >/dev/null 2>&1 || { log_error "unison not found"; return $EXIT_DEPLOY; }

    log_info "Syncing via unison (profile: $profile)..."
    unison "$profile" -batch 2>&1 || {
        log_error "unison failed"
        return $EXIT_DEPLOY
    }
    log_success "Synced via unison"
}

run_deploy() {
    local target_name="${1:-}"

    # If no target specified, use first
    if [ -z "$target_name" ] && [ "$CFG_DN" -gt 0 ]; then
        eval "target_name=\$CFG_D0_NAME"
    fi

    [ -n "$target_name" ] || {
        log_error "No deploy targets configured in build.json"
        return $EXIT_DEPLOY
    }

    # Find target by name
    local i=0
    while [ "$i" -lt "$CFG_DN" ]; do
        eval "local _name=\$CFG_D${i}_NAME"
        if [ "$_name" = "$target_name" ]; then
            eval "local _method=\$CFG_D${i}_METHOD"
            eval "local _host=\$CFG_D${i}_HOST"
            eval "local _path=\$CFG_D${i}_PATH"
            eval "local _remote=\$CFG_D${i}_REMOTE"
            eval "local _profile=\$CFG_D${i}_PROFILE"

            if [ "$OPT_DRY_RUN" = true ]; then
                log_info "[dry-run] would deploy via $_method to $_name"
                return 0
            fi

            case "$_method" in
                rsync)  deploy_rsync "$_host" "$_path" ;;
                scp)    deploy_scp "$_host" "$_path" ;;
                rclone) deploy_rclone "$_remote" ;;
                unison) deploy_unison "$_profile" ;;
                *)      log_error "Unknown deploy method: $_method"; return $EXIT_DEPLOY ;;
            esac
            return $?
        fi
        i=$((i + 1))
    done

    log_error "Deploy target '$target_name' not found"
    log_step "Available: $(i=0; while [ $i -lt $CFG_DN ]; do eval "printf \$CFG_D${i}_NAME"; printf " "; i=$((i+1)); done)"
    return $EXIT_DEPLOY
}

# ─── STATUS & HELPER ────────────────────────────────────────

# Get dependency status
_deps_status() {
    if [ -d "$PROJECT_DIR/node_modules" ]; then
        printf "${GREEN}✓${NC}  local (./node_modules)"
    else
        local repo_root
        repo_root="$(cd "$PROJECT_DIR" && git rev-parse --show-toplevel 2>/dev/null)" || repo_root=""
        if [ -n "$repo_root" ] && [ -d "$repo_root/node_modules" ]; then
            local rel
            rel="$(python3 -c "import os.path;print(os.path.relpath('$repo_root/node_modules','$PROJECT_DIR'))" 2>/dev/null || echo "$repo_root/node_modules")"
            printf "${GREEN}✓${NC}  repo root ($rel)"
        else
            printf "${RED}✗${NC}  not installed — run: ./build.sh deps"
        fi
    fi
}

# Get build status
_build_status() {
    if [ -d "$DIST_DIR" ]; then
        local count size age
        count="$(find "$DIST_DIR" -type f 2>/dev/null | wc -l | tr -d ' ')"
        size="$(du -sh "$DIST_DIR" 2>/dev/null | cut -f1)"
        printf "${GREEN}✓${NC}  dist/ — %s files, %s" "$count" "$size"
    else
        printf "${RED}✗${NC}  not built — run: ./build.sh build"
    fi
}

# Get server status
_server_status() {
    if [ -f "$PID_FILE" ] && command -v node >/dev/null 2>&1; then
        local port server
        port="$(node -p 'JSON.parse(require("fs").readFileSync(process.argv[1],"utf8")).port' "$PID_FILE" 2>/dev/null)" || port=""
        server="$(node -p 'JSON.parse(require("fs").readFileSync(process.argv[1],"utf8")).server' "$PID_FILE" 2>/dev/null)" || server=""

        # Check if main process is alive
        local main_pid
        main_pid="$(node -p 'var p=JSON.parse(require("fs").readFileSync(process.argv[1],"utf8"));p.pids[p.server]||Object.values(p.pids)[0]' "$PID_FILE" 2>/dev/null)" || main_pid=""

        if [ -n "$main_pid" ] && kill -0 "$main_pid" 2>/dev/null; then
            printf "${GREEN}✓${NC}  http://localhost:%s  (%s, pid %s)" "$port" "$server" "$main_pid"
        else
            printf "${YELLOW}!${NC}  stale pidfile (server not running)"
            rm -f "$PID_FILE"
        fi
    else
        printf "${DIM}—${NC}  not running"
    fi
}

# Get deploy status
_deploy_status() {
    if [ "$CFG_DN" -gt 0 ]; then
        local i=0
        while [ "$i" -lt "$CFG_DN" ]; do
            eval "local _name=\$CFG_D${i}_NAME"
            eval "local _method=\$CFG_D${i}_METHOD"
            eval "local _host=\$CFG_D${i}_HOST"
            eval "local _path=\$CFG_D${i}_PATH"
            eval "local _remote=\$CFG_D${i}_REMOTE"
            local dest="$_host:$_path"
            [ -z "$_host" ] && dest="$_remote"
            printf "  ${CYAN}%-12s${NC}  %s → %s\n" "$_name" "$_method" "$dest"
            i=$((i + 1))
        done
    else
        printf "  ${DIM}—  not configured${NC}\n"
    fi
}

# Print helper/status display
print_helper() {
    local fw_label="$CFG_FW"
    case "$CFG_FW" in
        vue)       fw_label="Vue 3" ;;
        react)     fw_label="React" ;;
        sveltekit) fw_label="SvelteKit" ;;
        vanilla)   fw_label="Vanilla" ;;
    esac

    printf "\n"
    printf "${BLUE}╔══════════════════════════════════════════════════════════════╗${NC}\n"
    printf "${BLUE}║${NC}  ${BOLD}${CFG_NAME}${NC} — ${fw_label} :${CFG_PORT}\n"
    printf "${BLUE}╚══════════════════════════════════════════════════════════════╝${NC}\n"
    printf "\n"

    # Status
    printf " ${BOLD}Status:${NC}\n"
    printf "   deps    "; _deps_status; printf "\n"
    printf "   build   "; _build_status; printf "\n"
    printf "   server  "; _server_status; printf "\n"
    printf "\n"

    # Commands
    printf " ${BOLD}Commands:${NC}\n"
    printf "   ${GREEN}build${NC}              Build for production → dist/\n"
    printf "   ${GREEN}dev${NC}                Start dev server with watchers (port %s)\n" "$CFG_PORT"
    printf "   ${GREEN}stop${NC}               Kill running dev server\n"
    printf "   ${GREEN}clean${NC}              Remove build artifacts\n"
    if [ "$CFG_DN" -gt 0 ]; then
        printf "   ${GREEN}deploy [target]${NC}    Deploy dist/ to remote server\n"
    fi
    printf "   ${GREEN}deps${NC}               Install/check dependencies\n"
    printf "   ${GREEN}status${NC}             Full status details\n"
    printf "\n"

    # Deploy targets
    if [ "$CFG_DN" -gt 0 ]; then
        printf " ${BOLD}Deploy targets:${NC}\n"
        _deploy_status
        printf "\n"
    fi

    # Options
    printf " ${BOLD}Options:${NC}\n"
    printf "   ${DIM}--dry-run${NC}          Show what would run\n"
    printf "   ${DIM}--verbose${NC}          Print all commands\n"
    printf "   ${DIM}--no-deps${NC}          Skip dependency resolution\n"
    printf "\n"

    # Build pipeline
    if [ "$CFG_BN" -gt 0 ]; then
        printf " ${BOLD}Build pipeline:${NC}\n"
        local i=0
        while [ "$i" -lt "$CFG_BN" ]; do
            eval "local _mod=\$CFG_B${i}_MOD"
            eval "local _input=\$CFG_B${i}_INPUT"
            eval "local _output=\$CFG_B${i}_OUTPUT"
            eval "local _files=\$CFG_B${i}_FILES"
            local detail=""
            [ -n "$_input" ] && detail="$_input"
            [ -n "$_files" ] && detail="$_files"
            [ -n "$_output" ] && [ -n "$detail" ] && detail="$detail → $_output"
            printf "   %s. ${CYAN}%-14s${NC} %s\n" "$((i + 1))" "$_mod" "$detail"
            i=$((i + 1))
        done
        printf "\n"
    fi

    # Paths
    printf " ${BOLD}Paths:${NC}\n"
    printf "   src     %s/\n" "$CFG_SRC"
    printf "   dist    %s/\n" "$CFG_DIST"
    printf "\n"
}

# ─── COMMANDS ───────────────────────────────────────────────

cmd_build() {
    log_info "Building $CFG_NAME for production..."
    resolve_deps
    rm -rf "$DIST_DIR"
    mkdir -p "$DIST_DIR"
    run_build
    log_success "Build complete → $DIST_DIR"
}

cmd_dev() {
    log_info "Starting $CFG_NAME dev environment..."
    resolve_deps

    # Start watchers first (for static projects)
    if [ "$CFG_WN" -gt 0 ]; then
        start_watchers
    fi

    # Start server
    start_server

    sleep 1

    printf "\n"
    printf "${GREEN}+----------------------------------------------------------+${NC}\n"
    printf "${GREEN}|${NC}  ${CYAN}${CFG_NAME} STARTED${NC}\n"
    printf "${GREEN}+----------------------------------------------------------+${NC}\n"
    printf "${GREEN}|${NC}  ${YELLOW}URL:${NC}  ${BLUE}http://localhost:${CFG_PORT}/${NC}\n"
    printf "${GREEN}|${NC}  ${YELLOW}Stop:${NC} ./build.sh stop\n"
    printf "${GREEN}+----------------------------------------------------------+${NC}\n"
    printf "\n"
}

cmd_stop() {
    stop_server
}

cmd_clean() {
    log_info "Cleaning build artifacts..."
    rm -rf "$DIST_DIR"
    rm -f "$PID_FILE"
    rm -rf "$PROJECT_DIR/node_modules/.vite" 2>/dev/null || true
    rm -rf "$PROJECT_DIR/.svelte-kit" 2>/dev/null || true
    log_success "Clean complete"
}

cmd_deploy() {
    local target="${1:-}"
    run_deploy "$target"
}

cmd_deps() {
    OPT_NO_DEPS=false
    resolve_deps
}

cmd_status() {
    printf "\n ${BOLD}Server:${NC}\n"
    if [ -f "$PID_FILE" ]; then
        check_server
    else
        printf "  ${DIM}Not running${NC}\n"
    fi
    printf "\n ${BOLD}Build:${NC}\n"
    printf "   "; _build_status; printf "\n"
    printf "\n ${BOLD}Dependencies:${NC}\n"
    printf "   "; _deps_status; printf "\n"
    printf "\n"
}

# ─── MAIN ───────────────────────────────────────────────────
main() {
    # Parse options
    _action=""
    _deploy_target=""
    for arg in "$@"; do
        case "$arg" in
            --verbose)  OPT_VERBOSE=true ;;
            --dry-run)  OPT_DRY_RUN=true ;;
            --no-deps)  OPT_NO_DEPS=true ;;
            --*)        ;; # ignore unknown options
            *)
                if [ -z "$_action" ]; then
                    _action="$arg"
                else
                    _deploy_target="$arg"
                fi
                ;;
        esac
    done

    # Parse config (needed for all commands except help with no config)
    if [ -f "$CONFIG_FILE" ]; then
        parse_config
        DIST_DIR="$PROJECT_DIR/$CFG_DIST"
    else
        if [ -z "$_action" ] || [ "$_action" = "help" ]; then
            printf "${RED}✗${NC} build.json not found in %s\n" "$PROJECT_DIR"
            printf "  Create a build.json to configure this project.\n"
            exit $EXIT_CONFIG
        fi
    fi

    # Default action: show helper
    [ -z "$_action" ] && { print_helper; exit 0; }

    case "$_action" in
        build)      cmd_build ;;
        dev|watch)  cmd_dev ;;
        stop|kill)  cmd_stop ;;
        clean)      cmd_clean ;;
        deploy)     cmd_deploy "$_deploy_target" ;;
        deps)       cmd_deps ;;
        status)     cmd_status ;;
        help|-h|--help) print_helper ;;
        *)
            log_error "Unknown command: $_action"
            print_helper
            exit 1
            ;;
    esac
}

main "$@"
