#!/usr/bin/env bash
# Godot Director autoplay · framework-owned: replaced on upgrade.
#
#   bash tools/autoplay.sh <scenario>|--all [--seed N] [--steps N] [--no-images] [--size WxH]
#   bash tools/autoplay.sh --replay <run folder> [--until <step>] [--from-save] [--no-images]
#   bash tools/autoplay.sh --list               the scenarios in tools/autoplay_scenarios.gd
# Exit codes: 0 = clean · 1 = findings or failures · 3 = couldn't run (no Godot, Godot older than
# 4.5, or no display; --no-images plays headless)
#
# It launches the real game through its main scene and plays a scenario through the game's adapter
# (tools/autoplay_adapter.gd): ui actions by real input, api actions through the game's systems
# (tools/autoplay.gd says how). Each run writes the play log, screenshots with their element maps,
# and repro.json on any finding to playtesting/autoplay/<scenario>-<seed>-<datetime>/ (gitignored).
# --all runs every scenario, one Godot run each. While the game's adapter still has the seed's
# start_run(), there is no run to play: it says what to wire, writes nothing and exits 0. A replay plays the scenario again with the run's
# seeds and its recorded actions, so expects and smoke's checks are made again; --from-save starts
# from the save written before the first finding that has one (through the adapter's load_save())
# and replays the recorded actions from that step. The game's user:// folder is pointed at a temporary
# folder that is deleted afterwards, so autoplay reads and writes no player data. AUTOPLAY_TIMEOUT
# (seconds, default 600) limits each Godot run when GNU timeout is available. Godot is found as
# tools/check.sh finds it: $GODOT_BIN, else the first line of tools/godot_bin.local, else `godot`
# on PATH.

set -u
caller_dir="$(pwd)"
cd "$(dirname "$0")/.." || exit 3
state_dir=".godot/godot-director"
limit="${AUTOPLAY_TIMEOUT:-600}"

