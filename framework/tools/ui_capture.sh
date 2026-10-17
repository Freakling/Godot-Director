#!/usr/bin/env bash
# Godot Director screen capture · framework-owned: replaced on upgrade.
#
#   bash tools/ui_capture.sh [<screen>|--all] [--state <name>] [--size <W>x<H>]   capture (default --all)
#   bash tools/ui_capture.sh ... --no-images    element maps and lint only; needs no display
#   bash tools/ui_capture.sh --list             the screens in the catalog
#   bash tools/ui_capture.sh --missing          the screen scenes the catalog doesn't cover (never fails)
#   bash tools/ui_capture.sh <screen> --verify  capture the screen, then check it against its spec
#                                               (design/ui/<screen>.md) and write the compare images
# Exit codes: 0 = done (lint findings don't count) · 1 = a screen failed, or --verify found
# deviations · 3 = couldn't run (no Godot, Godot older than 4.5, or no display), or --verify had no
# spec or capture to check
#
# For every screen in tools/ui_screens.gd, state and size in tools/ui_capture.cfg, it writes
# <id>[.<state>]@<W>x<H> .png, .elements.json, .map.png and .lint.txt to design/ui/captures/
# (.godot-director/procedures/ui-design.md). Godot needs a display, since headless Godot renders
# nothing; on Linux without one it uses xvfb-run when that is installed. Screens are rendered
# offscreen at each size, so sizes larger than the monitor capture too. The game's user:// folder
# is pointed at a temporary folder that is deleted afterwards, so a capture reads and writes no
# player data. A screen whose setup prints a script error, or doesn't finish, fails, and the error
# goes to the top of its .lint.txt. CAPTURE_TIMEOUT (seconds, default 600) limits each Godot run when GNU timeout
# is available. Godot is found as tools/check.sh finds it: $GODOT_BIN, else the first line of
# tools/godot_bin.local, else `godot` on PATH.

set -u
cd "$(dirname "$0")/.." || exit 3
state_dir=".godot/godot-director"
out_dir="design/ui/captures"
limit="${CAPTURE_TIMEOUT:-600}"

images=1; list=0; verify=0; screen_arg=""
count=$#
while [ "$count" -gt 0 ]; do   # --verify is ours; everything else goes to tools/ui_capture.gd
  arg="$1"; shift; count=$((count - 1))
  case "$arg" in
    --verify) verify=1; continue ;;
    --no-images) images=0 ;;
    --list|--missing) list=1 ;;
    --state|--size)
      if [ "$count" -gt 0 ]; then set -- "$@" "$arg" "$1"; shift; count=$((count - 1)); continue; fi ;;
    -h|--help) sed -n '2,10p' "$0"; exit 0 ;;
    -*) ;;
    *) screen_arg="$arg" ;;
  esac
  set -- "$@" "$arg"
done
if [ "$verify" -eq 1 ] && { [ -z "$screen_arg" ] || [ "$screen_arg" = "all" ] || [ "$list" -eq 1 ]; }; then
  echo "ui_capture: --verify takes one screen: bash tools/ui_capture.sh <screen> --verify" >&2
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
  echo "ui_capture: can't find Godot ('$godot'). Run: bash tools/setup-clone.sh" >&2
  exit 3
fi
version="$("$godot" --headless --version 2>/dev/null </dev/null | tr -d '\r' | grep -E '^[0-9]+\.[0-9]+' | tail -n 1)"
major="${version%%.*}"; rest="${version#*.}"; minor="${rest%%.*}"
case "$major" in ''|*[!0-9]*) major="" ;; esac
case "$minor" in ''|*[!0-9]*) minor="" ;; esac
if [ -z "$major" ] || [ -z "$minor" ]; then
  echo "ui_capture: couldn't read a version from '$godot' (on Windows, use the *_console.exe build)." >&2
  exit 3
fi
if [ "$major" -lt 4 ] || { [ "$major" -eq 4 ] && [ "$minor" -lt 5 ]; }; then
  echo "ui_capture: needs Godot 4.5 or newer; '$godot' is $version." >&2
  exit 3
