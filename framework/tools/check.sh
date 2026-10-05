#!/usr/bin/env bash
# Godot Director project check · framework-owned: replaced on upgrade.
#
# The single definition of "it works":
#   bash tools/check.sh                 run the check
#   bash tools/check.sh --if-changed    repeat the last result at once if these exact files were checked
#   bash tools/check.sh --fingerprint   print the fingerprint of the current files (for hooks)
# Exit codes: 0 = pass · 1 = fail · 3 = couldn't run (Godot missing or older than 4.3)
#
# Steps:
#   1. an import pass (so a fresh clone gets its import cache and class list, and new assets and
#      class_names are picked up)
#   2. tools/check.gd: load every script, scene and resource; check the screen rules; run tests
#   3. scan Godot's output for errors (a parse error is printed, not returned)
#   4. run tools/check.local.sh, if the project has one (extra project-specific steps)
#
# Godot is found through $GODOT_BIN, else the first line of tools/godot_bin.local (per machine,
# gitignored; `bash tools/setup-clone.sh` writes it), else `godot` on PATH. Settings are in
# tools/check.cfg. CHECK_TIMEOUT (seconds, default 600) limits each Godot run when GNU timeout
# (or gtimeout) is available. Plain GDScript warnings aren't printed (that needs -d, which can
# wait for debugger input); raise the ones that matter to Error in project.godot.

set -u
cd "$(dirname "$0")/.." || exit 3
mode="${1:-}"
state_dir=".godot/godot-director"
limit="${CHECK_TIMEOUT:-600}"

# Hash of every file that can change the result. Empty outside a git repository.
fingerprint() {
  git rev-parse --is-inside-work-tree >/dev/null 2>&1 || return 0
  local paths
  paths="$( {
    git -c core.quotePath=false ls-files -z -c -o --exclude-standard -- '*.gd' '*.tscn' '*.scn' \
      '*.tres' '*.res' '*.gdshader' '*.gdshaderinc' project.godot tools/check.cfg tools/check.sh \
      tools/check.local.sh 2>/dev/null | tr '\0' '\n'
    echo tools/godot_bin.local
    echo tools/check.ignore
  } | while IFS= read -r path; do [ -f "$path" ] && printf '%s\n' "$path"; done )"
  [ -n "$paths" ] || return 0
  { printf '%s\n' "$paths"; printf '%s\n' "$paths" | git hash-object --no-filters --stdin-paths; } \
    | git hash-object --stdin
}

if [ "$mode" = "--fingerprint" ]; then fingerprint; exit 0; fi
mkdir -p "$state_dir" || exit 3
before="$(fingerprint)"
# --if-changed: reuse the last result for exactly these files (asked again once the lock is ours).
reuse_last() {
  [ "$mode" = "--if-changed" ] && [ -n "$before" ] || return 0
  if [ "$(cat "$state_dir/last-pass" 2>/dev/null)" = "$before" ]; then
    echo "check: PASS (nothing changed since the last passing run)"
    exit 0
  fi
  if [ "$(cat "$state_dir/last-fail" 2>/dev/null)" = "$before" ]; then
    echo "check: FAIL (nothing changed since the last failing run; run 'bash tools/check.sh' to see why)"
    exit 1
  fi
}
reuse_last

# --- find Godot ---------------------------------------------------------------------------------
godot="${GODOT_BIN:-}"
if [ -z "$godot" ] && [ -f tools/godot_bin.local ]; then
  # Tolerates a UTF-8 or UTF-16 byte-order mark and trailing spaces (PowerShell writes both).
  godot="$(LC_ALL=C tr -d '\000\376\377' < tools/godot_bin.local \
    | awk 'NR == 1 { sub(/^\357\273\277/, ""); sub(/[ \t\r]+$/, ""); print; exit }')"
fi
[ -n "$godot" ] || godot="godot"
if ! command -v "$godot" >/dev/null 2>&1 && [ ! -x "$godot" ]; then
  echo "check: can't find Godot ('$godot'). Run: bash tools/setup-clone.sh"
  exit 3
fi
version="$("$godot" --headless --version 2>/dev/null </dev/null | tr -d '\r' | grep -E '^[0-9]+\.[0-9]+' | tail -n 1)"
major="${version%%.*}"; rest="${version#*.}"; minor="${rest%%.*}"
case "$major" in ''|*[!0-9]*) major="" ;; esac
case "$minor" in ''|*[!0-9]*) minor="" ;; esac
if [ -z "$major" ] || [ -z "$minor" ]; then
  echo "check: couldn't read a version from '$godot' (on Windows, use the *_console.exe build)."
  exit 3
