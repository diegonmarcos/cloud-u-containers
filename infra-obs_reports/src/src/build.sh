#!/bin/sh
# reports orchestrator — data-driven dispatch.
# Entry point: reports/build.sh (thin shim) → reports/src/build.sh (this file).
#
# Usage:
#   build.sh all                  run every DAILY crate's build+run (sec-data excluded)
#   build.sh build                build every crate, no run
#   build.sh sec                  run sec-data alone (weekly cadence)
#   build.sh list                 list discovered crates
#   build.sh test-dists           verify dist/ layout invariants
#   build.sh manifest             regenerate reports/manifest.json
#   build.sh <short>              run single crate (e.g. sec-data, health-full)
#   build.sh <full>               same, by full folder name (cloud-sec-data-report)
#   build.sh report<N>            same, by 1-based index in discovered list

set -eu

SELF_DIR="$(cd "$(dirname "$0")" && pwd)"
REPORTS_ROOT="$(cd "$SELF_DIR/.." && pwd)"
SRC_DIR="$SELF_DIR"
DIST_DIR="$REPORTS_ROOT/dist"
MANIFEST="$REPORTS_ROOT/manifest.json"
# Cross-crate snapshot the master writes and every derive reads. The name is
# the pipeline ABI, declared once in Rust as run_state::RUN_STATE_FILENAME.
RUN_STATE="$DIST_DIR/_run_state.json"

# Discover crates — every cloud-* dir under src/ that has a build.sh.
list_crate_dirs() {
    for d in "$SRC_DIR"/cloud-*/; do
        [ -d "$d" ] || continue
        [ -x "$d/build.sh" ] || continue
        printf '%s\n' "$(basename "$d")"
    done
}

# Map: short name → full folder name.
# Strip leading "cloud-" and trailing "-report"; fall back to full name.
short_name() {
    name="$1"
    name="${name#cloud-}"
    name="${name%-report}"
    printf '%s\n' "$name"
}

# Resolve a user-supplied target to a crate folder name.
# Accepts: full ("cloud-X-report"), short ("X"), or index ("reportN").
resolve_target() {
    target="$1"
    # Direct full-name match
    for c in $(list_crate_dirs); do
        [ "$c" = "$target" ] && { printf '%s\n' "$c"; return 0; }
    done
    # Short name match
    for c in $(list_crate_dirs); do
        [ "$(short_name "$c")" = "$target" ] && { printf '%s\n' "$c"; return 0; }
    done
    # report<N> — 1-based index
    case "$target" in
        report[0-9]*)
            idx="${target#report}"
            i=0
            for c in $(list_crate_dirs); do
                i=$((i + 1))
                [ "$i" = "$idx" ] && { printf '%s\n' "$c"; return 0; }
            done
            ;;
    esac
    return 1
}

cmd_list() {
    i=0
    for c in $(list_crate_dirs); do
        i=$((i + 1))
        printf '  report%-2d  %-32s (%s)\n' "$i" "$c" "$(short_name "$c")"
    done
}