fi
if [ ! -f project.godot ]; then
  echo "ui_capture: no project.godot in $(pwd)." >&2
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
          echo "ui_capture: there is no display, and xvfb-run isn't installed (it provides one). Install" >&2
          echo "            xvfb, or run on a machine with a display; --no-images maps and lints without one." >&2
          exit 3
        fi
      fi ;;
  esac
fi

# --- one Godot run at a time (the check and capture share .godot/) -----------------------------
mkdir -p "$state_dir" || exit 3
lock="$state_dir/lock"
waited=0
until mkdir "$lock" 2>/dev/null; do
  holder="$(cat "$lock/pid" 2>/dev/null)"
  if [ -n "$holder" ] && ! kill -0 "$holder" 2>/dev/null; then rm -rf "$lock"; continue; fi
  if [ "$waited" -ge $((limit * 2 + 60)) ]; then
    echo "ui_capture: another check or capture has run for too long. If none is running, delete $lock." >&2
    exit 3
  fi
  [ "$waited" -eq 0 ] && echo "ui_capture: waiting for a check or capture to finish..."
  sleep 2; waited=$((waited + 2))
done
echo $$ > "$lock/pid"
trap 'rm -rf "$lock"' EXIT

timeout_cmd=""
for candidate in timeout gtimeout; do   # GNU only: Windows' timeout.exe is something else
  if "$candidate" --version 2>/dev/null | grep -qi coreutils; then timeout_cmd="$candidate"; break; fi
done
run_godot() { # run_godot <log file> <wrapper or ""> <godot arguments...>
  local log="$1" with="$2"; shift 2
  if [ -n "$with" ]; then
    xvfb-run -a -s "-screen 0 1280x720x24" ${timeout_cmd:+"$timeout_cmd" "$limit"} "$godot" "$@" </dev/null >"$log" 2>&1
  elif [ -n "$timeout_cmd" ]; then
    "$timeout_cmd" "$limit" "$godot" "$@" </dev/null >"$log" 2>&1
  else
    "$godot" "$@" </dev/null >"$log" 2>&1
  fi
}

# An import pass first, as the check does, so a fresh clone has its import cache and class list.
run_godot "$state_dir/ui_import.log" "" --headless --path . --import
# Only the capture run gets a temporary user:// folder, deleted afterwards: nothing it runs reads
# or writes the player's data.
user_dir="$(mktemp -d)"
trap 'rm -rf "$lock" "$user_dir"' EXIT
if command -v cygpath >/dev/null 2>&1; then APPDATA="$(cygpath -w "$user_dir")"; else APPDATA="$user_dir"; fi
XDG_DATA_HOME="$user_dir"
export APPDATA XDG_DATA_HOME
# A relative script path on purpose: Git Bash would rewrite some res:// forms.
run_godot "$state_dir/ui_capture.log" "$wrapper" $display_args --path . --script tools/ui_capture.gd -- "$@"
status=$?

