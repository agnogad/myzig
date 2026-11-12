#!/usr/bin/env bash
# Runs every example under a headless display and checks that it starts, loads
# its page and reports no error.
#
#   scripts/smoke.sh            # every example
#   scripts/smoke.sh plugins    # one example
#
# Needs Xvfb and (for the web examples) WebKitGTK. Exits non-zero on the first
# failure, so it works as a CI gate.
set -uo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
cd "$ROOT"

DISPLAY_NUM=${DISPLAY_NUM:-99}
TIMEOUT=${SMOKE_TIMEOUT:-12}
LOG_DIR=${SMOKE_LOG_DIR:-$(mktemp -d)}
FAILED=0
PASSED=0

start_display() {
    if [ -n "${DISPLAY:-}" ] && xdpyinfo >/dev/null 2>&1; then
        return
    fi
    if ! pgrep -f "Xvfb :$DISPLAY_NUM" >/dev/null 2>&1; then
        Xvfb ":$DISPLAY_NUM" -screen 0 1280x800x24 >/dev/null 2>&1 &
        sleep 1
    fi
    export DISPLAY=":$DISPLAY_NUM"
}

# Programs in zig-out/bin that are not GUI applications. `myzig` is the command
# line tool: it is checked below rather than opened as a window.
not_gui="myzig"

run_one() {
    local name=$1
    local bin="$ROOT/zig-out/bin/$name"
    local log="$LOG_DIR/$name.log"

    if [ ! -x "$bin" ]; then
        echo "FAIL $name: not built (zig build install)"
        FAILED=$((FAILED + 1))
        return
    fi

    env -u WAYLAND_DISPLAY -u XDG_SESSION_TYPE \
        GDK_BACKEND=x11 \
        WEBKIT_DISABLE_DMABUF_RENDERER=1 \
        WEBKIT_DISABLE_COMPOSITING_MODE=1 \
        "$bin" >"$log" 2>&1 &
    local pid=$!

    # Give it time to create its window and load its page, then check it is
    # still alive: a crash on startup is the failure this catches.
    sleep "$TIMEOUT"
    local alive=1
    kill -0 "$pid" 2>/dev/null || alive=0

    # A page error means the bridge or the frontend is broken, which is exactly
    # what a smoke test should catch before a user does.
    local errors
    errors=$(grep -a -c "CONSOLE JS ERROR" "$log" 2>/dev/null || true)

    kill "$pid" 2>/dev/null
    wait "$pid" 2>/dev/null

    if [ "$alive" -eq 0 ]; then
        echo "FAIL $name: exited early; see $log"
        tail -5 "$log" | sed 's/^/    /'
        FAILED=$((FAILED + 1))
        return
    fi
    if [ "${errors:-0}" -gt 0 ]; then
        echo "FAIL $name: page reported a script error; see $log"
        grep -a "CONSOLE JS ERROR" "$log" | head -3 | sed 's/^/    /'
        FAILED=$((FAILED + 1))
        return
    fi

    echo "ok   $name"
    PASSED=$((PASSED + 1))
}

main() {
    start_display
    echo "display=$DISPLAY logs=$LOG_DIR"

    local names=("$@")
    if [ ${#names[@]} -eq 0 ]; then
        names=()
        # A cross-compile for Windows leaves `.exe` and `.pdb` files beside
        # the native ones; neither can run here, so both are skipped. Debug
        # symbol files are not programs at all.
        while IFS= read -r n; do
            case "$n" in
                *.exe|*.pdb|*.dll|*.dSYM) continue ;;
            esac
            names+=("$n")
        done < <(ls "$ROOT/zig-out/bin")
    fi

    for n in "${names[@]}"; do
        case " $not_gui " in
            *" $n "*) continue ;;
        esac
        run_one "$n"
    done

    # The command line tool is checked by running it: a GUI test would only
    # prove it can be started.
    if [ -x "$ROOT/zig-out/bin/myzig" ]; then
        if "$ROOT/zig-out/bin/myzig" version >/dev/null 2>&1 &&
           "$ROOT/zig-out/bin/myzig" help >/dev/null 2>&1; then
            echo "ok   myzig (cli)"
            PASSED=$((PASSED + 1))
        else
            echo "FAIL myzig (cli)"
            FAILED=$((FAILED + 1))
        fi
    fi

    echo
    echo "$PASSED passed, $FAILED failed"
    [ "$FAILED" -eq 0 ]
}

main "$@"