# ── Vacuity guard: a run that reached no host verified NOTHING ────────────
# A health report is a probe. When it reaches zero of its hosts it has
# measured nothing, and the only honest outcome is a non-zero exit — never
# an empty success.
#
# THE FAILURE THIS GUARDS
#   cloud-health-reports-arm-oci-apps.yml concluded `success` on eight
#   consecutive runs (2026-09-01 .. 2026-09-16, newest 35058414004). Its
#   GitHub-hosted runner had no route to the WireGuard mesh, so every SSH to
#   a 10.0.0.0/24 address failed. The log said so plainly —
#       Fleet: 0/4 reachable
#       SSH oci-mail UNREACHABLE: SSH failed        (and oci-analytics,
#       L2 WG Mesh: 0/4 reachable in 6.0s            oci-apps, gcp-proxy)
#   — and then the job exited 0, because nothing in this pipeline ever
#   asserted that the reach count was above zero. Eight clean bills of
#   health from a probe that never reached a single host, consumed
#   downstream as evidence that the fleet was fine.
#
# WHY HERE AND NOT IN THE BINARY
#   This is the function that decides the exit status of a report run, and
#   it is read from the repository checkout the workflows mount, not from
#   the prebuilt image — so the guard takes effect on the next run rather
#   than on the next image build.
#
# WHY THE COUNT IS READ, NOT KEPT
#   The number comes out of the snapshot the master itself just wrote. The
#   VM set behind it originates in _cloud-data-consolidated.json, so there
#   is no host list maintained here to drift out of agreement with the
#   declarations.
#
# There is deliberately NO opt-out environment variable. A vacuity guard
# with a bypass is decoration: the first red run sets the bypass and the
# check is back to proving nothing.
require_hosts_reached() {
    if ! command -v jq >/dev/null 2>&1; then
        echo "✗ reach guard cannot run: jq is not in PATH" >&2
        echo "  A check that cannot evaluate its subject fails; it does not skip." >&2
        return 1
    fi
    if [ ! -f "$RUN_STATE" ]; then
        echo "✗ reach guard: $RUN_STATE missing — the master recorded no fleet state" >&2
        echo "  Without it there is no evidence this run reached anything." >&2
        return 1
    fi

    # Mirrors fleet::VmState::is_reachable — Running | Provisioning |
    # Client{tcp_up:true}. serde renders the unit variants as bare strings
    # and Client as {"Client":{"tcp_up":<bool>}}.
    reached=$(jq '[.fleet_state.vms // {} | .[]
                   | select(. == "Running" or . == "Provisioning"
                            or (type == "object" and .Client.tcp_up == true))]
                  | length' "$RUN_STATE" 2>/dev/null || true)
    total=$(jq '(.fleet_state.vms // {}) | length' "$RUN_STATE" 2>/dev/null || true)
    case "$reached" in ''|*[!0-9]*) reached=-1 ;; esac
    case "$total"   in ''|*[!0-9]*) total=-1   ;; esac
    if [ "$reached" -lt 0 ] || [ "$total" -lt 0 ]; then
        echo "✗ reach guard: could not read .fleet_state.vms out of $RUN_STATE" >&2
        return 1
    fi

    if [ "$reached" -eq 0 ]; then
        echo "✗ hosts reached: 0 of $total — this report verified NOTHING" >&2
        echo "  Every declared host was unreachable. That is a failed probe," >&2
        echo "  not a healthy fleet, and it must not publish as a success." >&2
        echo "  Usual cause: the runner has no route to the 10.0.0.0/24 mesh." >&2
        echo "  A mesh-capable run needs either a runner that is already on the" >&2
        echo "  mesh, or the container started with --cap-add NET_ADMIN and a" >&2
        echo "  WireGuard key, as cloud-health-reports.yml does." >&2
        return 1
    fi

    echo "✓ hosts reached: $reached of $total"
    return 0
}