esc="$(printf '\033')"
log="$(tr -d '\r' < "$state_dir/ui_capture.log" | sed "s/${esc}\[[0-9;]*m//g")"
if [ "$status" -eq 3 ]; then
  printf '%s\n' "$log" | sed -n 's/^GDIR-UI-SKIP: /ui_capture: /p' >&2
  exit 3
fi
# Godot that couldn't open a window or start its renderer never reaches the script.
if [ "$status" -ne 0 ] && ! printf '%s\n' "$log" | grep -q '^GDIR-UI' \
    && printf '%s\n' "$log" | grep -qiE "(create|open|initiali[sz]e).*(window|display|context|rendering|renderer|opengl|vulkan|d3d12|metal)|video card driver"; then
  echo "ui_capture: Godot couldn't open a window or start its renderer here (see $state_dir/ui_capture.log);" >&2
  echo "            --no-images maps and lints without one." >&2
  exit 3
fi
if [ "$list" -eq 1 ]; then
  printf '%s\n' "$log" | sed -n -e 's/^GDIR-UI-LIST: //p' -e 's/^GDIR-UI-MISSING: /missing: /p' -e 's/^GDIR-UI-NOTE: /note: /p'
  printf '%s\n' "$log" | sed -n 's/^GDIR-UI-FAIL: /ui_capture: FAIL: /p'
  exit "$([ "$status" -eq 0 ] && echo 0 || echo 1)"
fi

# Errors Godot printed while a screen was set up and captured go to the top of its .lint.txt. The
# same allowlist as the check: engine noise at exit, and tools/check.ignore.
failed=0
[ "$status" -eq 0 ] || failed=1
[ "$status" -eq 124 ] && echo "ui_capture: Godot timed out after ${limit}s" >&2
printf '%s\n' "ObjectDB instances leaked at exit" "resources still in use at exit" "Pages in use exist at exit" \
  > "$state_dir/ui_allow.txt"
[ -f tools/check.ignore ] && grep -v '^[[:space:]]*#' tools/check.ignore | grep -v '^[[:space:]]*$' >> "$state_dir/ui_allow.txt"
errors="$(printf '%s\n' "$log" | awk -v allowfile="$state_dir/ui_allow.txt" '
  BEGIN { count = 0; while ((getline line < allowfile) > 0) if (line != "") allowed_text[count++] = line }
  function allowed(text,   i) { for (i = 0; i < count; i++) if (index(text, allowed_text[i]) > 0) return 1; return 0 }
  /^GDIR-UI: begin / { screen = $3; next }
  /^GDIR-UI: end / { screen = ""; next }
  keep && /^[ \t]+at: / { print where "\t" $0; keep = 0; next }
  { keep = 0 }
  /^[ \t]*(ERROR|SCRIPT ERROR|USER ERROR|USER SCRIPT ERROR):|Parse Error/ && !allowed($0) {
    where = (screen == "" ? "-" : screen); print where "\t" $0; keep = 1
  }')"
if [ -n "$errors" ]; then
  failed=1
  for screen in $(printf '%s\n' "$errors" | cut -f 1 | LC_ALL=C sort -u); do
    [ "$screen" = "-" ] && continue
    file="$out_dir/$screen.lint.txt"
    { printf '%s\n' "$errors" | awk -F '\t' -v s="$screen" '$1 == s { sub(/^[ \t]+/, "", $2); print "error: " $2 }'
      [ -f "$file" ] && cat "$file"; } > "$state_dir/ui_lint.tmp"
    mv "$state_dir/ui_lint.tmp" "$file"
    echo "ui_capture: FAIL: $screen: its setup printed errors (top of $file)"
  done
fi

printf '%s\n' "$log" | sed -n -e 's/^GDIR-UI: end /ui_capture: /p' -e 's/^GDIR-UI: /ui_capture: /p' \
  -e 's/^GDIR-UI-NOTE: /ui_capture: note: /p' -e 's/^GDIR-UI-FAIL: /ui_capture: FAIL: /p' | grep -v '^ui_capture: begin '
if [ -n "$errors" ] && printf '%s\n' "$errors" | grep -q '^-'; then
  echo "ui_capture: errors outside any screen (see $state_dir/ui_capture.log):"
  printf '%s\n' "$errors" | awk -F '\t' '$1 == "-" { print "  " $2 }' | head -n 20
fi
if [ "$failed" -eq 0 ] && ! printf '%s\n' "$log" | grep -q '^GDIR-UI: [0-9]* capture'; then
  echo "ui_capture: tools/ui_capture.gd didn't finish (see $state_dir/ui_capture.log)"
  failed=1
fi
if [ "$verify" -eq 1 ] && [ "$failed" -eq 0 ]; then
  # Reads the spec and the element maps and lint files just written; headless, it also writes the
  # compare images (it draws with Image operations only).
  run_godot "$state_dir/ui_verify.log" "" --headless --path . --script tools/ui_verify.gd -- "$@"
  status=$?
  vlog="$(tr -d '\r' < "$state_dir/ui_verify.log" | sed "s/${esc}\[[0-9;]*m//g")"
  printf '%s\n' "$vlog" | sed -n -e 's/^GDIR-UI-VERIFY: //p' -e 's/^GDIR-UI-FAIL: /ui_capture: FAIL: /p'
  if [ "$status" -eq 3 ]; then exit 3; fi
  if [ "$status" -ne 0 ]; then failed=1; fi
fi
exit "$failed"
