#!/bin/bash
# Set the MuteMe LED color/effect via hidapitester. Run with no arguments for help.
#
# Protocol (MuteMe Original, vid:pid 3603:0001): a 2-byte output report
# [0x00, color+effect]. The Original only has 3-bit color (R/G/B on or off), so
# only the 7 named colors exist.
# MuteMe-Client.app holds the device open, so it is quit before any LED write.
# Fails silently so a disconnected/busy device never breaks a Claude Code hook.

APP_NAME="MuteMe-Client"
APP_PATTERN="/Applications/MuteMe-Client.app/"
BG_FILE="${TMPDIR:-/tmp}/mm-bg.pid"
CONFIG_FILE="$HOME/.muteme.cfg"

# HID MuteMe models that use this byte protocol, from the official client's device list
# (3603:*) and older firmware (20a0:*, 16c0:*). The MuteMe Click uses a different
# protocol and is skipped by name.
KNOWN_DEVICES="3603:0001 3603:0006 3603:0007 3603:0010 3603:0011 20a0:42da 20a0:42db 16c0:27db"

# Defaults when ~/.muteme.cfg doesn't exist; run 'detect' to write it.
VIDPID="3603:0001"
SERIAL=""

load_config() {
  [[ -f "$CONFIG_FILE" ]] || return 0
  local key value
  while IFS='=' read -r key value; do
    case "$key" in
      VIDPID) VIDPID=$value ;;
      SERIAL) SERIAL=$value ;;
    esac
  done <"$CONFIG_FILE"
}

# hidapitester's --serial only filters --list; --open ignores it and takes the first
# vid:pid match. So look up the saved serial's current path (it changes on replug) and
# open that. Falls back to vid:pid if the serial isn't plugged in.
resolve_target() {
  [[ -n "$TARGET_RESOLVED" ]] && return 0
  TARGET_RESOLVED=1
  TARGET=(--vidpid "$VIDPID")
  [[ -n "$SERIAL" ]] || return 0
  local path
  path=$(hidapitester --vidpid "$VIDPID" --serial "$SERIAL" --list-detail 2>/dev/null |
    awk '$1 == "path:" { print $2; exit }')
  [[ -n "$path" ]] && TARGET=(--open-path "$path")
}

load_config

help() {
  local me config
  me=$(basename "$0")
  if [[ -f "$CONFIG_FILE" ]]; then config="from $CONFIG_FILE"; else config="default; run '$me detect'"; fi
  cat <<EOF
Control the MuteMe LED via hidapitester.
Device: $VIDPID${SERIAL:+ serial $SERIAL} ($config)

Usage: $me <command> [effect] [seconds]

Commands:
  <color> [effect] [seconds]   Set a color: red, green, yellow, blue, purple, cyan, white
  processing [seconds]         Pulsing yellow  (Claude Code: working)
  success [seconds]            Pulsing green   (Claude Code: done)
  needinput [seconds]          Pulsing red     (Claude Code: needs input)
  party [seconds]              Cycle through a rainbow (default 10 seconds), then turn off
  off                          Turn the LED off
  start                        (Re)start MuteMe-Client.app and hand the LED back to it
  stop                         Quit MuteMe-Client.app without changing the LED
  detect                       Find the MuteMe, flash it white, save it to ~/.muteme.cfg
  test                         Step through every option, asking whether each one worked
  help, -h, --help             Show this help

Effects (default: solid):
  solid              Full brightness
  dim                Low brightness
  pulse              Fast pulse
  slowpulse          Slow pulse

Seconds (whole number): turn the LED off after that long. Returns immediately and
turns off in the background (except party, which runs in the foreground). Without
seconds the LED stays on until the next command. Slow pulse is kept alive by a
background re-send every 4 seconds. Any later command cancels background work.

Every command except help quits MuteMe-Client.app first, because it holds the
device open. Run '$me start' to give the LED back to the app.

Examples:
  $me green
  $me red pulse
  $me cyan slowpulse 10
  $me success 5
  $me party 8
EOF
}

usage_error() {
  echo "$(basename "$0"): $1" >&2
  echo >&2
  help >&2
  exit 1
}

stop_app() {
  pgrep -f "$APP_PATTERN" >/dev/null || return 0
  pkill -x "$APP_NAME"
  # Wait for the helper processes to exit so the HID handle is released and the app's
  # own shutdown write (LED off) can't land after ours.
  for _ in {1..30}; do
    pgrep -f "$APP_PATTERN" >/dev/null || return 0
    sleep 0.1
  done
  pkill -9 -f "$APP_PATTERN"
  sleep 0.2
}

write_report() {
  resolve_target
  local open=(--open)
  [[ "${TARGET[0]}" == --open-path ]] && open=()
  hidapitester "${TARGET[@]}" "${open[@]}" -l 2 --send-output "0,$1" 2>&1 | grep -q "wrote 2 bytes"
}