cmd_all() {
    action="${1:-all}"  # all | build
    MASTER="cloud-health-full-daily"
    # sec-data does ~140s of YARA + git-grep on local disk — pure CPU work
    # that can't be sped up by the snapshot. It runs on its own (weekly)
    # cadence via the security_data_scan.yaml DAG, not in the daily fan-out.
    SEC_DATA="cloud-sec-data-report"

    # ── Phase 0: ONE workspace cargo build ───────────────────────────
    # Avoids the serialised "Blocking waiting for file lock on package
    # cache" we hit when 5 crates' build.sh each call cargo concurrently.
    # One workspace invocation builds all binaries in parallel inside cargo
    # (no lock contention) and is incremental on warm cache.
    if [ -f /opt/reports/entrypoint.sh ]; then
        echo "── Docker image — binaries pre-built ──"
    else
        echo ""
        echo "══════════════════════════════════════════"
        echo "  workspace cargo build (single invocation)"
        echo "══════════════════════════════════════════"
        cargo build --release --manifest-path "$SRC_DIR/Cargo.toml" 2>&1 || {
            echo "FAIL: workspace build failed"; exit 1;
        }
    fi

    # ── Phase 0b: per-crate symlink + template setup (NO cargo) ───────
    # The `link` action is the symlink-only path in _crate_engine.sh —
    # Phase 0a already built the workspace, so calling `cargo -p X` here
    # would be a 5×~120s waste. Output is visible (no /dev/null) so the
    # phase is honest about its cost.
    for c in $(list_crate_dirs); do
        sh "$SRC_DIR/$c/build.sh" link
    done

    if [ "$action" = "build" ]; then
        return 0
    fi

    # ── Phase 1: run MASTER sequentially (in-process consolidates submodules) ─
    if [ -d "$SRC_DIR/$MASTER" ]; then
        echo ""
        echo "══════════════════════════════════════════"
        echo "  $MASTER (run) — master"
        echo "══════════════════════════════════════════"
        sh "$SRC_DIR/$MASTER/build.sh" run
    fi

    # ── Phase 1b: the run must have reached at least one host ────────────
    # Checked before the fan-out, not after it: every derive reads the same
    # snapshot, so a vacuous snapshot makes the whole fan-out vacuous too.
    # Stopping at the source is both the cheapest and the loudest place.
    require_hosts_reached || return 1

    # ── Phase 2: run DERIVES in PARALLEL ────────────────────────────────
    # Each derive owns a distinct output file. No cargo invocations now,
    # just binary execution.
    echo ""
    echo "══════════════════════════════════════════"
    echo "  derives (parallel fan-out)"
    echo "══════════════════════════════════════════"
    pids=""
    logs_dir="$DIST_DIR/.run-logs"
    mkdir -p "$logs_dir"
    # Per-derive deadline. Without one, a single wedged derive (an un-timed-out
    # network probe, say) is waited on forever, eats the entire remaining job
    # budget and the runner kills the whole workflow with 124 — so nothing else
    # in the fan-out ever gets to fail loudly first. The slowest healthy derive
    # measures ~113 seconds, so 600 is roughly five times headroom while still
    # leaving the 90-minute job budget intact. The -k escalation sends KILL 30
    # seconds after TERM, so a derive that ignores TERM still dies.
    derive_timeout_seconds=600
    for c in $(list_crate_dirs); do
        [ "$c" = "$MASTER" ] && continue
        [ "$c" = "$SEC_DATA" ] && continue
        log="$logs_dir/$c.log"
        ( timeout -k 30 "$derive_timeout_seconds" sh "$SRC_DIR/$c/build.sh" run >"$log" 2>&1 ) &
        pids="$pids $!:$c"
    done
    rc=0
    for entry in $pids; do
        pid="${entry%%:*}"
        crate="${entry#*:}"
        # Name the crate BEFORE blocking on it. The outcome lines below only
        # print once the wait returns, so a derive that never returns used to
        # print nothing at all — the hang presented as anonymous silence and
        # every investigator had to re-identify the culprit by elimination.
        # The last "waiting" line with no outcome under it is the hung derive.
        echo "… waiting: $crate"
        status=0
        wait "$pid" || status=$?
        if [ "$status" -eq 0 ]; then
            echo "✓ $crate"
            tail -3 "$logs_dir/$crate.log" | sed "s/^/    /"
        elif [ "$status" -eq 124 ] || [ "$status" -eq 137 ]; then
            # Both statuses mean the deadline expired, and this outcome must
            # name the crate rather than present as a generic failure — 124 is
            # also the code the runner kills the whole workflow with, so the two
            # would otherwise be indistinguishable in the log.
            #   124 = deadline expired and the derive accepted SIGTERM.
            #   137 = 128 + SIGKILL, the -k escalation for a derive that ignored
            #         SIGTERM. It is not 124 because coreutils timeout signals
            #         its own process group and SIGKILL cannot be ignored, so
            #         timeout dies alongside the derive and never reports its
            #         own 124. Verified against coreutils 9.7.
            # An out-of-memory kill also lands on 137; the status is printed and
            # the log tail follows, which is what tells the two apart.
            echo "✗ $crate TIMED OUT after ${derive_timeout_seconds}s (exit $status)"
            tail -20 "$logs_dir/$crate.log" | sed "s/^/    /"
            rc=1
        else
            echo "✗ $crate (exit $status)"
            tail -10 "$logs_dir/$crate.log" | sed "s/^/    /"
            rc=1
        fi
    done

    # ── Phase 3: re-render MASTER from snapshot ───────────────────────
    # Picks up cloud_mail_full.md (and future url/sec-network md) the
    # derives just produced, plus any slices they merged into _run_state.json,
    # and re-emits cloud_health_daily.{html,_web.html,md,json} with the
    # appendix Z-sections filled in.
    if [ -d "$SRC_DIR/$MASTER" ]; then
        echo ""
        echo "══════════════════════════════════════════"
        echo "  $MASTER (render-only) — Phase 3"
        echo "══════════════════════════════════════════"
        REPORTS_RENDER_ONLY=1 sh "$SRC_DIR/$MASTER/build.sh" run || \
            echo "WARN: render-only re-pass failed (Pass-1 outputs preserved)"
    fi

    generate_manifest
    return $rc
}

cmd_one() {
    crate="$1"
    action="${2:-all}"
    sh "$SRC_DIR/$crate/build.sh" "$action"
    generate_manifest
}

