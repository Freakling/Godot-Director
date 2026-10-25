#!/usr/bin/env bash
# Godot Director project check · framework-owned: replaced on upgrade.
#
# The single definition of "it works":
#   bash tools/check.sh                 run the check
#   bash tools/check.sh --if-changed    repeat the last result at once if these exact files were checked
#   bash tools/check.sh --fingerprint   print the fingerprint of the current files (for hooks)
#   bash tools/check.sh --jobs N        run the tests in N Godot processes at once (N or auto; 1 is serial)
#   bash tools/check.sh --import        run the import pass even when no imported file changed
# Exit codes: 0 = pass · 1 = fail · 3 = couldn't run (Godot missing or older than 4.5, or a Godot
# run timed out: the report names the test file it was in)
#
# Steps:
#   1. an import pass (so a fresh clone gets its import cache and class list, and new assets are
#      picked up). It is skipped, with a line saying so, when no file Godot imports, no script's
#      class_name, extends or @icon line, and no scene or shader path has changed since the last pass
#      that exited 0; --import runs it anyway.
#   2. tools/check.gd: load every script, scene and resource; check the screen rules; run tests.
#      With more than one job, the tests run beside it in N processes, each on a contiguous group of
#      the sorted test files with its own log (.godot/godot-director/tests-<k>.log), merged into one
#      report. Every run lists each test file's time in the logs and ends with the slowest files.
#   3. scan Godot's output for errors (a parse error is printed, not returned)
#   3b. the layout lint of the screens and 3c. the autoplay smoke scenario, when tools/ui_capture.cfg and
#      tools/check.cfg switch them on
#   4. run tools/check.local.sh, if the project has one (extra project-specific steps)
#
# Godot is found through $GODOT_BIN, else the first line of tools/godot_bin.local (per machine,
# gitignored; `bash tools/setup-clone.sh` writes it), else `godot` on PATH. Settings are in
# tools/check.cfg. Each Godot run (each job of a parallel run too) is limited to [tests] timeout
# seconds from tools/check.cfg (default 600; CHECK_TIMEOUT overrides it) when GNU timeout (or
# gtimeout) is available. [tests] jobs sets the default for --jobs ("auto" is the CPU count). Plain GDScript warnings aren't printed (that needs -d, which can
# wait for debugger input); raise the ones that matter to Error in project.godot.

set -u
cd "$(dirname "$0")/.." || exit 3
mode=""
jobs_arg=""
force_import=0
while [ $# -gt 0 ]; do
  case "$1" in
    --jobs) jobs_arg="${2:-}"; [ $# -gt 1 ] && shift ;;
    --jobs=*) jobs_arg="${1#--jobs=}" ;;
    --import) force_import=1 ;;
    *) mode="$1" ;;
  esac
  shift
done
state_dir=".godot/godot-director"
nl="
"

# cfg_value <section> <key>: a value from tools/check.cfg, without quotes or a trailing comment.
cfg_value() {
  [ -f tools/check.cfg ] || return 0
  awk -v section="[$1]" -v key="$2" '{ sub(/\r$/, "") }
    /^\[/ { inside = ($0 == section); next }
    inside && $0 ~ "^[ \t]*" key "[ \t]*=" { v = $0; sub(/^[^=]*=[ \t]*/, "", v); sub(/[ \t]*;.*$/, "", v)
      gsub(/"/, "", v); sub(/[ \t]+$/, "", v); print v; exit }' tools/check.cfg
}
limit="${CHECK_TIMEOUT:-}"
[ "$mode" = "--fingerprint" ] || [ -n "$limit" ] || limit="$(cfg_value tests timeout)"
case "$limit" in ''|*[!0-9]*|0) limit=600 ;; esac

# Hash of every file that can change the result. Empty outside a git repository.
fingerprint() {
  git rev-parse --is-inside-work-tree >/dev/null 2>&1 || return 0
  local paths
  paths="$( {
    git -c core.quotePath=false ls-files -z -c -o --exclude-standard -- '*.gd' '*.tscn' '*.scn' \
      '*.tres' '*.res' '*.gdshader' '*.gdshaderinc' project.godot tools/check.cfg tools/ui_capture.cfg \
      tools/check.sh tools/check.local.sh tools/autoplay.sh 2>/dev/null | tr '\0' '\n'
    echo tools/godot_bin.local
    echo tools/check.ignore
  } | while IFS= read -r path; do [ -f "$path" ] && printf '%s\n' "$path"; done )"
  [ -n "$paths" ] || return 0
  { printf '%s\n' "$paths"; printf '%s\n' "$paths" | git hash-object --no-filters --stdin-paths; } \
    | git hash-object --stdin
}

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
if [ "$major" -lt 4 ] || { [ "$major" -eq 4 ] && [ "$minor" -lt 5 ]; }; then
  echo "check: needs Godot 4.5 or newer; '$godot' is $version."
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
[ -n "$timeout_cmd" ] || echo "check: no GNU timeout found: a hung test can't be cut short"
run_godot() { # run_godot <log file> <godot arguments…>
  local log="$1"; shift
  if [ -n "$timeout_cmd" ]; then
    "$timeout_cmd" "$limit" "$godot" "$@" </dev/null >"$log" 2>&1
  else
    "$godot" "$@" </dev/null >"$log" 2>&1
  fi
}