fi
if [ "$major" -lt 4 ] || { [ "$major" -eq 4 ] && [ "$minor" -lt 3 ]; }; then
  echo "check: needs Godot 4.3 or newer; '$godot' is $version."
  exit 3
fi
if [ ! -f project.godot ]; then
  echo "check: FAIL: no project.godot in $(pwd). Create the Godot project first."
  exit 1
fi

# --- one run at a time (hooks and sessions share .godot/) ---------------------------------------
lock="$state_dir/lock"
waited=0
until mkdir "$lock" 2>/dev/null; do
  holder="$(cat "$lock/pid" 2>/dev/null)"
  if [ -n "$holder" ] && ! kill -0 "$holder" 2>/dev/null; then rm -rf "$lock"; continue; fi
  if [ "$waited" -ge $((limit * 2 + 60)) ]; then
    echo "check: another check has run for too long. If none is running, delete $lock."
    exit 3
  fi
  [ "$waited" -eq 0 ] && echo "check: waiting for another check to finish…"
  sleep 2; waited=$((waited + 2))
done
echo $$ > "$lock/pid"
trap 'rm -rf "$lock"' EXIT
reuse_last   # the run we waited for may have checked exactly these files

timeout_cmd=""
for candidate in timeout gtimeout; do   # GNU only: Windows' timeout.exe is something else
  if "$candidate" --version 2>/dev/null | grep -qi coreutils; then timeout_cmd="$candidate"; break; fi
done
run_godot() { # run_godot <log file> <godot arguments…>
  local log="$1"; shift
  if [ -n "$timeout_cmd" ]; then
    "$timeout_cmd" "$limit" "$godot" "$@" </dev/null >"$log" 2>&1
  else
    "$godot" "$@" </dev/null >"$log" 2>&1
  fi
}

failed=0
echo "check: Godot $version"

# --- 1. import ----------------------------------------------------------------------------------
run_godot "$state_dir/import.log" --headless --path . --import
status=$?
if [ "$status" -eq 124 ]; then echo "check: the import pass timed out after ${limit}s"; failed=1
elif [ "$status" -ne 0 ]; then echo "check: the import pass exited with $status"; failed=1; fi

# --- 2. load, rules, tests ----------------------------------------------------------------------
# A relative script path on purpose: Git Bash would rewrite some res:// forms.
run_godot "$state_dir/check.log" --headless --path . --script tools/check.gd
status=$?
if [ "$status" -eq 124 ]; then echo "check: tools/check.gd timed out after ${limit}s"; failed=1
elif [ "$status" -ne 0 ]; then failed=1; fi

# --- 3. scan the output -------------------------------------------------------------------------
esc="$(printf '\033')"
clean() { tr -d '\r' < "$1" | sed "s/${esc}\[[0-9;]*m//g"; }

allow="$state_dir/allow.txt"
{
  # Engine noise at quick exit. Real leaks show up in the editor too.
  printf '%s\n' "ObjectDB instances leaked at exit" "resources still in use at exit" "Pages in use exist at exit"
  # Lines a test prints to expect an error. C4G-IGNORE: is the 2.x spelling, deprecated: remove in 4.0.
  clean "$state_dir/check.log" | sed -n -e "s/^GDIR-IGNORE://p" -e "s/^C4G-IGNORE://p"
  # Project-approved suppressions (tools/check.ignore: one substring per line, # comments).
  [ -f tools/check.ignore ] && grep -v '^[[:space:]]*#' tools/check.ignore
} | grep -v '^[[:space:]]*$' > "$allow"

# Matching lines, plus the "at:" line under each, minus allowlisted ones.
scan() { # scan <extended regex> <log files…>
  local pattern="$1" file
  shift
  for file in "$@"; do [ -f "$file" ] && clean "$file"; done | awk -v pattern="$pattern" -v allowfile="$allow" '
    BEGIN { count = 0; while ((getline line < allowfile) > 0) if (line != "") allowed_text[count++] = line }
    function allowed(text,   i) { for (i = 0; i < count; i++) if (index(text, allowed_text[i]) > 0) return 1; return 0 }
    keep && /^[ \t]+at: / { print; keep = 0; next }
    { keep = 0 }
    $0 ~ pattern && !allowed($0) { print; keep = 1 }
  '
}
errors="$(scan '^[ \t]*(ERROR|SCRIPT ERROR|USER ERROR|USER SCRIPT ERROR|GDIR-FAIL):|Parse Error' "$state_dir/import.log" "$state_dir/check.log")"
warnings="$(scan '^[ \t]*(WARNING|SCRIPT WARNING|USER WARNING):' "$state_dir/import.log" "$state_dir/check.log")"

