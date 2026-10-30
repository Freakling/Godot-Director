#!/usr/bin/env bash
# Godot Director project check · framework-owned: replaced on upgrade.
#
# The single definition of "it works":
#   bash tools/check.sh                 run the check
#   bash tools/check.sh --if-changed    repeat the last result at once if these exact files were checked with this gitleaks
#   bash tools/check.sh --fingerprint   print the fingerprint of the current files (for hooks)
#   bash tools/check.sh --jobs N        run in N Godot processes at once (N or auto; 1 is serial); autoplay in the check takes one of them
#   bash tools/check.sh --import        run the import pass even when no imported file changed
# Exit codes: 0 = pass · 1 = fail · 3 = couldn't run (Godot missing or older than 4.5, a gitleaks that
# is installed but too old or unable to scan, or a Godot run that timed out: the report names the test file it was in)
#
# Steps:
#   0. secrets, when gitleaks is installed (credentials in source): gitleaks dir --redact on the working
#      tree (detect --no-git before 8.19.1; 8.19.0 can't scan at all, so the check exits 3). Without
#      gitleaks the check prints one note and goes on; it never exits 3 for a gitleaks that isn't
#      installed. Findings are listed as file:line, with the values redacted (the report is
#      .godot/godot-director/gitleaks.json). The minimum version is [gitleaks] min-version in
#      tools/check.cfg (default 8.18.0). The cached result of --if-changed records gitleaks's version, so
#      installing, removing or changing it runs the scan again. The settings are the game's
#      .gitleaks.toml and .gitleaksignore.
#   1. an import pass (so a fresh clone gets its import cache and class list, and new assets are
#      picked up). It is skipped, with a line saying so, when no file Godot imports, no script's
#      class_name, extends or @icon line, and no scene or shader path has changed since the last pass
#      that exited 0; --import runs it anyway.
#   2. tools/check.gd: load every script, scene and resource; check the screen rules; run tests.
#      With more than one job, the tests run beside it in N processes, each with its own log
#      (.godot/godot-director/tests-<k>.log), merged into one report. By default each process takes a
#      contiguous group of the sorted test files, in file order. Opt-in: [tests] balance=true deals
#      them longest first by the last run's times instead, files with no time first, each to the job
#      with the least time so far; with it, a file whose time when it last ran whole is over
#      [tests] split_over seconds (default 0, off) runs as up to N shards of its test methods, each in
#      its own job, its tests counted once; a line `# gdir: no-split` among its first ten lines keeps
#      it whole (for tests that share state across methods). GDIR_CHECK_DEAL=1 prints the deal. Every
#      run lists each test file's time in the logs and ends with the slowest files (a split file's
#      shards added up). Every run also keeps the times, so balance works at once when turned on, in
#      .godot/godot-director/test-times.tsv, one tab-separated line per file: path, its whole time
#      in seconds (the split is sized from this; a split run whose shards all finished lowers it to
#      their sum, never raises it), the shard count of its last run, and that run's longest shard in seconds (a shard
#      is weighed by it while the count stays the same). A line of only a path and seconds still
#      reads. `bash tools/check.sh --jobs 1` re-measures every file whole.
#   3. scan Godot's output for errors (a parse error is printed, not returned)
#   3b. the layout lint of the screens and 3c. the autoplay scenarios, when tools/ui_capture.cfg and
#      tools/check.cfg switch them on. In a parallel run the scenarios start as soon as the import and the
#      load pass came back clean, in one more process beside the test jobs (which are then one fewer, so
#      the CPU count holds), one scenario at a time; their result joins the report with the rest. A
#      serial run (--jobs 1) plays them after the tests, once everything above was clean.
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
GITLEAKS_MIN_DEFAULT="8.18.0"

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