# --- how many test processes ------------------------------------------------------------------
jobs="$jobs_arg"
[ -n "$jobs" ] || jobs="$(cfg_value tests jobs)"
[ -n "$jobs" ] || jobs="auto"
if [ "$jobs" = "auto" ]; then
  jobs="${NUMBER_OF_PROCESSORS:-}"
  [ -n "$jobs" ] || jobs="$(getconf _NPROCESSORS_ONLN 2>/dev/null || sysctl -n hw.ncpu 2>/dev/null)"
  case "$jobs" in ''|*[!0-9]*) jobs=1 ;; esac
fi
case "$jobs" in
  ''|*[!0-9]*|0) echo "check: --jobs (or [tests] jobs in tools/check.cfg) takes a number or auto, not '$jobs'"; exit 3 ;;
esac
if [ "$jobs" -gt 1 ]; then
  tests_dir="$(cfg_value tests dir)"; tests_dir="${tests_dir#res://}"; tests_dir="${tests_dir%/}"
  [ -n "$tests_dir" ] || tests_dir="tests"
  test_count="$(/usr/bin/find "$tests_dir" -type f -name 'test_*.gd' 2>/dev/null | wc -l | tr -d ' ')"
  [ "${test_count:-0}" -lt "$jobs" ] && jobs="${test_count:-0}"
  [ "$jobs" -ge 1 ] || jobs=1
fi

failed=0
timed_out=""
hard_fail=0   # a failure that isn't a timeout: it wins over exit 3
echo "check: Godot $version"

# --- 1. import ----------------------------------------------------------------------------------
status=0
if [ "$force_import" -eq 0 ] && import_skip; then
  echo "check: import pass skipped (no imported file changed)"
else
  run_godot "$state_dir/import.log" --headless --path . --import
  status=$?
  import_record "$status"
fi
if [ "$status" -eq 124 ]; then timed_out="the import pass"; echo "check: the import pass timed out after ${limit} s"; failed=1
elif [ "$status" -ne 0 ]; then echo "check: the import pass exited with $status"; failed=1; hard_fail=1; fi

# --- 2. load, rules, tests ----------------------------------------------------------------------
esc="$(printf '\033')"
clean() { tr -d '\r' < "$1" | sed "s/${esc}\[[0-9;]*m//g"; }
# timed_out_in <what> <log>: say which test file a run that hit the timeout was in.
timed_out_in() {
  local running group
  running="$(clean "$2" | sed -n 's/^GDIR-TEST: \(.*\)::.*$/\1/p' | tail -n 1)"
  group="$(clean "$2" | sed -n 's/^GDIR-GROUP: //p' | head -n 1)"
  echo "check: $1 timed out after ${limit} s in ${group:-the tests}${running:+, while running $running} (see $2)"
  timed_out="${timed_out:+$timed_out, }$1"
  failed=1
}

# A relative script path on purpose: Git Bash would rewrite some res:// forms.
rm -f "$state_dir"/tests-*.log
test_logs="$state_dir/check.log"
if [ "$jobs" -le 1 ]; then
  run_godot "$state_dir/check.log" --headless --path . --script tools/check.gd
  status=$?
  if [ "$status" -eq 124 ]; then timed_out_in "tools/check.gd" "$state_dir/check.log"
  elif [ "$status" -ne 0 ]; then failed=1; hard_fail=1; fi
