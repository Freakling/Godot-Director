#!/usr/bin/env bash
# Godot Director autoplay · framework-owned: replaced on upgrade.
#
#   bash tools/autoplay.sh <scenario>...|--all [--seed N] [--steps N] [--no-images] [--size WxH]
#   bash tools/autoplay.sh --replay <run folder> [--until <step>] [--from-save] [--no-images]
#   bash tools/autoplay.sh --list               the scenarios in tools/autoplay_scenarios.gd
# Exit codes: 0 = clean · 1 = findings or failures · 3 = couldn't run (no Godot, Godot older than
# 4.5, or no display; --no-images plays headless)
#
# It launches the real game through its main scene and plays a scenario through the game's adapter
# (tools/autoplay_adapter.gd): ui actions by real input, api actions through the game's systems
# (tools/autoplay.gd says how). Each run writes the play log, screenshots with their element maps,
# and repro.json on any finding to playtesting/autoplay/<scenario>-<seed>-<datetime>/ (gitignored).
# --all runs every scenario, one Godot run each. Several scenarios (or --all) play side by side: one
# lock and one import check, then one Godot process per scenario at the same time, each with its own
# user:// folder, log and run folder, at most as many as the CPU count (AUTOPLAY_JOBS sets another
# number). Each scenario's lines are printed in the order given; the exit code is the worst (3, then
# 1, then 0). One scenario plays as it always did. While the game's adapter still has the seed's
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

images=1; list=0; all=0; scenario=""; replay=""; scenarios=""; nscen=0
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
    *) scenario="$arg"; scenarios="$scenarios $arg"; nscen=$((nscen + 1)) ;;
  esac
  set -- "$@" "$arg"
done
if [ "$nscen" -gt 1 ] && [ -n "$replay" ]; then
  echo "autoplay: --replay plays one run; leave out the scenarios" >&2
  exit 1
fi
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

# An import pass first, as the check does, so a fresh clone has its import cache and class list. The
# check has just done it when it runs this (held); otherwise it is skipped when nothing Godot imports
# has changed since the last pass that exited 0.
# >>> import skip (shared: check.sh, autoplay.sh and ui_capture.sh carry these lines; selftest.sh compares them)
# import_fingerprint: a hash of what the import pass and Godot's global class cache depend on, over the
# files tracked or untracked-not-ignored: the files Godot imports (all but scripts, scenes, resources
# read directly, .cfg and .md files, .uid files and .godot/, plus project.godot, which holds the import
# settings); the path of every script with its class_name, extends and @icon lines (what the class
# cache records, so a body-only edit doesn't count); and the paths of scenes and shaders. Empty outside
# a git repository.
import_fingerprint() {
  git rev-parse --is-inside-work-tree >/dev/null 2>&1 || return 0
  local all imported gd decl scenes
  all="$(git -c core.quotePath=false ls-files -z -c -o --exclude-standard 2>/dev/null | tr '\0' '\n' \
    | while IFS= read -r path; do [ -f "$path" ] && printf '%s\n' "$path"; done)"
  imported="$( { printf '%s\n' "$all" | grep -v -E '^$|^\.godot/|\.(gd|tscn|scn|tres|res|gdshader|gdshaderinc|godot|cfg|md|uid)$'; \
    [ -f project.godot ] && echo project.godot; } )"
  [ -n "$imported" ] || return 0
  gd="$(printf '%s\n' "$all" | grep -E '\.gd$')"
  decl="$(git -c core.quotePath=false grep --untracked -E '^(class_name|extends|@icon)' -- '*.gd' 2>/dev/null)"
  scenes="$(printf '%s\n' "$all" | grep -E '\.(gdshader|gdshaderinc|tscn|scn)$')"
  { printf '%s\n' "$imported"; printf '%s\n' "$imported" | git hash-object --no-filters --stdin-paths; \
    printf '%s\n' "$gd" "$decl" "$scenes"; } | git hash-object --stdin
}
# import_skip: 0 when the import pass can be skipped: .godot/imported exists, and the fingerprint is
# the one stored after the last import pass that exited 0 (so a fresh clone never skips).
import_skip() {
  local now
  [ -e .godot/imported ] || return 1
  now="$(import_fingerprint)"
  [ -n "$now" ] && [ "$now" = "$(cat "$state_dir/import-fingerprint" 2>/dev/null)" ]
}
# import_record <exit status of the import pass>: store the fingerprint after a pass that exited 0,
# and forget the stored one after any other.
import_record() {
  local now
  if [ "$1" -ne 0 ]; then rm -f "$state_dir/import-fingerprint"; return 0; fi
  now="$(import_fingerprint)"
  [ -n "$now" ] && printf '%s' "$now" > "$state_dir/import-fingerprint"
  return 0
}
# <<< import skip
if [ "$held" -eq 0 ]; then
  if import_skip; then
    echo "autoplay: import pass skipped (no imported file changed)"
  else
    run_godot "$state_dir/autoplay_import.log" "" --headless --path . --import
    import_record "$?"
  fi
