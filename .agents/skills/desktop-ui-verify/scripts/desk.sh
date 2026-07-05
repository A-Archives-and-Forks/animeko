#!/usr/bin/env bash
# Desktop UI verification toolbox for the Animeko client (macOS).
# Wraps build/launch/screenshot/click/type/quit/logs so an agent can drive the desktop app.
# Run `desk.sh help` for the command list.
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
PROC="${ANI_DESKTOP_PROCESS:-Ani}"
OUT_DIR="${ANI_UI_OUT_DIR:-${TMPDIR:-/tmp}/animeko-ui-verify}"

cmd="${1:-help}"
shift || true

window_origin() { # prints "x y" of window 1 of $PROC, or fails
  osascript <<OSA
tell application "System Events"
  tell process "$PROC"
    set p to position of window 1
    return (item 1 of p as text) & " " & (item 2 of p as text)
  end tell
end tell
OSA
}

case "$cmd" in
  build)
    "$SCRIPT_DIR/build_desktop_distributable.sh" "$@"
    ;;

  app)
    "$SCRIPT_DIR/find_desktop_app.sh" "$@"
    ;;

  launch)
    "$SCRIPT_DIR/launch_desktop_app.sh" "$@"
    ;;

  screenshot|shot)
    out="${1:-$OUT_DIR/desktop-$(date +%Y%m%d-%H%M%S).png}"
    "$SCRIPT_DIR/capture_macos_window.sh" "$out" "$PROC" "${2:-1440}" "${3:-900}" >&2
    echo "$out"
    ;;

  click)
    x="${1:?usage: desk.sh click <x> <y>   (window points; screenshot PNG px / 2)}"
    y="${2:?y}"
    read -r wx wy < <(window_origin) || { echo "cannot locate $PROC window (Accessibility permission?)" >&2; exit 1; }
    osascript <<OSA
tell application "System Events"
  tell process "$PROC"
    set frontmost to true
    click at {$((wx + x)), $((wy + y))}
  end tell
end tell
OSA
    echo "clicked window point ($x,$y) = screen ($((wx + x)),$((wy + y)))"
    ;;

  type)
    t="${1:?usage: desk.sh type <ascii-text>}"
    esc="${t//\\/\\\\}"
    esc="${esc//\"/\\\"}"
    osascript -e "tell application \"System Events\"
      tell process \"$PROC\" to set frontmost to true
      keystroke \"$esc\"
    end tell"
    echo "typed: $t"
    ;;

  key)
    name="${1:?usage: desk.sh key return|tab|esc|space|delete|up|down|left|right}"
    case "$name" in
      return) code=36 ;; tab) code=48 ;; esc) code=53 ;; space) code=49 ;;
      delete) code=51 ;; up) code=126 ;; down) code=125 ;; left) code=123 ;; right) code=124 ;;
      *) echo "unknown key: $name" >&2; exit 2 ;;
    esac
    osascript -e "tell application \"System Events\"
      tell process \"$PROC\" to set frontmost to true
      key code $code
    end tell"
    echo "pressed $name"
    ;;

  quit)
    "$SCRIPT_DIR/quit_desktop_app.sh" "${1:-$PROC}"
    ;;

  logs)
    n="${1:-100}"
    log="$(ls -t "$HOME/Library/Application Support/"*Ani*/logs/*.log 2>/dev/null | head -1 || true)"
    if [[ -z "$log" ]]; then # dev-run (:app:desktop:run) sandbox
      repo_root="$(cd "$SCRIPT_DIR/../../../.." && pwd)"
      log="$(ls -t "$repo_root/app/desktop/test-sandbox/logs/"*.log 2>/dev/null | head -1 || true)"
    fi
    [[ -n "$log" ]] || { echo "no desktop log file found" >&2; exit 1; }
    echo "=== $log ===" >&2
    tail -n "$n" "$log"
    ;;

  help|*)
    cat <<'EOF'
Animeko desktop UI verification toolbox (macOS). Set ANI_DESKTOP_PROCESS to override the process name (default Ani).
click/type/key/screenshot need macOS Accessibility permission for the terminal running them.

  build [gradle args]         build the distributable .app (JCEF JBR auto-selected)
  app                         print the built .app path
  launch [app]                open the .app and wait for the process
  screenshot [out.png] [w h]  activate+resize window, capture it; prints PNG path (Read it to see the window)
  click <x> <y>               click at window-relative POINTS (screenshot PNG pixels / 2 on retina)
  type <ascii>                keystroke text into the frontmost window (ASCII only)
  key return|tab|esc|space|delete|up|down|left|right
  quit [process]              quit the app (graceful, then pkill)
  logs [n]                    tail newest app log (Application Support .../logs, or test-sandbox for dev runs)
EOF
    ;;
esac
