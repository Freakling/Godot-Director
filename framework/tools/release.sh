#!/usr/bin/env bash
# Godot Director release uploads · framework-owned: replaced on upgrade.
#
#   bash tools/release.sh uat|production [preset] [--dry-run]
#
# Runs the upload commands that release.cfg names for each export preset: the `uat` command, or the
# `production` command. It uploads what is already in builds/<preset>/ (run /export first) and knows
# no store: the commands are the game's own. A command reads its credentials from environment
# variables; release.cfg lists their names under `secrets`, and the script stops before running
# anything when one is unset. It prints the names, never the values.
# Exit codes: 0 = done · 1 = a command failed · 2 = wrong use, or release.cfg, a build or a secret is missing.

usage="usage: bash tools/release.sh uat|production [preset] [--dry-run]"
stage=""; only=""; dry=0
for arg in "$@"; do
  case "$arg" in
    --dry-run) dry=1 ;;
    uat|production) if [ -z "$stage" ]; then stage="$arg"; else only="$arg"; fi ;;
    *) [ -n "$stage" ] || { echo "$usage" >&2; exit 2; }; only="$arg" ;;
  esac
done
[ -n "$stage" ] || { echo "$usage" >&2; exit 2; }
[ -f release.cfg ] || { echo "release.cfg not found in $(pwd); run from the project root" >&2; exit 2; }

# One line per preset that has a command for this stage: preset|secrets|command
plan="$(awk -v stage="$stage" '
  /^[ \t]*#/ || /^[ \t]*$/ { next }
  /^\[.*\][ \t]*$/ { s = $0; sub(/^\[/, "", s); sub(/\][ \t]*$/, "", s); if (!(s in seen)) { seen[s] = 1; n++; name[n] = s } cur = s; next }
  { k = $0; sub(/[ \t]*=.*/, "", k); v = $0; sub(/^[^=]*=[ \t]*/, "", v)
    if (k == stage) cmd[cur] = v
    if (k == "secrets") sec[cur] = v }
  END { for (i = 1; i <= n; i++) { s = name[i]; if (s in cmd) print s "|" sec[s] "|" cmd[s] } }' release.cfg)"
[ -n "$plan" ] || { echo "release.cfg has no '$stage' command for any preset" >&2; exit 2; }

# Check everything before running anything.
problems=""
while IFS='|' read -r preset secrets cmd; do
  if [ -n "$only" ] && [ "$only" != "$preset" ]; then continue; fi
  if [ -z "$(ls -A "builds/$preset" 2>/dev/null)" ]; then
    problems="$problems${problems:+, }builds/$preset is empty or missing (run /export)"
  fi
  for name in $(printf '%s' "$secrets" | tr ',' ' '); do
    case "$name" in
      *[!A-Za-z0-9_]*) problems="$problems${problems:+, }'$name' is not an environment variable name"; continue ;;
    esac
    if [ "$dry" = 0 ] && [ -z "${!name}" ]; then problems="$problems${problems:+, }secret $name is not set"; fi
  done
done <<PLAN
$plan
PLAN
[ -z "$problems" ] || { echo "not releasing to $stage: $problems" >&2; exit 2; }

ran=0
while IFS='|' read -r preset secrets cmd; do
  if [ -n "$only" ] && [ "$only" != "$preset" ]; then continue; fi
  echo "== $stage: $preset"
  echo "   $cmd"
  if [ "$dry" = 0 ]; then
    bash -c "$cmd" || { echo "the $stage command for $preset failed" >&2; exit 1; }
  fi
  ran=$((ran + 1))
done <<PLAN
$plan
PLAN
[ "$ran" -gt 0 ] || { echo "no preset named '$only' has a '$stage' command" >&2; exit 2; }
note=""; [ "$dry" = 1 ] && note=" (dry run, nothing uploaded)"
echo "$stage: $ran preset(s)$note"