# version_gte <installed> <minimum>: succeeds when installed >= minimum (both dotted numbers).
version_gte() {
  local inst="$1" min="$2" ia ib ic ma mb mc rest
  ia="${inst%%.*}"; rest="${inst#*.}"; ib="${rest%%.*}"; ic="${rest#*.}"
  ma="${min%%.*}"; rest="${min#*.}"; mb="${rest%%.*}"; mc="${rest#*.}"
  ia="${ia:-0}"; ib="${ib:-0}"; ic="${ic:-0}"
  ma="${ma:-0}"; mb="${mb:-0}"; mc="${mc:-0}"
  [ "$ia" -gt "$ma" ] && return 0
  [ "$ia" -lt "$ma" ] && return 1
  [ "$ib" -gt "$mb" ] && return 0
  [ "$ib" -lt "$mb" ] && return 1
  [ "$ic" -ge "$mc" ]
}

# Hash of every file that can change the result. Empty outside a git repository.
fingerprint() {
  git rev-parse --is-inside-work-tree >/dev/null 2>&1 || return 0
  local paths
  paths="$( {
    git -c core.quotePath=false ls-files -z -c -o --exclude-standard -- '*.gd' '*.tscn' '*.scn' \
      '*.tres' '*.res' '*.gdshader' '*.gdshaderinc' project.godot tools/check.cfg tools/ui_capture.cfg \
      tools/check.sh tools/check.local.sh tools/autoplay.sh .gitleaks.toml .gitleaksignore 2>/dev/null | tr '\0' '\n'
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

# gitleaks's version, or "missing". Read once: the cached result depends on it (cache_key), and the
# secrets step uses it, so a run starts gitleaks once for it, and not at all when it isn't installed.
gl_ver="missing"
if command -v gitleaks >/dev/null 2>&1; then
  gl_ver="$(gitleaks version 2>/dev/null | tr -d 'v \r\n')"
  gl_ver="${gl_ver%%[!0-9.]*}"   # 8.30.1-rc1 → 8.30.1
  [ -n "$gl_ver" ] || gl_ver="unreadable"
fi

# What a cached result stands for: the files' fingerprint and gitleaks's version. A gitleaks that was
# installed, removed or changed makes the cache miss, so --if-changed runs the secrets step again.
cache_key() { printf '%s gitleaks=%s' "$1" "$gl_ver"; }

# --if-changed: reuse the last result for exactly these files (asked again once the lock is ours).
reuse_last() {
  [ "$mode" = "--if-changed" ] && [ -n "$before" ] || return 0
  local key
  key="$(cache_key "$before")"
  if [ "$(cat "$state_dir/last-pass" 2>/dev/null)" = "$key" ]; then
    echo "check: PASS (nothing changed since the last passing run)"
    exit 0
  fi
  if [ "$(cat "$state_dir/last-fail" 2>/dev/null)" = "$key" ]; then
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

# --- autoplay in the check (opt in): read now, since it takes one of the processes --------------
# tools/check.cfg > [autoplay] check_in_check = true plays the smoke scenario headless (--no-images),
# and any other scenario `enforce` names ("*" is all of them). A finding in an enforced scenario fails
# the check, as GDIR-FAIL: autoplay: <scenario> step <n>: <kind>: <summary>; in another scenario it is
# a note, so `enforce` left empty makes smoke a note too. A missing file or key reads as off, and then
# nothing here costs anything. Step 3c says when they are played.
ap_on=0; ap_enforce=""; ap_scenarios=""
rm -f "$state_dir"/autoplay_check*.log "$state_dir"/autoplay_check*.status
if [ -f tools/check.cfg ] && [ -f tools/autoplay.sh ] && [ -f tools/autoplay.gd ] \
    && [ -f tools/autoplay_adapter.gd ] && [ -f tools/autoplay_scenarios.gd ]; then
  ap_cfg="$(awk '/^\[/ { in_ap = ($0 ~ /^\[autoplay\]/); next }
    in_ap && /^[ \t]*(check_in_check|enforce)[ \t]*=/ { k = $0; sub(/[ \t]*=.*$/, "", k); sub(/^[ \t]*/, "", k)
      v = $0; sub(/^[^=]*=[ \t]*/, "", v); sub(/[ \t\r]*(;.*)?$/, "", v); if (!(k in seen)) print k "=" v; seen[k] = 1 }' tools/check.cfg)"
  if [ "$(printf '%s\n' "$ap_cfg" | sed -n 's/^check_in_check=//p')" = "true" ]; then
    ap_on=1
    ap_enforce="$(printf '%s\n' "$ap_cfg" | sed -n 's/^enforce=//p' | tr -d '[]" \r' | tr ',' ' ')"
    ap_scenarios="smoke"
    set -f   # enforce may hold "*": no file name expansion
    for id in $ap_enforce; do
      case "$id" in "*") ap_scenarios="--all"; break ;; smoke) ;; *) ap_scenarios="$ap_scenarios $id" ;; esac
    done
    set +f
  fi
