#!/bin/zsh
# Measure Gitā CPU %, RSS MiB, and idle wakeups using the ps -o time= + top method.
# Runs against the installed Release build in /Applications/Gita.app.
# Usage:
#   scripts/perf.sh idle
#   scripts/perf.sh panel
#   scripts/perf.sh panel-closed
#   scripts/perf.sh window
#   scripts/perf.sh after-close
#   scripts/perf.sh cycle
#   scripts/perf.sh soak
# Environment overrides:
#   PERF_IDLE_MAX=1.0   PERF_PANEL_MAX=3.0   PERF_WINDOW_MAX=5.0
set -euo pipefail

ROOT=${0:A:h:h}
APP_NAME="Gita"
BUNDLE_ID="dev.clevermechanisms.Gita"
APP="/Applications/$APP_NAME.app"
EXEC_PATH="$APP/Contents/MacOS/$APP_NAME"
OUT="$ROOT/build/perf"
mkdir -p "$OUT"

PERF_IDLE_MAX=${PERF_IDLE_MAX:-1.0}
PERF_PANEL_MAX=${PERF_PANEL_MAX:-3.0}
PERF_WINDOW_MAX=${PERF_WINDOW_MAX:-5.0}

[[ -d "$APP" ]] || { print -u2 "Installed release app not found at $APP (run scripts/install.sh first)"; exit 1; }
BUILD=$(plutil -extract CFBundleVersion raw "$APP/Contents/Info.plist" 2>/dev/null || echo "unknown")

app_pid() {
  pgrep -f -- "$EXEC_PATH" | head -n 1
}

cpu_s() {
  ps -o time= -p "$1" | awk '{ n=split($1,a,":"); s=0; for(i=1;i<=n;i++) s=s*60+a[i]; printf "%.6f\n", s }'
}

measure() { # <label> <settle_secs> <sample_secs> <budget_pct>
  local label=$1 settle=$2 secs=$3 budget=$4
  (( settle > 0 )) && sleep "$settle"
  local pid
  pid=$(app_pid) || { print -u2 "$APP_NAME is not running"; return 1; }
  [[ -n "$pid" ]] || { print -u2 "$APP_NAME is not running"; return 1; }
  local a b rss_kib rss_mib pct top_line idlew
  a=$(cpu_s "$pid")
  sleep "$secs"
  b=$(cpu_s "$pid")
  rss_kib=$(ps -o rss= -p "$pid" | tr -d ' ')
  rss_mib=$(( rss_kib / 1024 ))
  pct=$(awk -v a="$a" -v b="$b" -v s="$secs" 'BEGIN { printf "%.2f", (b - a) / s * 100.0 }')
  top_line=$(top -l 2 -s 3 -pid "$pid" -stats cpu,idlew | tail -1 | awk '{$1=$1; print}')
  idlew=$(print -r -- "$top_line" | awk '{print $2}' | tr -dc '0-9')
  [[ -n "$idlew" ]] || idlew=0

  printf '%-14s %6.2f%%  (budget %s%%)  rss %d MiB  idlew %s  top[%s]\n' \
    "$label" "$pct" "$budget" "$rss_mib" "$idlew" "$top_line"

  local log_file="$OUT/$(date +%F).jsonl"
  printf '{"state":"%s","cpu":%s,"budget":%s,"rssMiB":%d,"rssKiB":%d,"idleWakeups":%d,"build":"%s","at":"%s"}\n' \
    "$label" "$pct" "$budget" "$rss_mib" "$rss_kib" "$idlew" "$BUILD" "$(date -u +%FT%TZ)" >> "$log_file"

  if ! awk -v p="$pct" -v b="$budget" 'BEGIN { exit !(p <= b) }'; then
    print -u2 "over budget: $label (${pct}% > ${budget}%)"
    return 1
  fi
}

ax() {
  osascript -e "tell application \"System Events\" to tell (first process whose bundle identifier is \"$BUNDLE_ID\") to $1" >/dev/null
}

panel() {
  ax 'click menu bar item 1 of menu bar 2'
}

esc() {
  osascript -e 'tell application "System Events" to key code 53' >/dev/null
}

relaunch_background() {
  pkill -f -- "$EXEC_PATH" 2>/dev/null || true
  sleep 2
  open -g "$APP" --args --background
}

case "${1:-cycle}" in
  idle)
    relaunch_background
    measure idle 12 60 "$PERF_IDLE_MAX"
    ;;
  panel)
    panel
    measure panel 5 30 "$PERF_PANEL_MAX"
    ;;
  panel-closed)
    panel
    sleep 5
    esc
    measure panel-closed 8 60 "$PERF_IDLE_MAX"
    ;;
  window)
    open "$APP"
    measure window 8 30 "$PERF_WINDOW_MAX"
    ;;
  after-close)
    for i in 1 2; do
      open "$APP"
      sleep 6
      ax 'keystroke "w" using {command down, shift down}'
      measure "after-close-$i" 8 60 "$PERF_IDLE_MAX"
    done
    ;;
  cycle)
    for state in idle panel panel-closed window after-close; do
      "$0" "$state"
    done
    ;;
  soak)
    relaunch_background
    for i in {1..360}; do
      measure soak 0 5 "$PERF_IDLE_MAX" || true
    done
    ;;
  -h|--help)
    echo "Usage: scripts/perf.sh <idle|panel|panel-closed|window|after-close|cycle|soak>"
    ;;
  *)
    print -u2 "Unknown mode: $1 (expected idle|panel|panel-closed|window|after-close|cycle|soak)"
    exit 2
    ;;
esac