else
  # The loading and the screen rules run once, beside the test groups.
  echo "check: running the tests in $jobs processes"
  run_godot "$state_dir/check.log" --headless --path . --script tools/check.gd -- --no-tests &
  main_pid=$!
  pids=""; test_logs=""; k=1
  while [ "$k" -le "$jobs" ]; do
    run_godot "$state_dir/tests-$k.log" --headless --path . --script tools/check.gd -- --tests "$k" "$jobs" &
    pids="$pids $!"; test_logs="$test_logs $state_dir/tests-$k.log"; k=$((k + 1))
  done
  wait "$main_pid"; status=$?
  if [ "$status" -eq 124 ]; then timed_out_in "tools/check.gd (loading and screen rules)" "$state_dir/check.log"
  elif [ "$status" -ne 0 ]; then failed=1; hard_fail=1; fi
  k=1
  for pid in $pids; do
    wait "$pid"; status=$?
    log="$state_dir/tests-$k.log"
    if [ "$status" -eq 124 ]; then timed_out_in "test group $k of $jobs" "$log"
    elif ! clean "$log" | grep -q '^GDIR-TESTS: '; then echo "check: test group $k of $jobs didn't finish (see $log)"; failed=1
    elif [ "$status" -ne 0 ]; then failed=1; hard_fail=1; fi
    k=$((k + 1))
  done
  test_logs="$state_dir/check.log$test_logs"
fi

# --- 3. scan the output -------------------------------------------------------------------------

allow="$state_dir/allow.txt"
{
  # Engine noise at quick exit. Real leaks show up in the editor too.
  printf '%s\n' "ObjectDB instances leaked at exit" "resources still in use at exit" "Pages in use exist at exit"
  # Lines a test prints to expect an error. C4G-IGNORE: is the 2.x spelling, deprecated: remove in 4.0.
  for log in $test_logs; do [ -f "$log" ] && clean "$log"; done | sed -n -e "s/^GDIR-IGNORE://p" -e "s/^C4G-IGNORE://p"
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
errors="$(scan '^[ \t]*(ERROR|SCRIPT ERROR|USER ERROR|USER SCRIPT ERROR|GDIR-FAIL):|Parse Error' "$state_dir/import.log" $test_logs)"
warnings="$(scan '^[ \t]*(WARNING|SCRIPT WARNING|USER WARNING):' "$state_dir/import.log" $test_logs)"

# --- 3b. layout lint of the screens (opt in) ----------------------------------------------------
# tools/ui_capture.cfg > [lint] check_in_check = true runs the lint on the screens in `enforce` (the
# default size, headless; "*" is all), but only when everything above was clean: a screen's setup
# runs the game's own code, which a broken project can send into a loop. A missing file or key reads
# as off, and then nothing here costs anything.
ui_log="$state_dir/ui_lint.log"
rm -f "$ui_log"
ui_status=0; ui_ran=0
if [ "$failed" -eq 0 ] && [ -z "$errors" ] && [ -f tools/ui_capture.cfg ] && [ -f tools/ui_capture.gd ] && [ -f tools/ui_screens.gd ]; then
  ui_on="$(awk '/^\[/ { in_lint = ($0 ~ /^\[lint\]/); next }
    in_lint && /^[ \t]*check_in_check[ \t]*=/ { v = $0; sub(/^[^=]*=[ \t]*/, "", v); sub(/[ \t\r;].*$/, "", v); print v; exit }' tools/ui_capture.cfg)"
  if [ "$ui_on" = "true" ]; then
    ui_ran=1
    run_godot "$ui_log" --headless --path . --script tools/ui_capture.gd -- --check
    ui_status=$?
    if [ "$ui_status" -eq 124 ]; then timed_out="${timed_out:+$timed_out, }the layout lint"; echo "check: the layout lint timed out after ${limit} s"; failed=1; fi
    ui_errors="$(scan '^[ \t]*(ERROR|SCRIPT ERROR|USER ERROR|USER SCRIPT ERROR|GDIR-FAIL):|Parse Error' "$ui_log")"
    if [ -n "$ui_errors" ]; then errors="$ui_errors"; fi
    ui_warnings="$(scan '^[ \t]*(WARNING|SCRIPT WARNING|USER WARNING):' "$ui_log")"
    if [ -n "$ui_warnings" ]; then warnings="${warnings:+$warnings
}$ui_warnings"; fi
  fi
fi