fi

# test_jobs is how many processes run the tests. With more than one process allowed and a test to run,
# the load pass and the tests run apart (par=1), and autoplay in the check takes one process of the
# count: it plays beside the test jobs (ap_beside=1), so the CPU count is not exceeded.
test_jobs="$jobs"; par=0; ap_beside=0
if [ "$jobs" -gt 1 ]; then
  tests_dir="$(cfg_value tests dir)"; tests_dir="${tests_dir#res://}"; tests_dir="${tests_dir%/}"
  [ -n "$tests_dir" ] || tests_dir="tests"
  test_count="$(/usr/bin/find "$tests_dir" -type f -name 'test_*.gd' 2>/dev/null | wc -l | tr -d ' ')"
  [ "$ap_on" -eq 1 ] && [ "${test_count:-0}" -ge 1 ] && { ap_beside=1; test_jobs=$((jobs - 1)); }
  [ "${test_count:-0}" -lt "$test_jobs" ] && test_jobs="${test_count:-0}"
  [ "$test_jobs" -ge 1 ] || test_jobs=1
  if [ "$ap_beside" -eq 1 ] || [ "$test_jobs" -gt 1 ]; then par=1; fi
fi

failed=0
timed_out=""
hard_fail=0   # a failure that isn't a timeout: it wins over exit 3
echo "check: Godot $version"

# --- helpers of the steps below -----------------------------------------------------------------
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

# The lines the scan below ignores: engine noise at quick exit, what the given logs ask to ignore, and
# tools/check.ignore.
allow="$state_dir/allow.txt"
write_allow() { # write_allow <log files...>
  local log
  {
    # Engine noise at quick exit. Real leaks show up in the editor too.
    printf '%s\n' "ObjectDB instances leaked at exit" "resources still in use at exit" "Pages in use exist at exit"
    # Lines a test prints to expect an error. C4G-IGNORE: is the 2.x spelling, deprecated: remove in 4.0.
    for log in "$@"; do [ -f "$log" ] && clean "$log"; done | sed -n -e "s/^GDIR-IGNORE://p" -e "s/^C4G-IGNORE://p"
    # Project-approved suppressions (tools/check.ignore: one substring per line, # comments).
    [ -f tools/check.ignore ] && grep -v '^[[:space:]]*#' tools/check.ignore
  } | grep -v '^[[:space:]]*$' > "$allow"
}

# Matching lines, plus the "at:" line under each, minus allowlisted ones.
scan() { # scan <extended regex> <log files...>
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
error_pattern='^[ \t]*(ERROR|SCRIPT ERROR|USER ERROR|USER SCRIPT ERROR|GDIR-FAIL):|Parse Error'

# A process that exits non-zero (a crash, say) and prints no error line gave no reason for the FAIL. These
# say so in one line, with its status and its log (step 1, 2 and 3b call them).
# exit_text <status>: the status, with the name of the signal a crash usually gives (128 + signal).
exit_text() {
  case "$1" in
    134) echo "134 (abort)" ;;
    136) echo "136 (floating-point exception)" ;;
    137) echo "137 (killed)" ;;
    139) echo "139 (segmentation fault)" ;;
    *) echo "$1" ;;
  esac
}
# silent_exit <log>: succeeds when the log has no error line the scan reports. It writes the allow list
# from that log alone (write_allow); the final scan allows at least those lines for a test log too.
silent_exit() {
  write_allow "$1"
  [ -z "$(scan "$error_pattern" "$1")" ]
}
# exit_quiet <what> <status> <log>: the line for a process that exited non-zero and printed no error.
exit_quiet() { echo "check: $1 exited with $(exit_text "$2") and printed no error; see $3"; }

