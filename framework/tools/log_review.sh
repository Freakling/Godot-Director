#!/usr/bin/env bash
# Godot Director log review · framework-owned: replaced on upgrade.
#
#   bash tools/log_review.sh [<run folder or .jsonl>|--latest|--player] [--check sig-xxxxxxxx]
# Exit codes: 0 = reviewed (--check: the signature is absent) · 1 = --check: the signature is
# present · 2 = bad arguments, or --check names a signature that isn't in playtesting/signatures.tsv ·
# 3 = couldn't run (no Godot, Godot older than 4.5, or no log to review)
#
# It reads a play log's JSONL and writes review.md and findings.json next to it: a timeline in turns
# and views, the findings grouped by signature, the coverage, and the delta against the previous
# autoplay run of the same scenario (tools/log_review.gd says how). Signatures are recorded in
# playtesting/signatures.tsv; --check sig-xxxxxxxx then says whether one is in the log reviewed, so a
# fix can be confirmed. Without an argument it reviews the newest autoplay run (--latest).
#   <run folder or .jsonl>  that run's newest run-*.jsonl, or that file
#   --latest                the newest folder in playtesting/autoplay/
#   --player                the newest run-*.jsonl a person played, in the game's real user://logs/play
#                           (found from application/config/name and use_custom_user_dir in
#                           project.godot), where review.md and findings.json are written too
# Nothing is sent anywhere. Godot is found as tools/check.sh finds it: $GODOT_BIN, else the first
# line of tools/godot_bin.local, else `godot` on PATH.

set -u
caller_dir="$(pwd)"
cd "$(dirname "$0")/.." || exit 3
state_dir=".godot/godot-director"
limit="${LOG_REVIEW_TIMEOUT:-120}"

target=""; mode=""; check=""; log=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --latest) mode="latest"; shift ;;
    --player) mode="player"; shift ;;
    --check)
      if [ "$#" -lt 2 ]; then echo "log_review: --check needs a signature (sig- and eight hex digits)" >&2; exit 2; fi
      check="$2"; shift 2 ;;
    -h|--help) sed -n '2,5p' "$0"; exit 0 ;;
    -*) echo "log_review: unknown argument $1 (bash tools/log_review.sh --help)" >&2; exit 2 ;;
    *)
      if [ -n "$target" ]; then echo "log_review: name one log" >&2; exit 2; fi
      target="$1"; shift ;;
  esac
done
if [ -n "$target" ] && [ -n "$mode" ]; then echo "log_review: name one log: a run folder or .jsonl, --latest or --player" >&2; exit 2; fi
if [ -n "$check" ]; then
  case "$check" in
    sig-[0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f]) ;;
    *) echo "log_review: $check isn't a signature (sig- and eight hex digits)" >&2; exit 2 ;;
  esac
fi