# One line per HID device: vid:pid|serial|name (lowercase hex, no 0x).
list_devices() {
  hidapitester --list-detail 2>/dev/null | awk '
    function flush() { if (vid != "") print vid ":" pid "|" serial "|" name }
    /^[^ \t]/ { flush(); vid = pid = serial = ""; name = $0; sub(/^[^:]*: */, "", name) }
    $1 == "vendorId:"      { vid = tolower($2); sub(/^0x/, "", vid) }
    $1 == "productId:"     { pid = tolower($2); sub(/^0x/, "", pid) }
    $1 == "serial_number:" { serial = $2 }
    END { flush() }' | sort -u
}

detect() {
  stop_app
  local found=() id serial name
  while IFS='|' read -r id serial name; do
    [[ " $KNOWN_DEVICES " == *" $id "* ]] || continue
    [[ "$name" == *Click* ]] && continue
    found+=("$id|$serial|$name")
  done < <(list_devices)

  if (( ${#found[@]} == 0 )); then
    echo "No MuteMe found. Is it plugged in? Config not changed." >&2
    exit 1
  fi
  if (( ${#found[@]} > 1 )); then
    echo "Found ${#found[@]} MuteMe devices, using the first:"
    printf '  %s\n' "${found[@]}"
  fi

  IFS='|' read -r VIDPID SERIAL name <<<"${found[0]}"
  TARGET_RESOLVED=""
  echo "Found $name ($VIDPID${SERIAL:+, serial $SERIAL}). Flashing it white..."
  if ! write_report 7; then
    echo "Couldn't write to it (another app may have it open). Config not changed." >&2
    exit 1
  fi
  sleep 1
  write_report 0

  cat >"$CONFIG_FILE" <<EOF
# Written by $(basename "$0") detect on $(date '+%Y-%m-%d %H:%M')
# Device: $name
VIDPID=$VIDPID
SERIAL=$SERIAL
EOF
  echo "Saved to $CONFIG_FILE"
}

is_slowpulse() { (( ($1 & 0x30) == 0x30 )); }

send() {
  stop_app
  write_report "$1"
  # Slow pulse only starts once the value is re-sent with 0x40 set, but that same bit
  # also arms a ~10 second firmware auto-off. So only slow pulse gets it, and
  # run_background re-sends it to keep it alive.
  if is_slowpulse "$1"; then
    sleep 0.1
    write_report $(( $1 + 0x40 ))
  fi
}

cancel_background() {
  [[ -f "$BG_FILE" ]] || return 0
  local pid
  pid=$(<"$BG_FILE")
  rm -f "$BG_FILE"
  # Guard against PID reuse: only kill it if it is still one of ours.
  if [[ "$pid" =~ ^[0-9]+$ ]] &&
    ps -o command= -p "$pid" 2>/dev/null | grep -qE "(^|/)$(basename "$0")( |$)"; then
    pkill -P "$pid" 2>/dev/null
    kill "$pid" 2>/dev/null
  fi
}

# Background job for code $1: re-sends slow pulse every 4 seconds (before the
# firmware's auto-off) and/or turns the LED off after $2 seconds. Runs until then or
# until the next command cancels it. Detached with all fds closed so a Claude Code
# hook calling this returns immediately.
run_background() {
  local code=$1 secs=$2
  is_slowpulse "$code" || [[ -n "$secs" ]] || return 0
  (
    deadline=$(( SECONDS + ${secs:-0} ))
    while :; do
      nap=4
      if [[ -n "$secs" ]]; then
        left=$(( deadline - SECONDS ))
        (( left <= 0 )) && break
        if (( left < nap )) || ! is_slowpulse "$code"; then nap=$left; fi
      fi
      sleep "$nap"
      [[ -n "$secs" ]] && (( SECONDS >= deadline )) && break
      send "$code"
    done
    rm -f "$BG_FILE"
    send 0
  ) </dev/null >/dev/null 2>&1 &
  echo $! >"$BG_FILE"
  disown
}

# "what you should see|arguments to this script"
TEST_STEPS=(
  "Solid red|red"
  "Solid green|green"
  "Solid yellow|yellow"
  "Solid blue|blue"
  "Solid purple|purple"
  "Solid cyan|cyan"
  "Solid white|white"
  "Dim white|white dim"
  "Fast-pulsing cyan|cyan pulse"
  "Slow-pulsing cyan|cyan slowpulse"
  "processing: fast-pulsing yellow|processing"
  "success: fast-pulsing green|success"
  "needinput: fast-pulsing red|needinput"
  "Solid green that turns itself off after 3 seconds|green 3"
  "Party: solid rainbow colors cycling for 3 seconds, then off|party 3"
  "Off|off"
  "start: MuteMe-Client.app launches and takes over the LED (give it a few seconds)|start"
  "stop: MuteMe-Client.app quits and the LED is left as the app set it|stop"
  "detect: finds the MuteMe, flashes it white for 1 second, saves ~/.muteme.cfg|detect"
)

run_tests() {
  if ! { : </dev/tty; } 2>/dev/null; then
    echo "$(basename "$0") test needs an interactive terminal." >&2
    exit 1
  fi
  local total=${#TEST_STEPS[@]} n=0 step desc cmdline key failed=()
  local -a args
  echo "Watch the MuteMe. After each step: y or Enter = worked, n = didn't. Ctrl-C to quit."
  for step in "${TEST_STEPS[@]}"; do
    n=$((n + 1))
    desc=${step%%|*}
    cmdline=${step#*|}
    read -ra args <<<"$cmdline"
    echo
    echo "[$n/$total] $desc"
    echo "    running: $(basename "$0") $cmdline"
    "$0" "${args[@]}"
    while true; do
      printf '    Worked? [Y/n] '
      IFS= read -rsn1 key </dev/tty
      case "$key" in
        ""|y|Y) echo "y"; break ;;
        n|N)    echo "n"; failed+=("[$n] $desc ($cmdline)"); break ;;
        *)      echo ;;
      esac
    done
  done
  "$0" off
  echo
  if (( ${#failed[@]} == 0 )); then
    echo "All $total steps worked."
    return 0
  fi
  echo "$(( total - ${#failed[@]} ))/$total worked. Failed:"
  printf '  %s\n' "${failed[@]}"
  return 1
}

color_code() {
  case "$1" in
    red)    echo 1 ;;
    green)  echo 2 ;;
    yellow) echo 3 ;;
    blue)   echo 4 ;;
    purple) echo 5 ;;
    cyan)   echo 6 ;;
    white)  echo 7 ;;
    *)      return 1 ;;
  esac
}