images=1; list=0; all=0; scenario=""; replay=""
count=$#
while [ "$count" -gt 0 ]; do   # --all is ours; everything else goes to tools/autoplay.gd
  arg="$1"; shift; count=$((count - 1))
  case "$arg" in
    --all|all) all=1; continue ;;
    --no-images) images=0 ;;
    --list) list=1 ;;
    --replay)
      if [ "$count" -gt 0 ]; then
        replay="$1"; shift; count=$((count - 1))
        # A folder named from the caller's folder, or absolute (Git Bash's /c/... becomes C:/...).
        if [ -d "$caller_dir/$replay" ] && [ ! -d "$replay" ]; then replay="$caller_dir/$replay"; fi
        case "$replay" in /*) command -v cygpath >/dev/null 2>&1 && replay="$(cygpath -m "$replay")" ;; esac
        set -- "$@" "$arg" "$replay"; continue
      fi ;;
    --seed|--steps|--size|--until)
      if [ "$count" -gt 0 ]; then set -- "$@" "$arg" "$1"; shift; count=$((count - 1)); continue; fi ;;
    -h|--help) sed -n '2,7p' "$0"; exit 0 ;;
    -*) ;;
    *) scenario="$arg" ;;
  esac
  set -- "$@" "$arg"
done
if [ "$all" -eq 1 ] && { [ -n "$scenario" ] || [ -n "$replay" ]; }; then
  echo "autoplay: --all runs every scenario; leave out the scenario and --replay" >&2
  exit 1
fi
if [ "$all" -eq 0 ] && [ "$list" -eq 0 ] && [ -z "$scenario" ] && [ -z "$replay" ]; then
  echo "autoplay: name a scenario, or --all (bash tools/autoplay.sh --list lists them)" >&2
  exit 1
fi

# --- find Godot (as tools/check.sh does) --------------------------------------------------------
godot="${GODOT_BIN:-}"
if [ -z "$godot" ] && [ -f tools/godot_bin.local ]; then
  godot="$(LC_ALL=C tr -d '\000\376\377' < tools/godot_bin.local \
    | awk 'NR == 1 { sub(/^\357\273\277/, ""); sub(/[ \t\r]+$/, ""); print; exit }')"
fi
[ -n "$godot" ] || godot="godot"
if ! command -v "$godot" >/dev/null 2>&1 && [ ! -x "$godot" ]; then
  echo "autoplay: can't find Godot ('$godot'). Run: bash tools/setup-clone.sh" >&2
  exit 3
fi
version="$("$godot" --headless --version 2>/dev/null </dev/null | tr -d '\r' | grep -E '^[0-9]+\.[0-9]+' | tail -n 1)"
major="${version%%.*}"; rest="${version#*.}"; minor="${rest%%.*}"
case "$major" in ''|*[!0-9]*) major="" ;; esac
case "$minor" in ''|*[!0-9]*) minor="" ;; esac
if [ -z "$major" ] || [ -z "$minor" ]; then
  echo "autoplay: couldn't read a version from '$godot' (on Windows, use the *_console.exe build)." >&2
  exit 3
fi
if [ "$major" -lt 4 ] || { [ "$major" -eq 4 ] && [ "$minor" -lt 5 ]; }; then
  echo "autoplay: needs Godot 4.5 or newer; '$godot' is $version." >&2
  exit 3
fi
if [ ! -f project.godot ]; then
  echo "autoplay: no project.godot in $(pwd)." >&2
  exit 1
fi

# --- a display ----------------------------------------------------------------------------------
display_args="--headless"
wrapper=""
if [ "$images" -eq 1 ] && [ "$list" -eq 0 ]; then
  display_args="--windowed"
  case "$(uname -s)" in
    Linux*|*BSD*)
      if [ -z "${DISPLAY:-}" ] && [ -z "${WAYLAND_DISPLAY:-}" ]; then
        if command -v xvfb-run >/dev/null 2>&1; then
          wrapper="xvfb-run"
        else
          echo "autoplay: there is no display, and xvfb-run isn't installed (it provides one). Install" >&2
          echo "          xvfb, or run on a machine with a display; --no-images plays headless." >&2
          exit 3
        fi
      fi ;;
  esac
fi

# --- one Godot run at a time (the check, capture and autoplay share .godot/) --------------------
mkdir -p "$state_dir" || exit 3
# GDIR_LOCK_HELD=1: tools/check.sh runs this inside its own lock (it holds the lock itself).
held=0; [ "${GDIR_LOCK_HELD:-}" = "1" ] && held=1
lock="$state_dir/lock"
waited=0
until [ "$held" -eq 1 ] || mkdir "$lock" 2>/dev/null; do
  holder="$(cat "$lock/pid" 2>/dev/null)"
  if [ -n "$holder" ] && ! kill -0 "$holder" 2>/dev/null; then rm -rf "$lock"; continue; fi
  if [ "$waited" -ge $((limit * 2 + 60)) ]; then
    echo "autoplay: another check, capture or autoplay has run for too long. If none is running, delete $lock." >&2
    exit 3
  fi
  [ "$waited" -eq 0 ] && echo "autoplay: waiting for a check, capture or autoplay to finish..."
  sleep 2; waited=$((waited + 2))
done
[ "$held" -eq 1 ] || echo $$ > "$lock/pid"
[ "$held" -eq 1 ] || trap 'rm -rf "$lock"' EXIT

timeout_cmd=""
for candidate in timeout gtimeout; do   # GNU only: Windows' timeout.exe is something else
  if "$candidate" --version 2>/dev/null | grep -qi coreutils; then timeout_cmd="$candidate"; break; fi
done
run_godot() { # run_godot <log file> <wrapper or ""> <godot arguments...>
  local log="$1" with="$2"; shift 2
  if [ -n "$with" ]; then
    xvfb-run -a -s "-screen 0 1920x1080x24" ${timeout_cmd:+"$timeout_cmd" "$limit"} "$godot" "$@" </dev/null >"$log" 2>&1
  elif [ -n "$timeout_cmd" ]; then
    "$timeout_cmd" "$limit" "$godot" "$@" </dev/null >"$log" 2>&1
  else
    "$godot" "$@" </dev/null >"$log" 2>&1
  fi
}

# An import pass first, as the check does, so a fresh clone has its import cache and class list.
[ "$held" -eq 1 ] || run_godot "$state_dir/autoplay_import.log" "" --headless --path . --import   # the check has just done it
# Only the autoplay runs get a temporary user:// folder, deleted afterwards.
user_dir="$(mktemp -d)"
if [ "$held" -eq 1 ]; then trap 'rm -rf "$user_dir"' EXIT; else trap 'rm -rf "$lock" "$user_dir"' EXIT; fi
if command -v cygpath >/dev/null 2>&1; then APPDATA="$(cygpath -w "$user_dir")"; else APPDATA="$user_dir"; fi
XDG_DATA_HOME="$user_dir"
export APPDATA XDG_DATA_HOME
esc="$(printf '\033')"
printf '%s\n' "ObjectDB instances leaked at exit" "resources still in use at exit" "Pages in use exist at exit" \
  > "$state_dir/autoplay_allow.txt"
[ -f tools/check.ignore ] && grep -v '^[[:space:]]*#' tools/check.ignore | grep -v '^[[:space:]]*$' >> "$state_dir/autoplay_allow.txt"

# play <args...>: one Godot run of tools/autoplay.gd; prints its lines and returns 0, 1 or 3.
play() {
  local status log errors
  # A relative script path on purpose: Git Bash would rewrite some res:// forms.
  # --fixed-fps: every frame advances the game by 1/60 s, so Tweens, Timers and physics move the
  # same on every run, headless or not, however fast the machine is.
  run_godot "$state_dir/autoplay.log" "$wrapper" $display_args --fixed-fps 60 --path . --script tools/autoplay.gd -- "$@"
  status=$?
  log="$(tr -d '\r' < "$state_dir/autoplay.log" | sed "s/${esc}\[[0-9;]*m//g")"
  if [ "$status" -eq 3 ]; then
    printf '%s\n' "$log" | sed -n 's/^GDIR-AUTOPLAY-SKIP: /autoplay: /p' >&2
    return 3
  fi
  # Godot that couldn't open a window or start its renderer never reaches the script.
  if [ "$status" -ne 0 ] && ! printf '%s\n' "$log" | grep -q '^GDIR-AUTOPLAY' \
      && printf '%s\n' "$log" | grep -qiE "(create|open|initiali[sz]e).*(window|display|context|rendering|renderer|opengl|vulkan|d3d12|metal)|video card driver"; then
    echo "autoplay: Godot couldn't open a window or start its renderer here (see $state_dir/autoplay.log);" >&2
    echo "          --no-images plays headless." >&2
    return 3
  fi
  if [ "$list" -eq 1 ]; then
    printf '%s\n' "$log" | sed -n -e 's/^GDIR-AUTOPLAY-LIST: //p' -e 's/^GDIR-AUTOPLAY-FAIL: /autoplay: FAIL: /p'
    [ "$status" -eq 0 ] && return 0 || return 1
  fi
  printf '%s\n' "$log" | sed -n -e 's/^GDIR-AUTOPLAY: /autoplay: /p' -e 's/^GDIR-AUTOPLAY-FAIL: /autoplay: FAIL: /p'
  [ "$status" -eq 124 ] && echo "autoplay: FAIL: Godot timed out after ${limit}s (AUTOPLAY_TIMEOUT)" && return 1
  if [ "$status" -eq 0 ] && ! printf '%s\n' "$log" | grep -qE '^GDIR-AUTOPLAY: .* (finding|skipped)'; then
    echo "autoplay: FAIL: tools/autoplay.gd didn't finish (see $state_dir/autoplay.log)"
    return 1
  fi
  # Errors the game's play log didn't catch (before it started, or at exit) still fail a clean run.
  errors="$(printf '%s\n' "$log" | awk -v allowfile="$state_dir/autoplay_allow.txt" '
    BEGIN { count = 0; while ((getline line < allowfile) > 0) if (line != "") allowed_text[count++] = line }
    function allowed(text,   i) { for (i = 0; i < count; i++) if (index(text, allowed_text[i]) > 0) return 1; return 0 }
    /^[ \t]*(ERROR|SCRIPT ERROR|USER ERROR|USER SCRIPT ERROR):|Parse Error/ && !allowed($0) { print "  " $0 }' | head -n 10)"
  if [ "$status" -eq 0 ] && [ -n "$errors" ]; then
    echo "autoplay: FAIL: Godot printed errors the run didn't report (see $state_dir/autoplay.log):"
    printf '%s\n' "$errors"
    return 1
  fi
  [ "$status" -eq 0 ] && return 0 || return 1
}

if [ "$all" -eq 0 ]; then
  play "$@"
  exit $?
fi
# --all: list the scenarios (headless), then one run each.
shown="$display_args"; shown_wrapper="$wrapper"
display_args="--headless"; wrapper=""; list=1
play --list > "$state_dir/autoplay_list.txt"
status=$?
display_args="$shown"; wrapper="$shown_wrapper"; list=0
if [ "$status" -ne 0 ]; then cat "$state_dir/autoplay_list.txt"; exit "$status"; fi
failed=0
for id in $(sed -n 's/^\([a-z0-9_]*\) · .*/\1/p' "$state_dir/autoplay_list.txt"); do
  play "$id" "$@"
  status=$?
  if [ "$status" -eq 3 ]; then exit 3; fi
  [ "$status" -eq 0 ] || failed=1
done
exit "$failed"