# --- 3c. autoplay smoke (opt in) ----------------------------------------------------------------
# tools/check.cfg > [autoplay] check_in_check = true plays the smoke scenario headless (--no-images),
# and any other scenario `enforce` names ("*" is all of them), once everything above was clean: the
# game's own code runs. A finding in an enforced scenario fails the check, as GDIR-FAIL: autoplay:
# <scenario> step <n>: <kind>: <summary>; in another scenario it is a note, so `enforce` left empty
# makes smoke a note too. A missing file or key reads as off, and then nothing here costs anything.
# While the game's adapter is still the seed's, the run is skipped with a note that names what to wire.
ap_notes=""
ap_log="$state_dir/autoplay_check.log"
rm -f "$ap_log"
if [ "$failed" -eq 0 ] && [ -z "$errors" ] && [ -f tools/check.cfg ] && [ -f tools/autoplay.sh ] && [ -f tools/autoplay.gd ] \
    && [ -f tools/autoplay_adapter.gd ] && [ -f tools/autoplay_scenarios.gd ]; then
  ap_cfg="$(awk '/^\[/ { in_ap = ($0 ~ /^\[autoplay\]/); next }
    in_ap && /^[ \t]*(check_in_check|enforce)[ \t]*=/ { k = $0; sub(/[ \t]*=.*$/, "", k); sub(/^[ \t]*/, "", k)
      v = $0; sub(/^[^=]*=[ \t]*/, "", v); sub(/[ \t\r]*(;.*)?$/, "", v); if (!(k in seen)) print k "=" v; seen[k] = 1 }' tools/check.cfg)"
  ap_on="$(printf '%s\n' "$ap_cfg" | sed -n 's/^check_in_check=//p')"
  ap_enforce="$(printf '%s\n' "$ap_cfg" | sed -n 's/^enforce=//p' | tr -d '[]" \r' | tr ',' ' ')"
  if [ "$ap_on" = "true" ]; then
    ap_scenarios="smoke"
    set -f   # enforce may hold "*": no file name expansion
    for id in $ap_enforce; do
      case "$id" in "*") ap_scenarios="--all"; break ;; smoke) ;; *) ap_scenarios="$ap_scenarios $id" ;; esac
    done
    set +f
    ap_dir="playtesting/autoplay"
    ap_before="$(ls "$ap_dir" 2>/dev/null)"
    for id in $ap_scenarios; do
      enforced=0
      case " $ap_enforce " in *" $id "*|*" * "*) enforced=1 ;; esac
      GDIR_LOCK_HELD=1 AUTOPLAY_TIMEOUT="$limit" GODOT_BIN="$godot" bash tools/autoplay.sh $id --no-images > "$ap_log" 2>&1
      ap_status=$?
      ap_out="$(clean "$ap_log")"
      ap_fail="$(printf '%s\n' "$ap_out" | sed -n 's/^autoplay: FAIL: /autoplay: /p')"
      if [ "$ap_status" -eq 1 ] || [ -n "$ap_fail" ]; then
        [ -n "$ap_fail" ] || ap_fail="autoplay: $id failed (see $ap_log)"
        if [ "$enforced" -eq 1 ]; then
          errors="${errors:+$errors
}$(printf '%s\n' "$ap_fail" | sed 's/^/GDIR-FAIL: /')"
          failed=1
        else
          ap_notes="${ap_notes:+$ap_notes
}$(printf '%s\n' "$ap_fail" | sed 's/^/check: note: (not enforced) /')"
        fi
      elif [ "$ap_status" -eq 3 ]; then
        ap_notes="${ap_notes:+$ap_notes
}check: note: autoplay $id couldn't run: $(printf '%s\n' "$ap_out" | head -n 1)"
      elif [ "$ap_status" -ne 0 ]; then
        errors="${errors:+$errors
}GDIR-FAIL: autoplay: $id exited with $ap_status (see $ap_log)"
        failed=1
      else
        ap_notes="${ap_notes:+$ap_notes
}$(printf '%s\n' "$ap_out" | grep -E '^autoplay: .* · (skipped:|[0-9]+ steps? · )' | sed -e 's/ · playtesting\/autoplay\/[^ ]*$//' -e 's/^/check: note: /')"
      fi
    done
    # A clean run's folder isn't kept (every check would add one); a run with findings keeps its own.
    for folder in $(ls "$ap_dir" 2>/dev/null); do
      case "$nl$ap_before$nl" in *"$nl$folder$nl"*) continue ;; esac
      [ -f "$ap_dir/$folder/repro.json" ] || rm -rf "${ap_dir:?}/$folder"
    done
  fi