# --- 0. secrets (gitleaks, when installed) ------------------------------------------------------
# gitleaks is optional, so a game needs no extra install. Not installed: one note, and the check goes
# on. Installed but too old or unable to scan: the check couldn't run (exit 3), since the human chose
# to install it, and a scan that didn't happen must not read as a pass. It runs first so that a
# gitleaks that can't scan is reported before any Godot time is spent. The working tree is scanned as
# it is: gitleaks dir doesn't read .gitignore, so the game's .gitleaks.toml allowlists .godot/.
gl_min="$(cfg_value gitleaks min-version)"
case "$gl_min" in ''|*[!0-9.]*) gl_min="$GITLEAKS_MIN_DEFAULT" ;; esac
gl_report="$state_dir/gitleaks.json"
# gitleaks 8.19.1 is the first release whose `dir` command works; 8.18 scans the folder with
# `detect --no-git`. Both write the same JSON report (a File, a StartLine and a Fingerprint per finding).
# gitleaks 8.19.0 can't scan at all: every command fails with "flag accessed but not defined: source"
# and writes no report. So a failed scan that left no finding in the report is "couldn't scan"
# (exit 3), never "credentials found". The scan's output is kept for that message.
gl_scan() {
  rm -f "$gl_report"
  if version_gte "$gl_ver" 8.19.1; then
    gitleaks dir --redact --report-path="$gl_report" . 2>&1
  else
    gitleaks detect --no-git --redact --report-path="$gl_report" --source . 2>&1
  fi
}
# gl_findings: "file:line (rule)" for each finding in the report. Only these are printed; the values
# stay redacted in the report.
gl_findings() {
  tr -d '\r' < "$gl_report" | awk '
    /"RuleID"[ \t]*:/ { rule = $0; sub(/.*"RuleID"[ \t]*:[ \t]*"/, "", rule); sub(/".*/, "", rule) }
    /"StartLine"[ \t]*:/ { line = $0; sub(/.*"StartLine"[ \t]*:[ \t]*/, "", line); sub(/[^0-9].*/, "", line) }
    /"File"[ \t]*:/ { file = $0; sub(/.*"File"[ \t]*:[ \t]*"/, "", file); sub(/",?[ \t]*$/, "", file); gsub(/\\\\/, "/", file) }
    /^[ \t]*\},?[ \t]*$/ { if (file != "") print file ":" line " (" rule ")"; file = ""; line = ""; rule = "" }
  '
}
if [ "$gl_ver" = "missing" ]; then
  echo "check: note: gitleaks isn't installed, so the check doesn't scan for secrets; install it from https://github.com/gitleaks/gitleaks#installing"
elif [ "$gl_ver" = "unreadable" ]; then
  echo "check: secrets FAIL: gitleaks is installed, but 'gitleaks version' printed no version number."
  echo "       Reinstall it: https://github.com/gitleaks/gitleaks#installing"
  exit 3
elif ! version_gte "$gl_ver" "$gl_min"; then
  echo "check: secrets FAIL: gitleaks $gl_ver is below the minimum $gl_min ([gitleaks] min-version in tools/check.cfg)."
  echo "       Upgrade: https://github.com/gitleaks/gitleaks#installing"
  exit 3