summary="$(clean "$state_dir/check.log" | grep -E '^GDIR(-NOTE)?:')"
if [ -n "$summary" ]; then
  printf '%s\n' "$summary" | sed 's/^GDIR: /check: /; s/^GDIR-NOTE: /check: note: /'
else
  echo "check: tools/check.gd didn't finish (see $state_dir/check.log)"
  failed=1
fi
hooks_dir="$(git rev-parse --git-path hooks 2>/dev/null)"
if [ -n "$hooks_dir" ] && ! grep -qs "Godot Director" "$hooks_dir/pre-commit"; then
  echo "check: note: this clone has no Godot Director pre-commit hook. Run: bash tools/setup-clone.sh"
fi

if [ -n "$warnings" ]; then
  echo "check: warnings (not failures):"
  printf '%s\n' "$warnings" | head -n 20 | sed 's/^/  /'
fi
if [ -n "$errors" ]; then
  failed=1
  echo "check: errors:"
  printf '%s\n' "$errors" | head -n 60 | sed 's/^/  /'
fi

# --- 4. project-specific steps ------------------------------------------------------------------
if [ -f tools/check.local.sh ]; then
  echo "check: running tools/check.local.sh"
  if ! GODOT_BIN="$godot" bash tools/check.local.sh; then
    echo "check: tools/check.local.sh failed"
    failed=1
  fi
fi

if [ "$failed" -eq 0 ]; then
  after="$(fingerprint)"
  if [ -n "$before" ] && [ "$before" = "$after" ]; then
    printf '%s' "$before" > "$state_dir/last-pass"
  elif [ -n "$before" ]; then
    echo "check: note: files changed while the check ran; run it again to cover the changes."
  fi
  rm -f "$state_dir/last-fail"
  # Streak tracking: count how many consecutive passing runs each warning has appeared in,
  # and emit a note for any that have reached the threshold.
  streak_file="$state_dir/warn-streak.json"
  threshold=5
  if [ -f tools/check.cfg ]; then
    t="$(awk '/^\[warnings\]/{s=1;next} /^\[/{s=0}
              s && /^recurring_threshold[[:space:]]*=/{
                sub(/[^=]*=[[:space:]]*/,""); sub(/[#[:space:]].*/,""); print; exit
              }' tools/check.cfg)"
    [ -n "$t" ] && [ "$t" -eq "$t" ] 2>/dev/null && threshold="$t"
  fi
  printf '%s\n' "$warnings" \
    | grep -v '^[[:space:]]*at:' \
    | sed 's/^[[:space:]]*//' \
    | sort -u \
    | awk -v sf="$streak_file" -v thresh="$threshold" '
      # Read {"text":count,...} from sf into st[].
      function rj(f, st,    ln, s, i, c, k, v, ins, esc) {
        while ((getline ln < f) > 0) s = s ln; close(f)
        ins = 0; esc = 0; k = ""; v = ""
        for (i = 1; i <= length(s); i++) {
          c = substr(s, i, 1)
          if (esc) { if (ins) k = k c; esc = 0; continue }
          if (c == "\\") { esc = 1; continue }
          if (c == "\"") { ins = !ins; if (ins) k = ""; continue }
          if (ins) { k = k c; continue }
          if (c ~ /[0-9]/) { v = v c; continue }
          if ((c == "," || c == "}") && k != "" && v != "") { st[k] = int(v); k = ""; v = "" }
        }
      }
      # Write st[] as {"text":count,...} to f, omitting zero-count entries.
      function wj(f, st,    sep, k, ek) {
        printf "{" > f; sep = ""
        for (k in st) {
          if (st[k] <= 0) continue
          ek = k; gsub(/\\/, "\\\\", ek); gsub(/"/, "\\\"", ek)
          printf "%s\"%s\":%d", sep, ek, st[k] > f; sep = ","
        }
        printf "}" > f; close(f)
      }
      BEGIN { rj(sf, old) }
      NF   { cur[$0] = 1 }
      END  {
        for (k in old) new[k] = (k in cur) ? old[k] + 1 : 0
        for (k in cur) if (!(k in new)) new[k] = 1
        for (k in new)
          if (new[k] >= thresh)
            printf "check: note: recurring warning (%d\303\227): %s\n", new[k], k
        wj(sf, new)
      }
    '
  echo "check: PASS"
  exit 0
fi
rm -f "$state_dir/last-pass"
if [ -n "$before" ] && [ "$before" = "$(fingerprint)" ]; then printf '%s' "$before" > "$state_dir/last-fail"; fi
echo "check: FAIL (full logs in $state_dir/)"
exit 1