fi
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

play_log="$state_dir/autoplay.log"
# play <args...>: one Godot run of tools/autoplay.gd; prints its lines and returns 0, 1 or 3.
play() {
  local status log errors
  # A relative script path on purpose: Git Bash would rewrite some res:// forms.
  # --fixed-fps: every frame advances the game by 1/60 s, so Tweens, Timers and physics move the
  # same on every run, headless or not, however fast the machine is.
  run_godot "$play_log" "$wrapper" $display_args --fixed-fps 60 --path . --script tools/autoplay.gd -- "$@"
  status=$?
  log="$(tr -d '\r' < "$play_log" | sed "s/${esc}\[[0-9;]*m//g")"
  if [ "$status" -eq 3 ]; then
    printf '%s\n' "$log" | sed -n 's/^GDIR-AUTOPLAY-SKIP: /autoplay: /p' >&2
    return 3
  fi
  # Godot that couldn't open a window or start its renderer never reaches the script.
  if [ "$status" -ne 0 ] && ! printf '%s\n' "$log" | grep -q '^GDIR-AUTOPLAY' \
      && printf '%s\n' "$log" | grep -qiE "(create|open|initiali[sz]e).*(window|display|context|rendering|renderer|opengl|vulkan|d3d12|metal)|video card driver"; then
    echo "autoplay: Godot couldn't open a window or start its renderer here (see $play_log);" >&2
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
    echo "autoplay: FAIL: tools/autoplay.gd didn't finish (see $play_log)"
    return 1
  fi
  # Errors the game's play log didn't catch (before it started, or at exit) still fail a clean run.
  errors="$(printf '%s\n' "$log" | awk -v allowfile="$state_dir/autoplay_allow.txt" '
    BEGIN { count = 0; while ((getline line < allowfile) > 0) if (line != "") allowed_text[count++] = line }
    function allowed(text,   i) { for (i = 0; i < count; i++) if (index(text, allowed_text[i]) > 0) return 1; return 0 }
    /^[ \t]*(ERROR|SCRIPT ERROR|USER ERROR|USER SCRIPT ERROR):|Parse Error/ && !allowed($0) { print "  " $0 }' | head -n 10)"
  if [ "$status" -eq 0 ] && [ -n "$errors" ]; then
    echo "autoplay: FAIL: Godot printed errors the run didn't report (see $play_log):"
    printf '%s\n' "$errors"
    return 1
  fi
  [ "$status" -eq 0 ] && return 0 || return 1
}

if [ "$all" -eq 0 ] && [ "$nscen" -le 1 ]; then
  play "$@"
  status=$?
  [ "$status" -eq 0 ] || rm -f "$state_dir/import-fingerprint"   # a failing run may leave the class cache stale
  exit "$status"
fi
# --all or several scenarios: the ids to play, in the order given (a repeated name plays once).
ids=""
if [ "$all" -eq 1 ]; then
  # List the scenarios (headless) first.
  shown="$display_args"; shown_wrapper="$wrapper"
  display_args="--headless"; wrapper=""; list=1
  play --list > "$state_dir/autoplay_list.txt"
  status=$?
  display_args="$shown"; wrapper="$shown_wrapper"; list=0
  if [ "$status" -ne 0 ]; then cat "$state_dir/autoplay_list.txt"; exit "$status"; fi
  ids="$(sed -n 's/^\([a-z0-9_]*\) · .*/\1/p' "$state_dir/autoplay_list.txt")"
else
  for id in $scenarios; do
    case " $(echo $ids) " in *" $id "*) ;; *) ids="$ids $id" ;; esac
  done
  # The options without the scenario names (the values of --seed, --steps, --size and --until stay).
  count=$#
  while [ "$count" -gt 0 ]; do
    arg="$1"; shift; count=$((count - 1))
    case "$arg" in
      --seed|--steps|--size|--until)
        if [ "$count" -gt 0 ]; then set -- "$@" "$arg" "$1"; shift; count=$((count - 1)); continue; fi ;;
      -*) ;;
      *) continue ;;
    esac
    set -- "$@" "$arg"
  done