else
  gl_out="$(gl_scan)"; gl_rc=$?
  if [ "$gl_rc" -eq 0 ]; then
    rm -f "$gl_report"
    echo "check: secrets: no credentials found (gitleaks $gl_ver)"
  elif grep -qs '"File"' "$gl_report"; then
    gl_found="$(gl_findings)"
    gl_count="$(printf '%s\n' "$gl_found" | grep -c .)"
    echo "check: secrets FAIL: gitleaks found $gl_count possible credential(s) in the working tree:"
    printf '%s\n' "$gl_found" | head -n 20 | sed 's/^/       /'
    [ "$gl_count" -gt 20 ] && echo "       ... and $((gl_count - 20)) more (see the report)"
    echo "       Report (values redacted): $gl_report"
    echo "       Move the credential out of the file (the environment, or a gitignored file); if it was ever"
    echo "       committed or shared, rotate it. A false positive: add its Fingerprint, from the report, to"
    echo "       .gitleaksignore, record why in design/decisions.md, and have the human approve both."
    failed=1; hard_fail=1
  else
    echo "check: secrets FAIL: gitleaks couldn't scan the working tree."
    gl_last="$(printf '%s\n' "$gl_out" | tr -d '\r' | tail -n 1)"
    [ -n "$gl_last" ] && echo "       gitleaks: $gl_last"
    if [ "$gl_ver" = "8.19.0" ]; then
      echo "       gitleaks 8.19.0 can't scan (every command fails). Upgrade to 8.19.1 or later."
    else
      echo "       Check the error above. Upgrading gitleaks may help."
    fi
    exit 3
  fi
fi

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
elif [ "$status" -ne 0 ]; then
  if silent_exit "$state_dir/import.log"; then exit_quiet "the import pass" "$status" "$state_dir/import.log"
  else echo "check: the import pass exited with $status"; fi
  failed=1; hard_fail=1
fi

# --- 2. load, rules, tests ----------------------------------------------------------------------
# Autoplay in the check (step 3c) plays the scenarios one at a time, each call's output and exit status in
# .godot/godot-director/autoplay_check-<scenario>.log and .status. It never reads or writes the variables
# of this script, so it can run in the background beside the test jobs. AUTOPLAY_JOBS=1: a sweep (--all)
# plays one scenario at a time too, as this is one process of the count.
ap_file() { # ap_file <scenario or --all> <log|status>: where its output or exit status goes
  local tag="${1#--}"
  printf '%s/autoplay_check-%s.%s' "$state_dir" "${tag//[!A-Za-z0-9_]/_}" "$2"
}
ap_play() {
  local id
  for id in $ap_scenarios; do
    GDIR_LOCK_HELD=1 AUTOPLAY_JOBS=1 AUTOPLAY_TIMEOUT="$limit" GODOT_BIN="$godot" bash tools/autoplay.sh $id --no-images > "$(ap_file "$id" log)" 2>&1
    echo $? > "$(ap_file "$id" status)"
  done
}
ap_dir="playtesting/autoplay"
ap_before=""; ap_ran=0; ap_pid=""

# A relative script path on purpose: Git Bash would rewrite some res:// forms.
rm -f "$state_dir"/tests-*.log
test_logs="$state_dir/check.log"
if [ "$par" -eq 0 ]; then
  run_godot "$state_dir/check.log" --headless --path . --script tools/check.gd
  status=$?
  if [ "$status" -eq 124 ]; then timed_out_in "tools/check.gd" "$state_dir/check.log"
  elif [ "$status" -ne 0 ]; then
    if silent_exit "$state_dir/check.log"; then exit_quiet "tools/check.gd" "$status" "$state_dir/check.log"; fi
    failed=1; hard_fail=1
  fi