# A path Godot can read: absolute, in the form the platform's Godot wants (C:/... on Windows).
absolute() { # absolute <path>: prints it, or returns 1 when nothing is there
  local path="$1"
  case "$path" in
    /*|[A-Za-z]:*) ;;
    *) [ -e "$caller_dir/$path" ] && path="$caller_dir/$path" ;;
  esac
  [ -e "$path" ] || return 1
  if [ -d "$path" ]; then path="$(cd "$path" && pwd)"; else path="$(cd "$(dirname "$path")" && pwd)/$(basename "$path")"; fi
  if command -v cygpath >/dev/null 2>&1; then path="$(cygpath -m "$path")"; fi
  printf '%s' "$path"
}

if [ "$mode" = "player" ]; then
  [ -f project.godot ] || { echo "log_review: no project.godot in $(pwd)." >&2; exit 3; }
  setting() { sed -n "s/^config\\/$1=\\(.*\\)\$/\\1/p" project.godot | tr -d '\r' | head -n 1; }
  unquote() { printf '%s' "$1" | sed -e 's/^"//' -e 's/"[[:space:]]*$//'; }
  name="$(unquote "$(setting name)")"
  custom_on="$(setting use_custom_user_dir)"
  custom_name="$(unquote "$(setting custom_user_dir_name)")"
  if [ -z "$name" ] && { [ "$custom_on" != "true" ] || [ -z "$custom_name" ]; }; then
    echo "log_review: project.godot has no application/config/name, so the game's user:// folder can't be found." >&2
    exit 3
  fi
  # Godot's user data folders: standard is <data>/Godot/app_userdata/<name> (godot on Linux), and
  # use_custom_user_dir puts <custom_user_dir_name> straight under <data>.
  case "$(uname -s)" in
    MINGW*|MSYS*|CYGWIN*)
      data="$(cygpath -u "${APPDATA:-}")"; standard="$data/Godot/app_userdata" ;;
    Darwin)
      data="$HOME/Library/Application Support"; standard="$data/Godot/app_userdata" ;;
    *)
      data="${XDG_DATA_HOME:-$HOME/.local/share}"; standard="$data/godot/app_userdata" ;;
  esac
  if [ "$custom_on" = "true" ] && [ -n "$custom_name" ]; then
    user_dir="$data/$custom_name"
  else
    # The name is a folder name: Godot replaces the characters a folder can't have with a hyphen.
    safe="$(printf '%s' "$name" | sed -e 's#[\\/:*?"<>|]#-#g' -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
    user_dir="$standard/$safe"
  fi
  if [ ! -d "$user_dir/logs/play" ]; then
    echo "log_review: no play logs in $user_dir/logs/play (play the game first)." >&2
    exit 3
  fi
  play_dir="$(absolute "$user_dir/logs/play")" || exit 3
elif [ "$mode" != "latest" ] && [ -n "$target" ]; then
  log="$(absolute "$target")" || { echo "log_review: $target isn't a run folder or a .jsonl file." >&2; exit 3; }
fi

# --- find Godot (as tools/check.sh does) --------------------------------------------------------
godot="${GODOT_BIN:-}"
if [ -z "$godot" ] && [ -f tools/godot_bin.local ]; then
  godot="$(LC_ALL=C tr -d '\000\376\377' < tools/godot_bin.local \
    | awk 'NR == 1 { sub(/^\357\273\277/, ""); sub(/[ \t\r]+$/, ""); print; exit }')"
fi
[ -n "$godot" ] || godot="godot"
if ! command -v "$godot" >/dev/null 2>&1 && [ ! -x "$godot" ]; then
  echo "log_review: can't find Godot ('$godot'). Run: bash tools/setup-clone.sh" >&2
  exit 3
fi
version="$("$godot" --headless --version 2>/dev/null </dev/null | tr -d '\r' | grep -E '^[0-9]+\.[0-9]+' | tail -n 1)"
major="${version%%.*}"; rest="${version#*.}"; minor="${rest%%.*}"
case "$major" in ''|*[!0-9]*) major="" ;; esac
case "$minor" in ''|*[!0-9]*) minor="" ;; esac
if [ -z "$major" ] || [ -z "$minor" ]; then
  echo "log_review: couldn't read a version from '$godot' (on Windows, use the *_console.exe build)." >&2
  exit 3
fi
if [ "$major" -lt 4 ] || { [ "$major" -eq 4 ] && [ "$minor" -lt 5 ]; }; then
  echo "log_review: needs Godot 4.5 or newer; '$godot' is $version." >&2
  exit 3
fi
if [ ! -f project.godot ]; then
  echo "log_review: no project.godot in $(pwd)." >&2
  exit 3
fi

# --- one Godot run at a time (the check, capture, autoplay and the review share .godot/) --------
needs_import=0
[ -f .godot/global_script_class_cache.cfg ] || needs_import=1
mkdir -p "$state_dir" || exit 3
lock="$state_dir/lock"
waited=0
until mkdir "$lock" 2>/dev/null; do
  holder="$(cat "$lock/pid" 2>/dev/null)"
  if [ -n "$holder" ] && ! kill -0 "$holder" 2>/dev/null; then rm -rf "$lock"; continue; fi
  if [ "$waited" -ge $((limit * 2 + 60)) ]; then
    echo "log_review: another check, capture or autoplay has run for too long. If none is running, delete $lock." >&2
    exit 3
  fi
  [ "$waited" -eq 0 ] && echo "log_review: waiting for a check, capture or autoplay to finish..."
  sleep 2; waited=$((waited + 2))
done
echo $$ > "$lock/pid"
trap 'rm -rf "$lock"' EXIT

timeout_cmd=""
for candidate in timeout gtimeout; do   # GNU only: Windows' timeout.exe is something else
  if "$candidate" --version 2>/dev/null | grep -qi coreutils; then timeout_cmd="$candidate"; break; fi
done
run_godot() { # run_godot <log file> <godot arguments...>
  local out="$1"; shift
  if [ -n "$timeout_cmd" ]; then
    "$timeout_cmd" "$limit" "$godot" "$@" </dev/null >"$out" 2>&1
  else
    "$godot" "$@" </dev/null >"$out" 2>&1
  fi
}

# A fresh clone has no import cache or class list yet.
if [ "$needs_import" -eq 1 ]; then run_godot "$state_dir/log_review_import.log" --headless --path . --import; fi

# A relative script path on purpose: Git Bash would rewrite some res:// forms.
if [ "$mode" = "player" ]; then
  run_godot "$state_dir/log_review.log" --headless --path . --script tools/log_review.gd -- --player "$play_dir" ${check:+--check "$check"}
elif [ -n "${log:-}" ]; then
  run_godot "$state_dir/log_review.log" --headless --path . --script tools/log_review.gd -- --log "$log" ${check:+--check "$check"}
else
  run_godot "$state_dir/log_review.log" --headless --path . --script tools/log_review.gd -- --latest ${check:+--check "$check"}
fi
status=$?
esc="$(printf '\033')"
output="$(tr -d '\r' < "$state_dir/log_review.log" | sed "s/${esc}\[[0-9;]*m//g")"
if ! printf '%s\n' "$output" | grep -q '^GDIR-REVIEW'; then
  echo "log_review: FAIL: tools/log_review.gd didn't run (see $state_dir/log_review.log)" >&2
  printf '%s\n' "$output" | grep -E 'ERROR|Parse Error' | head -n 5 >&2
  exit 3
fi
printf '%s\n' "$output" | sed -n 's/^GDIR-REVIEW: /log_review: /p'
printf '%s\n' "$output" | sed -n 's/^GDIR-REVIEW-FAIL: /log_review: FAIL: /p' >&2
case "$status" in 0|1|2|3) exit "$status" ;; *) exit 3 ;; esac