fi
# One Godot process per scenario at the same time, at most as many as the CPU count: each has its
# own user:// folder, play log (autoplay-<n>.log) and, from tools/autoplay.gd, run folder, and writes
# its lines to its own files, printed in order once all have finished.
cap="${AUTOPLAY_JOBS:-}"
[ -n "$cap" ] || cap="$(nproc 2>/dev/null)"
[ -n "$cap" ] || cap="${NUMBER_OF_PROCESSORS:-}"
[ -n "$cap" ] || cap="$(getconf _NPROCESSORS_ONLN 2>/dev/null || sysctl -n hw.ncpu 2>/dev/null)"
case "$cap" in ''|*[!0-9]*) cap=1 ;; esac
[ "$cap" -ge 1 ] || cap=1
results="$(mktemp -d)"
if [ "$held" -eq 1 ]; then trap 'rm -rf "$user_dir" "$results"' EXIT; else trap 'rm -rf "$lock" "$user_dir" "$results"' EXIT; fi
run_one() { # run_one <n> <scenario> <options...>: one scenario in a subshell with its own user:// folder
  local n="$1" id="$2"; shift 2
  (
    one_dir="$(mktemp -d)"
    trap 'rm -rf "$one_dir"' EXIT
    if command -v cygpath >/dev/null 2>&1; then APPDATA="$(cygpath -w "$one_dir")"; else APPDATA="$one_dir"; fi
    XDG_DATA_HOME="$one_dir"
    export APPDATA XDG_DATA_HOME
    play_log="$state_dir/autoplay-$n.log"
    play "$id" "$@" > "$results/$n.out" 2> "$results/$n.err"
    echo $? > "$results/$n.status"
  )
}
total=0; pids=""
for id in $ids; do
  if [ "$total" -ge "$cap" ]; then   # a free slot: wait for the run that started $cap places earlier
    wait $(echo $pids | cut -d ' ' -f $((total - cap + 1)))
  fi
  run_one "$total" "$id" "$@" &
  pids="$pids $!"; total=$((total + 1))
done
wait
failed=0; n=0
while [ "$n" -lt "$total" ]; do
  cat "$results/$n.out"; cat "$results/$n.err" >&2
  status="$(cat "$results/$n.status" 2>/dev/null)"; [ -n "$status" ] || status=1
  if [ "$status" -eq 3 ]; then failed=3
  elif [ "$status" -ne 0 ] && [ "$failed" -eq 0 ]; then failed=1; fi
  n=$((n + 1))
done
[ "$failed" -eq 0 ] || rm -f "$state_dir/import-fingerprint"
exit "$failed"