else
  # The loading and the screen rules run once, beside the test groups.
  [ "$test_jobs" -eq 1 ] && echo "check: running the tests in 1 process" || echo "check: running the tests in $test_jobs processes"
  run_godot "$state_dir/check.log" --headless --path . --script tools/check.gd -- --no-tests &
  main_pid=$!
  pids=""; test_logs=""; k=1
  while [ "$k" -le "$test_jobs" ]; do
    run_godot "$state_dir/tests-$k.log" --headless --path . --script tools/check.gd -- --tests "$k" "$test_jobs" &
    pids="$pids $!"; test_logs="$test_logs $state_dir/tests-$k.log"; k=$((k + 1))
  done
  wait "$main_pid"; status=$?
  if [ "$status" -eq 124 ]; then timed_out_in "tools/check.gd (loading and screen rules)" "$state_dir/check.log"
  elif [ "$status" -ne 0 ]; then
    if silent_exit "$state_dir/check.log"; then exit_quiet "the load pass (tools/check.gd --no-tests)" "$status" "$state_dir/check.log"; fi
    failed=1; hard_fail=1
  fi
  # The import and the load pass are done. If both were clean (the game's own code is about to run),
  # autoplay starts now, in its own process beside the test jobs.
  if [ "$ap_beside" -eq 1 ] && [ "$failed" -eq 0 ]; then
    write_allow "$state_dir/check.log"
    if [ -z "$(scan "$error_pattern" "$state_dir/import.log" "$state_dir/check.log")" ]; then
      echo "check: playing the autoplay scenarios beside the tests"
      ap_before="$(ls "$ap_dir" 2>/dev/null)"
      ap_play &
      ap_pid=$!; ap_ran=1
    fi
  fi
  k=1
  for pid in $pids; do
    wait "$pid"; status=$?
    log="$state_dir/tests-$k.log"
    if [ "$status" -eq 124 ]; then timed_out_in "test group $k of $test_jobs" "$log"
    elif ! clean "$log" | grep -q '^GDIR-TESTS: '; then
      if [ "$status" -ne 0 ] && silent_exit "$log"; then exit_quiet "test group $k of $test_jobs" "$status" "$log"
      else echo "check: test group $k of $test_jobs didn't finish (see $log)"; fi
      failed=1
    elif [ "$status" -ne 0 ]; then
      if silent_exit "$log"; then exit_quiet "test group $k of $test_jobs" "$status" "$log"; fi
      failed=1; hard_fail=1
    fi
    k=$((k + 1))
  done
  [ -z "$ap_pid" ] || wait "$ap_pid"
  test_logs="$state_dir/check.log$test_logs"
  if [ "${GDIR_CHECK_DEAL:-}" = "1" ]; then clean "$state_dir/tests-1.log" | sed -n 's/^GDIR-DEAL: /check: deal: job /p'; fi
fi

# Each test file's times for the next run's deal (path, whole seconds, shards, longest shard seconds).
# A whole run sets all three. A split run whose shards all reported sets the shard count and the
# longest shard, and the whole time to their sum only when that is lower (so a split never grows from
# its own overhead; `--jobs 1` re-measures a file whole); one with a shard missing (timed out or
# crashed) keeps the file's stored line. A file that didn't run keeps its line while it exists; nothing is written when
# no test reported a time. The file is replaced in one move, so a stopped run never leaves half of it.
times_file="$state_dir/test-times.tsv"
for log in $test_logs; do [ -f "$log" ] && clean "$log"; done | sed -n -e 's/^GDIR-TIME: /T /p' -e 's/^GDIR-SHARDS: /S /p' \
  | awk -v old="$times_file" '
    { kind = $1; n = $2; path = $0; sub(/^[TS] [0-9]+ /, "", path)
      if (kind == "S") { shards[path] = n; done[path]++; next }
      seen = 1; total[path] += n; if (n > longest[path]) longest[path] = n }
    END {
      if (!seen) exit 1
      while ((getline line < old) > 0) {
        count = split(line, field, "\t"); path = field[1]
        if (path == "" || count < 2) continue
        if (path in total) { stored[path] = line; stored_whole[path] = field[2]; continue }
        file = path; sub(/^res:\/\//, "", file)
        if ((getline dummy < file) >= 0) { close(file); print line }
      }
      for (path in total) {
        if (!(path in shards)) printf "%s\t%.3f\t1\t%.3f\n", path, total[path] / 1000, total[path] / 1000
        else if (done[path] >= shards[path]) {
          w = sprintf("%.3f", total[path] / 1000)
          if ((path in stored_whole) && stored_whole[path] + 0 < w + 0) w = stored_whole[path]
          printf "%s\t%s\t%d\t%.3f\n", path, w, shards[path], longest[path] / 1000
        }
        else if (path in stored) print stored[path]
      }
    }' > "$times_file.new" && /usr/bin/sort "$times_file.new" > "$times_file.tmp" && mv -f "$times_file.tmp" "$times_file"
rm -f "$times_file.new" "$times_file.tmp"

# --- 3. scan the output -------------------------------------------------------------------------

write_allow $test_logs
errors="$(scan "$error_pattern" "$state_dir/import.log" $test_logs)"
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
    ui_errors="$(scan "$error_pattern" "$ui_log")"
    if [ -n "$ui_errors" ]; then errors="$ui_errors"; fi
    ui_warnings="$(scan '^[ \t]*(WARNING|SCRIPT WARNING|USER WARNING):' "$ui_log")"
    if [ -n "$ui_warnings" ]; then warnings="${warnings:+$warnings
}$ui_warnings"; fi
  fi