# Regenerate reports/manifest.json from *.md files in dist/.
generate_manifest() {
    [ -d "$DIST_DIR" ] || return 0
    printf '[\n' > "$MANIFEST"
    first=true
    for md in "$DIST_DIR"/*.md; do
        [ -f "$md" ] || continue
        name=$(basename "$md" .md | tr '_' ' ')
        # Path as the Pages site sees it. The reports moved under y_old/ when
        # the old APIs were archived; this stayed on the pre-move path, so
        # every link the site drew from here 404'd.
        file="y_old/reports/dist/$(basename "$md")"
        if [ "$first" = true ]; then first=false; else printf ',\n' >> "$MANIFEST"; fi
        printf '  {"file": "%s", "name": "%s"}' "$file" "$name" >> "$MANIFEST"
    done
    printf '\n]\n' >> "$MANIFEST"
    echo "Generated manifest.json ($(grep -c '{"file' "$MANIFEST") entries)"
}

# Verify the shared dist/ layout.
test_dists() {
    fail=0
    [ -d "$DIST_DIR" ] || { echo "FAIL: reports/dist/ missing"; exit 1; }
    [ -d "$DIST_DIR/bin" ] || { echo "FAIL: reports/dist/bin/ missing"; exit 1; }

    for c in $(list_crate_dirs); do
        # Per-crate binary lookup: main.rs crate name matches folder OR BINARY in build.sh
        binary=$(awk -F= '/^BINARY=/ { gsub(/"/,"",$2); print $2; exit }' "$SRC_DIR/$c/build.sh")
        [ -z "$binary" ] && binary="$c"
        if [ ! -e "$DIST_DIR/bin/$binary" ]; then
            echo "FAIL $c: dist/bin/$binary missing"
            fail=1
            continue
        fi
        # Templates live under src/ (resolved via TEMPLATE_DIR at run time).
        # Assert templates ARE NOT copied or symlinked into dist/.
        for tpl in "$SRC_DIR/$c"/*.md.tpl; do
            [ -f "$tpl" ] || continue
            t_name=$(basename "$tpl")
            if [ -e "$DIST_DIR/$t_name" ]; then
                echo "FAIL $c: dist/$t_name should not exist (templates stay in src/)"
                fail=1
            fi
        done
        echo "OK   $c (bin: $binary)"
    done
    [ "$fail" -eq 0 ] && echo "test-dists: PASS" || { echo "test-dists: FAIL"; exit 1; }
}

cmd_android() {
    # Cross-compile EVERY workspace binary for Android in one cargo
    # invocation — far cheaper than fanning out one cargo per crate.
    # Outputs end up at reports/dist/android/<abi>/lib<binary-snake>.so,
    # named so the Cloud-SuperApp APK can drop them under jniLibs/<abi>/
    # and have Android's PackageManager extract + chmod them on install.
    command -v cargo-ndk >/dev/null 2>&1 || {
        echo "ERROR: cargo-ndk not on PATH (cargo install cargo-ndk)" >&2; exit 1
    }
    [ -n "${ANDROID_NDK_HOME:-${NDK_HOME:-}}" ] || {
        echo "ERROR: ANDROID_NDK_HOME / NDK_HOME unset" >&2; exit 1
    }

    echo ""
    echo "══════════════════════════════════════════"
    echo "  workspace cross-compile (arm64-v8a + armeabi-v7a)"
    echo "══════════════════════════════════════════"
    cargo android --manifest-path "$SRC_DIR/Cargo.toml" --workspace || {
        echo "FAIL: workspace android cross-compile failed"; exit 1;
    }

    target_root="${CARGO_TARGET_DIR:-$HOME/.cargo/target}"
    out_root="$DIST_DIR/android"

    for c in $(list_crate_dirs); do
        bin=$(awk -F= '/^BINARY=/ { gsub(/"/,"",$2); print $2; exit }' "$SRC_DIR/$c/build.sh")
        [ -z "$bin" ] && bin="$c"
        lib_name="lib$(echo "$bin" | tr '-' '_').so"
        for triple_abi in \
            "aarch64-linux-android:arm64-v8a" \
            "armv7-linux-androideabi:armeabi-v7a"; do
            triple="${triple_abi%%:*}"
            abi="${triple_abi##*:}"
            src="$target_root/$triple/release-android/$bin"
            if [ -f "$src" ]; then
                mkdir -p "$out_root/$abi"
                cp "$src" "$out_root/$abi/$lib_name"
                size=$(stat -c%s "$src" 2>/dev/null || stat -f%z "$src" 2>/dev/null || echo "?")
                echo "→ android/$abi/$lib_name ($size bytes, from $bin)"
            fi
        done
    done

    echo ""
    echo "Done. Copy reports/dist/android/<abi>/*.so into the Cloud-SuperApp APK:"
    echo "  aa_cloud-superapp/app/src/main/jniLibs/<abi>/"
}

target="${1:-all}"

case "$target" in
    all)        cmd_all all ;;
    build)      cmd_all build ;;
    android)    cmd_android ;;
    sec)        cmd_one cloud-sec-data-report all ;;
    list)       cmd_list ;;
    manifest)   generate_manifest ;;
    test-dists) test_dists ;;
    help|-h|--help)
        sed -n '2,/^set -eu/p' "$0" | sed 's/^# \?//' | head -n -1 ;;
    *)
        crate=$(resolve_target "$target" || true)
        if [ -z "$crate" ]; then
            echo "Unknown target: $target" >&2
            echo "Run: $0 list" >&2
            exit 1
        fi
        cmd_one "$crate" all
        ;;
esac