effect_code() {
  case "${1:-solid}" in
    solid)     echo 0 ;;
    dim)       echo 16 ;;
    pulse)     echo 32 ;;
    slowpulse) echo 48 ;;
    *)         return 1 ;;
  esac
}

if [[ $# -eq 0 ]]; then
  help
  exit 0
fi

cmd=$1
shift
effect_arg=""
secs=""
for arg in "$@"; do
  if [[ "$arg" =~ ^[0-9]+$ ]]; then
    [[ -z "$secs" ]] || usage_error "more than one duration given"
    (( arg > 0 )) || usage_error "duration must be at least 1 second"
    secs=$arg
  elif [[ -z "$effect_arg" ]] && effect_code "$arg" >/dev/null; then
    effect_arg=$arg
  else
    usage_error "unknown effect or duration '$arg'"
  fi
done

no_effect()   { [[ -z "$effect_arg" ]] || usage_error "'$cmd' doesn't take an effect"; }
no_duration() { [[ -z "$secs" ]] || usage_error "'$cmd' doesn't take a duration"; }

# Validate everything before touching the device, so a typo doesn't cancel a pending
# turn-off or quit MuteMe-Client.
case "$cmd" in
  help|-h|--help) help; exit 0 ;;
  start|stop|detect|test) no_effect; no_duration ;;
  off)       no_effect; no_duration; code=0 ;;
  party)      no_effect ;;
  processing) no_effect; code=35 ;; # yellow + pulse
  success)    no_effect; code=34 ;; # green + pulse
  needinput)  no_effect; code=33 ;; # red + pulse
  *)
    effect=$(effect_code "$effect_arg")
    color=$(color_code "$cmd") || usage_error "unknown command or color '$cmd'"
    code=$((color + effect))
    ;;
esac

cancel_background

case "$cmd" in
  start)
    stop_app
    open -g -a "$APP_NAME"
    ;;
  stop)
    stop_app
    ;;
  detect)
    detect
    ;;
  test)
    run_tests
    exit
    ;;
  party)
    # All 7 colors (1 red, 2 green, 3 yellow, 4 blue, 5 purple, 6 cyan, 7 white) in a
    # shuffled order with no color twice in a row, including across the wrap-around.
    rainbow=(5 2 7 1 6 3 4 7 2 5 1 3 6 7 4 2 1 5 3 7 6 1 4 6)
    offset=$(( RANDOM % ${#rainbow[@]} ))
    sleep "${secs:-10}" &
    party_timer=$!
    for ((i = 0; ; i++)); do
      kill -0 "$party_timer" 2>/dev/null || break
      send "${rainbow[(i + offset) % ${#rainbow[@]}]}"
      sleep 0.07
    done
    send 0
    ;;
  *)
    send "$code"
    run_background "$code" "$secs"
    ;;
esac
exit 0