fi

# --- 3c. autoplay (opt in) ----------------------------------------------------------------------
# The scenarios and what fails the check are read above (tools/check.cfg > [autoplay]). A parallel run
# started them already, as soon as the import and the load pass were clean, beside the test jobs; a
# serial run plays them here, once everything above was clean: the game's own code runs. Either way the
# result joins the report here. While the game's adapter is still the seed's, the run is skipped with a
# note that names what to wire.
ap_notes=""
if [ "$ap_on" -eq 1 ] && [ "$par" -eq 0 ] && [ "$failed" -eq 0 ] && [ -z "$errors" ]; then
  ap_before="$(ls "$ap_dir" 2>/dev/null)"
  ap_play
  ap_ran=1
fi
if [ "$ap_ran" -eq 1 ]; then
  for id in $ap_scenarios; do
    enforced=0
    case " $ap_enforce " in *" $id "*|*" * "*) enforced=1 ;; esac
    ap_log="$(ap_file "$id" log)"
    ap_status="$(cat "$(ap_file "$id" status)" 2>/dev/null)"
    case "$ap_status" in ''|*[!0-9]*) ap_status=1 ;; esac
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

summary="$(clean "$state_dir/check.log" | grep -E '^GDIR(-NOTE)?:')"
if [ "$par" -eq 1 ]; then
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
  if [ "$ui_status" -ne 0 ] && [ "$ui_status" -ne 124 ] && [ -z "$ui_errors" ]; then
    exit_quiet "the layout lint (tools/ui_capture.gd --check)" "$ui_status" "$ui_log"
    failed=1
  elif [ "$ui_status" -ne 0 ] && [ -z "$(clean "$ui_log" | grep -E '^[[:space:]]*(GDIR-FAIL|ERROR|SCRIPT ERROR):')" ]; then
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

# Every run ends with the slowest test files (each file's or shard's time is in the logs, as
# GDIR-TIME: <ms> <file>; a file's shards add up).
slowest() {
  for log in $test_logs; do [ -f "$log" ] && clean "$log"; done | sed -n 's/^GDIR-TIME: //p' \
    | awk '{ ms = $1; sub(/^[0-9]+ /, ""); sum[$0] += ms } END { for (f in sum) print sum[f] " " f }' | /usr/bin/sort -rn \
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
    cache_key "$before" > "$state_dir/last-pass"
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
if [ -n "$before" ] && [ "$before" = "$(fingerprint)" ]; then cache_key "$before" > "$state_dir/last-fail"; fi
slowest
echo "check: FAIL (full logs in $state_dir/)"
exit 1