fi

summary="$(clean "$state_dir/check.log" | grep -E '^GDIR(-NOTE)?:')"
if [ "$jobs" -gt 1 ]; then
  # A parallel run: the groups' notes, and their passed tests in the main run's line.
  tests_passed="$(for log in $test_logs; do [ -f "$log" ] && clean "$log"; done | awk '/^GDIR-TESTS: / { n += $2 } END { print n + 0 }')"
  [ "$tests_passed" -eq 1 ] && tests_word="1 test" || tests_word="$tests_passed tests"
  summary="$(printf '%s\n' "$summary" | sed "s/@TESTS@/$tests_word/")"
  for log in $test_logs; do
    [ "$log" = "$state_dir/check.log" ] || summary="$summary$nl$(clean "$log" | grep -E '^GDIR-NOTE:')"
  done
  summary="$(printf '%s\n' "$summary" | grep -v '^$')"
fi
if clean "$state_dir/check.log" | grep -q '^GDIR: '; then
  printf '%s\n' "$summary" | sed 's/^GDIR: /check: /; s/^GDIR-NOTE: /check: note: /'
elif [ -z "$timed_out" ]; then
  echo "check: tools/check.gd didn't finish (see $state_dir/check.log)"
  failed=1
fi
if [ "$ui_ran" -eq 1 ]; then
  clean "$ui_log" | sed -n 's/^GDIR-NOTE: ui lint/check: note: ui lint/p'
  if [ "$ui_status" -ne 0 ] && [ -z "$(clean "$ui_log" | grep -E '^[[:space:]]*(GDIR-FAIL|ERROR|SCRIPT ERROR):')" ]; then
    echo "check: the layout lint stopped early (see $ui_log)"
    failed=1
  fi
fi
if [ -n "$ap_notes" ]; then printf '%s\n' "$ap_notes"; fi
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
  if printf '%s\n' "$errors" | grep -q '^GDIR-FAIL: autoplay:'; then
    echo "  autoplay: 'bash tools/log_review.sh --latest' reads the run; 'bash tools/autoplay.sh --replay <run folder>' plays it again"
  fi
fi

# --- 4. project-specific steps ------------------------------------------------------------------
if [ -f tools/check.local.sh ]; then
  echo "check: running tools/check.local.sh"
  if ! GODOT_BIN="$godot" bash tools/check.local.sh; then
    echo "check: tools/check.local.sh failed"
    failed=1
  fi
fi

# Every run ends with the slowest test files (each file's time is in the logs, as GDIR-TIME: <ms> <file>).
slowest() {
  for log in $test_logs; do [ -f "$log" ] && clean "$log"; done | sed -n 's/^GDIR-TIME: //p' | /usr/bin/sort -rn \
    | awk '{ ms[NR] = $1; sub(/^[0-9]+ /, ""); file[NR] = $0; total += ms[NR] }
      END {
        if (NR == 0) exit
        printf "check: slowest test files (of %d, %.1f s of test time in all):\n", NR, total / 1000
        for (i = 1; i <= NR && i <= 10; i++)
          printf "  %7.1f s  %3d%%  %s\n", ms[i] / 1000, (total > 0 ? int(ms[i] * 100 / total + 0.5) : 0), file[i]
      }'
}

if [ -n "$timed_out" ]; then
  echo "check: couldn't run to the end: $timed_out timed out after ${limit} s ([tests] timeout in tools/check.cfg, or CHECK_TIMEOUT; full logs in $state_dir/)"
  # A failure seen beside the timeout wins: exit 1, as a normal failure. Exit 3 only when none was seen.
  if [ "$hard_fail" -eq 0 ] && ! printf '%s
' "$errors" | grep -q 'GDIR-FAIL:'; then
    slowest
    rm -f "$state_dir/last-pass" "$state_dir/import-fingerprint"
    exit 3
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
  slowest
  echo "check: PASS"
  exit 0
fi
# A failing run may have left Godot's class cache stale (scripts aren't in the import fingerprint), so
# the next run imports again.
rm -f "$state_dir/last-pass" "$state_dir/import-fingerprint"
if [ -n "$before" ] && [ "$before" = "$(fingerprint)" ]; then printf '%s' "$before" > "$state_dir/last-fail"; fi
slowest
echo "check: FAIL (full logs in $state_dir/)"
exit 1
