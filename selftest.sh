#!/usr/bin/env bash
# Godot Director self-test. It installs the framework into temporary copies of examples/market-day
# and tests the installer, the project check, the per-clone setup, the Claude Code hooks and the
# pre-commit hook. Run it after every change to the framework.
#
#   bash selftest.sh [path to Godot 4.5+]      (or set GODOT_BIN)
#
# Without Godot, only the parts that don't need it are tested. KEEP=1 keeps the temporary folder.
# The sections run side by side as lanes (see "lanes" below): SELFTEST_LANES=1 runs them one by one, and
# SELFTEST_ONLY=a,b runs only the lanes with these names.

set -u
src="$(cd "$(dirname "$0")" && pwd)"
godot="${1:-${GODOT_BIN:-}}"
work="$(mktemp -d)"
if [ "${KEEP:-0}" = "1" ]; then echo "keeping $work"; else trap 'kill $(jobs -p) 2>/dev/null; rm -rf "$work"' EXIT; fi

passed=0; failed=0
nl='
'
ok()  { passed=$((passed + 1)); echo "  ok    $1"; }
bad() { failed=$((failed + 1)); echo "  FAIL  $1"; [ -n "${2:-}" ] && printf '%s\n' "$2" | tail -n 15 | sed 's/^/          /'; }
expect_status() { # <what> <expected> <actual> [output]
  if [ "$3" -eq "$2" ]; then ok "$1"; else bad "$1 (exit $3, expected $2)" "${4:-}"; fi
}
expect_output() { # <what> <extended regex> <output>
  if printf '%s' "$3" | grep -qE -- "$2"; then ok "$1"; else bad "$1 (no match for /$2/)" "$3"; fi
}
expect_no_output() { # <what> <extended regex> <output>
  if printf '%s' "$3" | grep -qE -- "$2"; then bad "$1 (unexpected /$2/)" "$3"; else ok "$1"; fi
}
git_q() { git -c user.name=selftest -c user.email=selftest@localhost "$@"; }
hash_of() { git hash-object --stdin < "$1"; }
finish() {
  echo "selftest: $passed passed, $failed failed"
  [ "$failed" -eq 0 ]
  exit $?
}
new_repo() { # new_repo <folder>: an empty git repository with one commit
  mkdir -p "$1" && (cd "$1" && git init -q && git config core.autocrlf false && printf '# game\n' > README.md && git add -A && git_q commit -qm init)
}

# --- lanes --------------------------------------------------------------------------------------
# One after the other the sections below take about two hours on a busy Windows machine, nearly all of it
# waiting for processes to start (Git Bash forks slowly, and every check run starts several Godots). They
# don't depend on each other's results, only on a game installed from the example, so each runs as a lane:
# a background subshell with its own copy of that game, its own scratch folder ($work) and its own user://
# folder, its output going to a file. At the end the files are printed in the order the sections had and the
# counts added up, so the output is the sections' output one after the other, and only the time changes.
#   SELFTEST_LANES=<n>   lanes at a time (default: a third more than the processors, 16 at most; 1 runs them one by one)
#   SELFTEST_ONLY=a,b    only the lanes with these names (a development aid; "the run" at the end names them)
#   SELFTEST_TIMES=1     when each lane started and ended, on stderr, just before the last line
main_work="$work"
lane_dir="$work/lanes"; mkdir -p "$lane_dir"
lane_list=" "
lane_jobs="${SELFTEST_LANES:-}"
if [ -z "$lane_jobs" ]; then
  lane_jobs=$(nproc 2>/dev/null || getconf _NPROCESSORS_ONLN 2>/dev/null || echo 4)
  case "$lane_jobs" in ''|*[!0-9]*) lane_jobs=4 ;; esac
  lane_jobs=$((lane_jobs + lane_jobs / 3))   # a few more than the processors: a lane spends much of its time waiting for a process to start
  [ "$lane_jobs" -le 16 ] || lane_jobs=16
  # Godot's user:// folder can't be moved on macOS, so lanes there would share one: they run one by one
  [ "$(uname -s)" != Darwin ] || lane_jobs=1
fi
case "$lane_jobs" in ''|*[!0-9]*|0) lane_jobs=1 ;; esac
base=""; ready=""; warm=""

lane_isolate() { # the lane's own user:// folder, so no other lane's Godot writes into the one a case looks at
  local d="$work/appdata"
  mkdir -p "$d"
  case "$(uname -s)" in
    MINGW*|MSYS*|CYGWIN*) command -v cygpath >/dev/null 2>&1 && d="$(cygpath -w "$d")"; export APPDATA="$d" ;;
    Darwin) ;;
    *) export XDG_DATA_HOME="$d" ;;
  esac
}
lane_body() { # lane_body <name> <function>: in a subshell of its own, with its counts, output and a mark for a normal end in $lane_dir
  lane_self="$1"; passed=0; failed=0; lane_t0=$SECONDS
  work="$main_work/lane-$1"; mkdir -p "$work"; cd "$work" || exit 1
  lane_isolate
  trap 'echo "$passed $failed" > "$lane_dir/$lane_self.count"; echo "$lane_t0 $SECONDS" > "$lane_dir/$lane_self.secs"' EXIT
  "$2" > "$lane_dir/$1.out" 2>&1
  : > "$lane_dir/$1.done"
}
# The games the lanes copy, each made once: base is the example with the framework installed (the first
# install of "installer"), ready is base with the clone set up (hooks, and the Godot path saved the way
# PowerShell writes it), warm is ready after one passing check (the import and the class cache are there).
prepare_base() {
  local d="$main_work/base-game"
  cp -R "$src/examples/market-day" "$d"
  rm -rf "$d/.godot" "$d/.claude" "$d/.godot-director" "$d/.githooks" "$d/tools/godot_bin.local"
  (cd "$d" && git init -q && git config core.autocrlf false && git add -A && git_q commit -qm "example" \
    && bash "$src/install.sh" . >/dev/null 2>&1) || { echo "selftest: couldn't prepare the game"; exit 1; }
  base="$d"
}
prepare_ready() {
  local d="$main_work/ready-game"
  cp -R "$base" "$d" && (cd "$d" && { bash tools/setup-clone.sh "$godot" >/dev/null 2>&1; printf '\357\273\277%s  \r\n' "$godot" > tools/godot_bin.local; })
  ready="$d"
}
prepare_warm() {
  local d="$main_work/warm-game"
  cp -R "$ready" "$d" && (cd "$d" && bash tools/check.sh >/dev/null 2>&1)
  warm="$d"
}
prepare() { # prepare base|ready|warm
  case "$1" in
    base) [ -n "$base" ] || prepare_base ;;
    ready) prepare base; [ -n "$ready" ] || prepare_ready ;;
    warm) prepare ready; [ -n "$warm" ] || prepare_warm ;;
  esac
}
lane_game() { # lane_game base|ready|warm: this lane's game, a copy of the prepared one; it is $game and the working folder
  local from
  case "$1" in base) from="$base" ;; ready) from="$ready" ;; *) from="$warm" ;; esac
  game="$work/game"
  cp -R "$from" "$game" && cd "$game" || exit 1
}
lane_count_busy() {
  local name
  lane_busy=0
  for name in $lane_list; do
    [ -f "$lane_dir/$name.count" ] || lane_busy=$((lane_busy + 1))
  done
}
lane_start() { # lane_start <name> <function> [base|ready|warm]: when a place is free and the game it copies is made
  local name="$1"
  case ",${SELFTEST_ONLY:-}," in ",,") ;; *",$name,"*) ;; *) return 0 ;; esac
  [ -z "${3:-}" ] || prepare "$3"
  lane_count_busy
  while [ "$lane_busy" -ge "$lane_jobs" ]; do sleep 1; lane_count_busy; done
  lane_list="$lane_list$name "
  if [ "$lane_jobs" -gt 1 ]; then
    ( lane_body "$name" "$2" ) &
    echo $! > "$lane_dir/$name.pid"
  else
    ( lane_body "$name" "$2" )
  fi
}
lanes_times() { # SELFTEST_TIMES=1: when each lane started and how long it ran, on stderr (the output stays as it is)
  [ -n "${SELFTEST_TIMES:-}" ] || return 0
  local name a b
  for name in $lane_list; do
    a="?"; b="?"; read -r a b < "$lane_dir/$name.secs" 2>/dev/null
    echo "lane $name: started at $a s, ended at $b s" >&2
  done
}
lanes_print() { # lanes_print <name>...: the output of these lanes in this order, and their counts added to the totals
  local name pid p f
  for name in "$@"; do
    case "$lane_list" in *" $name "*) ;; *) continue ;; esac
    if [ -f "$lane_dir/$name.pid" ]; then read -r pid < "$lane_dir/$name.pid"; wait "$pid" 2>/dev/null; fi
    cat "$lane_dir/$name.out"
    if [ -f "$lane_dir/$name.count" ]; then
      read -r p f < "$lane_dir/$name.count"; passed=$((passed + p)); failed=$((failed + f))
    fi
    [ -f "$lane_dir/$name.done" ] || bad "the $name part stopped before its last case"
  done
}

# --- shared by the lanes ----------------------------------------------------------------------
settings="$src/framework/.claude/settings.json"
stories_tpl="$src/framework/.godot-director/templates/user-stories.md"
stories_ex="$src/examples/market-day/design/user-stories.md"

git_fail=""
guard_report() { # guard_report <failed cases> <what is wrong> <what holds>: one line for a block of cases, and the failed ones under it
  if [ -n "$1" ]; then
    bad "$2"
    printf '%s\n' "${1#$'\n'}" | sed 's/^/          /'
  else ok "$3"; fi
  git_fail=""
}
# json_str <text>: sets JSON_STR to the text as the inside of a JSON string, with \, ", a line break, a tab and a return escaped.
json_str() {
  local s="$1" out="" i c
  for ((i = 0; i < ${#s}; i++)); do
    c="${s:i:1}"
    case $c in
      '\') out+='\\' ;;
      '"') out+='\"' ;;
      $'\n') out+='\n' ;;
      $'\t') out+='\t' ;;
      $'\r') out+='\r' ;;
      *) out+="$c" ;;
    esac
  done
  JSON_STR="$out"
}
# The guard cases (Director-Driven-Development B41). guard queues a case: its JSON payload goes to a file, and its expected
# exit code, tool and text are kept. guard_run runs the queued cases, guard_jobs at a time, each as its own run of the hook
# with its own payload, then checks every exit code against that case's expected one, in the order the cases were queued,
# so a failure names its case and why. Each block of cases ends with guard_run and guard_report.
guard_jobs=$(nproc 2>/dev/null || getconf _NPROCESSORS_ONLN 2>/dev/null || echo 4); [ "$guard_jobs" -le 8 ] || guard_jobs=8
guard_cmds=(); guard_exps=(); guard_tools=(); guard_pats=()
guard() { # guard <expected exit> <command> [tool name: Bash by default, or PowerShell] [extended regex the guard's message must match]
  local n=${#guard_cmds[@]} tool="${3:-Bash}"
  json_str "$2"
  printf '{"session_id":"s","tool_name":"%s","tool_input":{"command":"%s","description":"run"}}' "$tool" "$JSON_STR" > "$guard_dir/$n.json"
  guard_cmds+=("$2"); guard_exps+=("$1"); guard_tools+=("$tool"); guard_pats+=("${4:-}")
}
guard_run() { # runs the queued cases, guard_jobs workers at a time; worker k takes cases k, k + guard_jobs, ...
  local n=${#guard_cmds[@]} i k w msg
  local -a pid=()
  [ "$n" -gt 0 ] || return 0
  w=$guard_jobs; [ "$w" -le "$n" ] || w=$n
  for ((k = 0; k < w; k++)); do
    (
      for ((i = k; i < n; i += w)); do
        bash .claude/hooks/guard-git.sh < "$guard_dir/$i.json" >/dev/null 2>"$guard_dir/$i.err"
        echo $? > "$guard_dir/$i.rc"
      done
    ) &
    pid[k]=$!
  done
  for ((k = 0; k < w; k++)); do wait "${pid[k]}"; done
  for ((i = 0; i < n; i++)); do
    rc="missing"; read -r rc < "$guard_dir/$i.rc" 2>/dev/null
    if [ "$rc" != "${guard_exps[i]}" ]; then
      git_fail="$git_fail"$'\n'"  guard exited $rc, expected ${guard_exps[i]} (${guard_tools[i]}): ${guard_cmds[i]//$'\n'/ NL }"
    elif [ -n "${guard_pats[i]}" ]; then   # a case with a pattern also checks what the guard said
      msg=""; read -r -d '' msg < "$guard_dir/$i.err" 2>/dev/null
      [[ $msg =~ ${guard_pats[i]} ]] || git_fail="$git_fail"$'\n'"  guard's message doesn't match /${guard_pats[i]}/ (${guard_tools[i]}): ${guard_cmds[i]//$'\n'/ NL }"
    fi
  done
  guard_cmds=(); guard_exps=(); guard_tools=(); guard_pats=()
  rm -f "$guard_dir"/*.json "$guard_dir"/*.rc "$guard_dir"/*.err
}

# The guard reads a long file body in time: measured first, in guard_slow_measure, while the lanes aren't running yet (a
# timing is the one result a busy machine changes). The guard lane reports it where the measurement used to be.
guard_slow_measure() {
  local slow_dir="$work/slow-body"
  mkdir -p "$slow_dir/.claude" "$slow_dir/guard-cases" && cp -R "$src/framework/.claude/hooks" "$slow_dir/.claude/hooks" || return 1
  local guard_dir="$slow_dir/guard-cases"
  cd "$slow_dir" || return 1
gd_body='extends Node2D'$'\n'
while ((${#gd_body} < 25000)); do gd_body+=$'\t$AnimationPlayer.play("walk")\n\t$Sprite2D.flip_h = not $Sprite2D.flip_h # it\'s "x"\n'; done
py_body='import sys'$'\n'
while ((${#py_body} < 25000)); do py_body+=$'def copy_py(x):\n    # python data, it\'s "ok"\n    return x\n'; done
slow_cmds=($'cat > scripts/hero.gd <<\'EOF\'\n'"$gd_body"$'EOF' $'@\'\n'"$gd_body"$'\'@ | Set-Content scripts/hero.gd' $'python3 tool.py <<\'EOF\'\n'"$py_body"$'EOF')
# T294: 300 lines (about 14 KB) that name bash.exe and git.exe -c, in a heredoc and a here-string. Every line gives the wrapper gate and
# the git option rules something to read, so this body costs more than the GDScript one (about 1 second, where the GDScript body takes
# 0.4 to 1.2), and it grows faster than its length (900 lines take about 6, with nothing else running): the limit of 5 seconds holds with room to spare here.
nm_body=""
for ((si = 0; si < 300; si++)); do nm_body+=$'see C:\\Git\\bin\\bash.exe -c and git.exe -c here\n'; done
slow_cmds+=($'cat > scripts/hero.gd <<\'EOF\'\n'"$nm_body"$'EOF' $'@\'\n'"$nm_body"$'\'@ | Set-Content scripts/hero.gd')
slow_tools=(Bash PowerShell Bash Bash PowerShell); slow_names=(heredoc here-string python-data named-heredoc named-here-string); slow_fail=""; slow_times=""
for ((si = 0; si < ${#slow_cmds[@]}; si++)); do
  json_str "${slow_cmds[si]}"
  printf '{"session_id":"s","tool_name":"%s","tool_input":{"command":"%s","description":"run"}}' "${slow_tools[si]}" "$JSON_STR" > "$guard_dir/slow.json"
  TIMEFORMAT=%R
  slow_out=$( { time { LC_ALL=C.UTF-8 bash .claude/hooks/guard-git.sh < "$guard_dir/slow.json" >/dev/null 2>&1; echo "rc $?" >&2; }; } 2>&1 )
  unset TIMEFORMAT
  slow_rc="${slow_out#*rc }"; slow_rc="${slow_rc%%[!0-9]*}"; slow_s="${slow_out##*[!0-9.]}"
  slow_times="$slow_times ${slow_names[si]} (${slow_tools[si]}) ${slow_s}s,"
  [ "$slow_rc" = 0 ] || slow_fail="$slow_fail"$'\n'"  (${slow_tools[si]}) the guard exited $slow_rc on a long ${slow_names[si]} body, expected 0"
  [ "${slow_s%%.*}" -lt 5 ] 2>/dev/null || slow_fail="$slow_fail"$'\n'"  (${slow_tools[si]}) the guard took ${slow_s}s on a long ${slow_names[si]} body, over 5 seconds"
done
rm -f "$guard_dir/slow.json"
  cd "$work"
}

guard_write() { # guard_write <expected exit> <what> <file_path as sent (JSON-escaped)> [project dir]
  local out got
  out="$(printf '{"session_id":"s","tool_name":"Write","tool_input":{"file_path":"%s","content":"x"}}' "$3" \
    | CLAUDE_PROJECT_DIR="${4:-$game}" bash .claude/hooks/guard-protected.sh 2>&1)"
  got=$?
  if [ "$got" -eq "$1" ]; then ok "$([ "$1" -eq 2 ] && echo blocks || echo allows): $2"; else bad "guard-protected exit $got, expected $1: $2" "$out"; fi
}

user_data_init() { # the example's real user:// folder, in this lane's own APPDATA (or XDG_DATA_HOME)
  case "$(uname -s)" in
    MINGW*|MSYS*|CYGWIN*) user_data="$(cygpath -u "$APPDATA")/Godot/app_userdata/Market Day" ;;
    Darwin) user_data="$HOME/Library/Application Support/Godot/app_userdata/Market Day" ;;
    *) user_data="${XDG_DATA_HOME:-$HOME/.local/share}/godot/app_userdata/Market Day" ;;
  esac
}

gen_token() { # gen_token: sets _tok to "ghp_" and 36 generated letters and digits
  local chars='ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789' i
  _tok="ghp_"
  for ((i = 0; i < 36; i++)); do _tok="$_tok${chars:$((RANDOM % 62)):1}"; done
}
gitleaks_prelude() { # the gitleaks found here, a PATH without it, and a stand-in (sets _gl_ok, _gl_real, _no_gl_path, _no_gl_ok, _fake_gl)
_gl_ok=0; _gl_real=""
if command -v gitleaks >/dev/null 2>&1; then
  _gl_real="$(gitleaks version 2>/dev/null | tr -d 'v \r\n')"
  _gl_maj="${_gl_real%%.*}"; _gl_rest="${_gl_real#*.}"; _gl_mnr="${_gl_rest%%.*}"
  case "$_gl_maj$_gl_mnr" in
    ''|*[!0-9]*) ;;
    *) if [ "$_gl_real" != "8.19.0" ] && { [ "$_gl_maj" -gt 8 ] || { [ "$_gl_maj" -eq 8 ] && [ "$_gl_mnr" -ge 18 ]; }; }; then _gl_ok=1; fi ;;
  esac
fi
# A PATH without gitleaks: every directory that holds it is left out (the other tools must remain).
_no_gl_path=""
while IFS= read -r _dir; do
  [ -n "$_dir" ] || continue
  if [ -x "$_dir/gitleaks" ] || [ -x "$_dir/gitleaks.exe" ]; then continue; fi
  _no_gl_path="${_no_gl_path:+$_no_gl_path:}$_dir"
done <<EOF
$(printf '%s\n' "$PATH" | tr ':' '\n')
EOF
_no_gl_ok=1
for _tool in git bash awk sed tr grep head tail cat mkdir rm find sort; do
  PATH="$_no_gl_path" command -v "$_tool" >/dev/null 2>&1 || _no_gl_ok=0
done
PATH="$_no_gl_path" command -v gitleaks >/dev/null 2>&1 && _no_gl_ok=0
# A stand-in gitleaks: it reports FAKE_GL_VERSION, logs each call to FAKE_GL_LOG, and a scan finds nothing,
# or fails with FAKE_GL_ERROR's text and no report (as 8.19.0 does for every command). protect, the staged
# scan, writes one finding in FAKE_GL_FINDING (a file) when it is set, in the report's own layout.
_fake_gl="$work/fake-gl"; mkdir -p "$_fake_gl"
cat > "$_fake_gl/gitleaks" << 'FAKE'
#!/usr/bin/env bash
[ -n "${FAKE_GL_LOG:-}" ] && printf '%s\n' "$*" >> "$FAKE_GL_LOG"
case "$1" in
  version) echo "v${FAKE_GL_VERSION:-8.30.1}" ;;
  dir|detect|protect)
    for a in "$@"; do case "$a" in --report-path=*) report="${a#--report-path=}" ;; esac; done
    if [ -n "${FAKE_GL_ERROR:-}" ]; then echo "$FAKE_GL_ERROR"; exit 1; fi
    if [ "$1" = protect ] && [ -n "${FAKE_GL_FINDING:-}" ]; then
      printf '[\n {\n  "RuleID": "selftest-rule",\n  "StartLine": 7,\n  "Match": "REDACTED",\n  "Secret": "REDACTED",\n  "File": "%s",\n  "Fingerprint": "%s:selftest-rule:7"\n }\n]\n' "$FAKE_GL_FINDING" "$FAKE_GL_FINDING" > "$report"
      exit 1
    fi
    exit 0 ;;
  *) exit 0 ;;
esac
FAKE
chmod +x "$_fake_gl/gitleaks"
}

runs=playtesting/autoplay
latest_run() { ls -d "$runs/$1"-* 2>/dev/null | grep -v -- '-replay' | LC_ALL=C /usr/bin/sort | tail -n 1; }
after_line() { # after_line <file> <exact line> <lines to add after it>; awk reads \t and \n in both
  awk -v line="$2" -v text="$3" '{ print } $0 == line { print text }' "$1"
}
replace_line() { # replace_line <file> <exact line> <its replacement>
  awk -v line="$2" -v text="$3" '{ print ($0 == line ? text : $0) }' "$1"
}
normalized() { # a run's JSONL without time stamps, run ids and timing lines
  sed -e 's/^{"t":[0-9]*,/{/' -e 's/[0-9]\{8\}-[0-9]\{6\}\(-[0-9][0-9]*\)\{0,1\}/<id>/g' "$1"/run-*.jsonl \
    | grep -v -e '"event":"frame.hitch"' -e '"event":"window.focus"'
}

crash_defs() {
# A Godot process that exits 139 (a segmentation fault) with a clean log: the check names the process, its
# status and its log in one line before the FAIL, and the exit code stays 1. crashy <pattern> [silent]: a
# stand-in for Godot that runs the real one, then exits 139 for a call whose arguments contain the pattern;
# with "silent" it exits 139 before running anything, so the log stays empty.
crashy() {
  if [ "${2:-}" = "silent" ]; then
    cat > "$work/godot-crash" <<CRASH
#!/usr/bin/env bash
case "\$*" in *"$1"*) exit 139 ;; esac
"$godot" "\$@"
CRASH
  else
    cat > "$work/godot-crash" <<CRASH
#!/usr/bin/env bash
"$godot" "\$@"
status=\$?
case "\$*" in *"$1"*) exit 139 ;; esac
exit \$status
CRASH
  fi
  chmod +x "$work/godot-crash"
}
line_of() { printf '%s\n' "$1" | grep -n -E -- "$2" | head -n 1 | cut -d: -f1; }
before() { # before <output> <regex> <regex>: the first line matching the first regex comes before the second's
  local a b
  a="$(line_of "$1" "$2")"; b="$(line_of "$1" "$3")"
  [ -n "$a" ] && [ -n "$b" ] && [ "$a" -lt "$b" ]
}
}

parallel_prelude() { # the example's [autoplay] left out of tools/check.cfg, and the helpers the parallel-tests lanes share
logs=".godot/godot-director"
# These cases count the processes that run the tests, and autoplay in the check takes one of them, so
# the example's [autoplay] is left out here ("autoplay beside the tests" covers it).
cp tools/check.cfg "$work/saved-check-cfg-ap"
awk '/^\[autoplay\]$/ { skip = 1; next } /^\[/ { skip = 0 } !skip' "$work/saved-check-cfg-ap" > tools/check.cfg
test_order() { for f in "$@"; do tr -d '\r' < "$f"; done | sed -n 's/^GDIR-TEST: \(.*\)::.*$/\1/p' | uniq; }
deal_of() { printf '%s\n' "$1" | sed -n 's/^check: deal: job \([0-9]*\) [0-9.?]* /\1 /p' | tr '\n' ';'; }
times="$logs/test-times.tsv"
}

l_framework() {
cd "$work" || exit 1
# --- framework files ----------------------------------------------------------------------------
echo "framework"
plugin_version="$(sed -n 's/.*"version"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$src/.claude-plugin/plugin.json")"
[ "$plugin_version" = "$(tr -d '\r\n' < "$src/VERSION")" ] && ok "plugin.json version matches VERSION" \
  || bad "plugin.json version ($plugin_version) matches VERSION ($(cat "$src/VERSION"))"
installer="$src/skills/godot-director/SKILL.md"
if [ -f "$installer" ] && grep -q '^name: godot-director$' "$installer" && grep -q '^description: ' "$installer"     && grep -q 'ONBOARDING.md' "$installer" && grep -qE 'git .*clone ' "$installer"     && [ "$(find "$src" -name SKILL.md -not -path "*/.git/*" -mindepth 2 -maxdepth 4 | wc -l)" -eq 1 ]; then
  ok "the installer skill is the only one the skills CLI finds, and fetches Godot Director on its own"
else
  bad "skills/godot-director/SKILL.md (name, description, self-contained fetch, only skill found by npx skills add)"
fi
# Every install path gets the latest release, tagged v<version>. The files that carry the version
# must agree with VERSION: the skill's metadata.version and the release it clones, and the release
# the marketplace pins the plugin to.
version="$(tr -d '\r\n' < "$src/VERSION")"
skill_version=""; branch=""; dashes=0
while IFS= read -r line; do
  [ "$line" = "---" ] && { dashes=$((dashes + 1)); continue; }
  if [ "$dashes" -eq 1 ]; then case "$line" in "  version: "*) skill_version="${line#  version: }" ;; esac; fi
  [[ $line =~ --branch[[:space:]]+v([0-9.]+) ]] && branch="${BASH_REMATCH[1]}"
done < "$installer"
[ "$skill_version" = "$version" ] && [ "$branch" = "$version" ] \
  && ok "the installer skill's metadata.version and the release it clones match VERSION" \
  || bad "skills/godot-director/SKILL.md: version '$skill_version', clones v$branch, VERSION is $version"
pinned_ref="$(sed -n 's/.*"ref"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$src/.claude-plugin/marketplace.json")"
[ "$pinned_ref" = "v$version" ] && ok "the marketplace pins the plugin to the release v<VERSION>" \
  || bad "the marketplace pins the plugin to '$pinned_ref', VERSION is $version"
cmp -s "$src/LICENSE" "$src/framework/.godot-director/LICENSE" && ok "the installed LICENSE copy matches LICENSE" \
  || bad "framework/.godot-director/LICENSE differs from LICENSE"
# The import skip is one block copied into check.sh, autoplay.sh and ui_capture.sh: the copies must agree.
import_block() { sed -n '/^# >>> import skip/,/^# <<< import skip/p' "$1"; }
block="$(import_block "$src/framework/tools/check.sh")"
if [ -n "$block" ] && [ "$block" = "$(import_block "$src/framework/tools/autoplay.sh")" ] \
    && [ "$block" = "$(import_block "$src/framework/tools/ui_capture.sh")" ]; then
  ok "the import skip is the same block in check.sh, autoplay.sh and ui_capture.sh"
else
  bad "the import skip block differs between check.sh, autoplay.sh and ui_capture.sh"
fi
# Staging a new file must not change either fingerprint. git lists untracked files before tracked ones, so
# staging scripts/z.gd moved it in the list the check hashes, though no file's content had changed.
fp_game="$work/fp-game"; new_repo "$fp_game" || exit 1
cd "$fp_game" || exit 1
mkdir -p tools scripts art
cp "$src/framework/tools/check.sh" tools/check.sh
printf 'config_version=5\n' > project.godot
printf 'extends Node\n' > scripts/a.gd
printf 'a\n' > art/a.png
git add -A && git_q commit -qm files
printf 'extends Node\nclass_name Zed\n' > scripts/z.gd
printf 'z\n' > art/z.png
fp_before="$(bash tools/check.sh --fingerprint)"
imp_before="$(eval "$block"; import_fingerprint)"
git add scripts/z.gd art/z.png
fp_after="$(bash tools/check.sh --fingerprint)"
imp_after="$(eval "$block"; import_fingerprint)"
printf 'extends Node2D\n' > scripts/a.gd
fp_changed="$(bash tools/check.sh --fingerprint)"
cd "$work" || exit 1
if [ -n "$fp_before" ] && [ "$fp_before" = "$fp_after" ]; then ok "staging a new file keeps the check's fingerprint"
else bad "staging a new file changes the check's fingerprint ($fp_before before, $fp_after after)"; fi
if [ -n "$imp_before" ] && [ "$imp_before" = "$imp_after" ]; then ok "staging a new file keeps the import fingerprint"
else bad "staging a new file changes the import fingerprint ($imp_before before, $imp_after after)"; fi
if [ -n "$fp_after" ] && [ "$fp_changed" != "$fp_after" ]; then ok "a changed script still changes the check's fingerprint"
else bad "a changed script does not change the check's fingerprint ($fp_after before, $fp_changed after)"; fi
missing=""
for skill in "$src"/framework/.claude/skills/*/SKILL.md; do
  name="$(basename "$(dirname "$skill")")"
  [ -f "$src/framework/.godot-director/procedures/$name.md" ] || missing="$missing $name"
  grep -q "^name: $name$" "$skill" || missing="$missing $name(name)"
done
[ -z "$missing" ] && ok "every skill points to an existing procedure" || bad "skills without procedures:$missing"
missing=""
for doc in "$src"/framework/.godot-director/rules.md "$src"/framework/.godot-director/procedures/*.md "$src"/project/TASKS.md; do
  for ref in $(grep -o '[a-z-]*\.md' "$doc" | sort -u); do
    case "$ref" in
      rules.md|tasks.md|research-domain.md) [ -f "$src/framework/.godot-director/$ref" ] || missing="$missing $(basename "$doc")→$ref" ;;
      next-task.md|build.md|design.md|research.md|playtest.md|function-check.md|align.md|drift-reset.md|prune.md|review.md|refresh-model-sizing.md|ui-design.md|prototype.md)
        [ -f "$src/framework/.godot-director/procedures/$ref" ] || missing="$missing $(basename "$doc")→$ref" ;;
    esac
  done
done
[ -z "$missing" ] && ok "rules and procedures only point to files that exist" || bad "dangling references:$missing"
missing=""
for procedure in "$src"/framework/.godot-director/procedures/*.md; do
  name="$(basename "$procedure")"
  grep -qF "$name" "$src/framework/.godot-director/rules.md" || missing="$missing $name"
done
[ -z "$missing" ] && ok "rules.md names every procedure" || bad "procedures rules.md doesn't name:$missing"
grep -q 'drift-reset\.md' "$src/framework/.godot-director/procedures/align.md" \
  && grep -q '^disable-model-invocation: true$' "$src/framework/.claude/skills/drift-reset/SKILL.md" \
  && ok "align recommends the drift reset, and only the human can start it" \
  || bad "align.md must recommend drift-reset.md, and the drift-reset skill must set disable-model-invocation"
missing=""
for agent in "$src"/framework/.claude/agents/*.md; do
  procedure="$(grep -o '\.godot-director/procedures/[a-z-]*\.md' "$agent" | head -n 1)"
  procedure="${procedure##*/}"
  [ -n "$procedure" ] && [ -f "$src/framework/.godot-director/procedures/$procedure" ] || missing="$missing $(basename "$agent")"
done
[ -z "$missing" ] && ok "every subagent points to an existing procedure" || bad "subagents without procedures:$missing"
# The research assistant: every piece exists and is wired in, and the researcher can read and search but not change anything.
missing=""
for file in framework/.godot-director/procedures/research.md framework/.godot-director/research-domain.md \
    framework/.claude/agents/researcher.md framework/.claude/skills/research/SKILL.md \
    project/design/research/README.md examples/market-day/design/research/README.md; do
  [ -f "$src/$file" ] || missing="$missing $file"
done
[ -z "$missing" ] && ok "the research assistant's files exist" || bad "research assistant files missing:$missing"
researcher="$src/framework/.claude/agents/researcher.md"
if [ "$(sed -n 's/^tools: //p' "$researcher" | tr -d '\r')" = "Read, Grep, Glob, WebSearch, WebFetch" ] \
    && grep -q '^model: inherit' "$researcher" \
    && grep -Eq '^ *"WebSearch",?[[:space:]]*$' "$settings" && grep -Eq '^ *"WebFetch",?[[:space:]]*$' "$settings"; then
  ok "the researcher has read, search and fetch tools only, and settings.json allows web search and fetch"
else
  bad "researcher.md must have exactly the tools Read, Grep, Glob, WebSearch, WebFetch (no edit, write or shell), and settings.json must allow WebSearch and WebFetch"
fi
wired=""
proc="$src/framework/.godot-director"
grep -q 'research-domain\.md' "$proc/procedures/research.md" || wired="$wired research.md>research-domain.md"
grep -q 'researcher' "$proc/procedures/next-task.md" && grep -q 'Research items' "$proc/procedures/next-task.md" || wired="$wired next-task.md"
grep -q 'research\.md' "$proc/procedures/design.md" && grep -q 'design/research/' "$proc/procedures/design.md" || wired="$wired design.md"
grep -q 'R<n>' "$proc/tasks.md" && grep -q '^- \*\*Research\.\*\*' "$proc/tasks.md" || wired="$wired tasks.md"
grep -q 'research' "$proc/procedures/align.md" || wired="$wired align.md"
grep -q '/research' "$src/README.md" && grep -q '/research' "$src/ONBOARDING.md" || wired="$wired README.md/ONBOARDING.md"
grep -q '^\*\*Next IDs:\*\* T[0-9]* · B[0-9]* · R[0-9]*$' "$src/project/TASKS.md" || wired="$wired project/TASKS.md(Next IDs)"
grep -q '^\*\*Next IDs:\*\* T[0-9]* · B[0-9]* · R[0-9]*$' "$src/examples/market-day/TASKS.md" || wired="$wired market-day/TASKS.md(Next IDs)"
[ -z "$wired" ] && ok "the research assistant is wired into the procedures, the item format, the seeds and the docs" \
  || bad "the research assistant isn't wired into:$wired"
# Every subagent launch sets its model explicitly from the mapping, so none inherits the session's model:
# next-task.md says so for the builder, the reviewer, the researcher and an escalated retry, and
# rules.md states the rule the launches apply.
launch=""
nt="$proc/procedures/next-task.md"
grep -qF 'Every subagent launch sets its model explicitly' "$nt" || launch="$launch launch-rule"
grep -qF "A launch never lets a subagent inherit the session's model" "$nt" || launch="$launch no-inherit"
grep -qF 'Where the mapping has no entry for the size, or model sizing is off, the launch passes the session model explicitly' "$nt" \
  || launch="$launch session-fallback"
grep -qF 'the builder, the reviewer (step 6), the researcher (Research items) and an escalated retry' "$nt" || launch="$launch launches"
grep -qF 'Pass that model as `model: <id>`' "$nt" || launch="$launch builder-model"
grep -qF 'or in a subagent if your tool has them, with its model set as section 3 says' "$nt" || launch="$launch builder-other-tools"
grep -qF 'subagent, with its model set as section 3 says for the item' "$nt" || launch="$launch reviewer"
grep -qF 'in the foreground (`run_in_background: false`), with its model set as section 3 says' "$nt" || launch="$launch researcher"
grep -qF 'follow `research.md` in a fresh context, or a subagent if your tool has them, with its model set as section 3 says' "$nt" \
  || launch="$launch research-other-tools"
grep -qF 'on the next-size model, set on the launch as section 3 says' "$nt" || launch="$launch escalation"
grep -qF "rerun it once on the next size's model, set on the launch as section 3 says" "$nt" || launch="$launch research-escalation"
grep -qF 'Otherwise use the session model' "$nt" && launch="$launch old-fallback"
grep -qF 'turn on model sizing' "$nt" && launch="$launch old-conditional"
grep -qF "for the item's size, as for a build" "$nt" && launch="$launch old-research"
grep -qF 'Every subagent launch sets its model explicitly' "$proc/rules.md" \
  && grep -qF 'A size without an entry, or model sizing off, passes the session model, also explicitly' "$proc/rules.md" \
  || launch="$launch rules.md"
grep -qF 'A size without an entry uses the session model.' "$proc/rules.md" && launch="$launch rules-old"
[ -z "$launch" ] && ok "every subagent launch sets its model explicitly, and next-task.md and rules.md say so" \
  || bad "the subagent model wording is missing or has drifted:$launch"
# The human-written GDD: the template ships as a seed (and in the example), is the director's own
# structure, and onboarding and the README present it.
wired=""
for file in project/design/director-gdd.md examples/market-day/design/director-gdd.md; do
  grep -q '^# Game Design Document (GDD): ' "$src/$file" && grep -q '^\* \*\*Elevator Pitch:\*\*' "$src/$file" \
    && grep -q '^## 7\. Milestone Roadmap' "$src/$file" || wired="$wired $file"
done
cmp -s "$src/project/design/director-gdd.md" "$src/examples/market-day/design/director-gdd.md" || wired="$wired example copy differs from the seed"
grep -q 'design/director-gdd\.md' "$src/ONBOARDING.md" && grep -q '(from your document)' "$src/ONBOARDING.md" \
  && grep -q '(inferred, please confirm)' "$src/ONBOARDING.md" && grep -q 'alternative to the chat interview or an addition to it' "$src/ONBOARDING.md" \
  && grep -q 'sets the stage for later development' "$src/ONBOARDING.md" || wired="$wired ONBOARDING.md"
grep -q 'design/director-gdd\.md' "$src/README.md" || wired="$wired README.md"
[ -z "$wired" ] && ok "the human-written GDD template ships as a seed and in the example, and onboarding and the README present it" \
  || bad "the human-written GDD isn't wired into:$wired"
# The README's Start here step comes before Install and links the template at the release tag, and
# the template's header carries the same link: both follow VERSION, like the skill's clone line.
gdd_link="https://raw.githubusercontent.com/Freakling/Godot-Director/v$version/project/design/director-gdd.md"
start_line="$(grep -n '^### Start here' "$src/README.md" | head -n 1 | cut -d: -f1)"
install_line="$(grep -n '^### Install' "$src/README.md" | head -n 1 | cut -d: -f1)"
if grep -qF "($gdd_link)" "$src/README.md" && grep -qF "$gdd_link" "$src/project/design/director-gdd.md" \
  && [ -n "$start_line" ] && [ -n "$install_line" ] && [ "$start_line" -lt "$install_line" ]; then
  ok "the README's Start here step precedes Install and links the template at v<VERSION>, and the template's header carries that link"
else
  bad "the README's Start here step (before Install, linking $gdd_link) and the template header's link"
fi
# Export: the procedure and skill exist and are wired in, the skipped-step path writes a question
# and a gated setup item, and nothing here needs export templates or a Godot run.
missing=""
for file in framework/.godot-director/procedures/export.md framework/.claude/skills/export/SKILL.md; do
  [ -f "$src/$file" ] || missing="$missing $file"
done
[ -z "$missing" ] && ok "the export procedure and skill exist" || bad "export files missing:$missing"
wired=""
exportproc="$proc/procedures/export.md"
grep -q 'export\.md' "$proc/rules.md" || wired="$wired rules.md"
grep -q 'export\.md' "$src/framework/.claude/skills/export/SKILL.md" || wired="$wired skills/export"
grep -q '/export' "$src/README.md" || wired="$wired README.md"
grep -q 'export\.md' "$src/ONBOARDING.md" && grep -q 'Set up exports' "$src/ONBOARDING.md" || wired="$wired ONBOARDING.md"
grep -q -e '--export-release' -e 'godot_bin.local' "$exportproc" && grep -q 'export_presets\.cfg' "$exportproc" && grep -q 'export_templates' "$exportproc" || wired="$wired export.md(command, presets, templates)"
grep -q 'When the human skips it' "$exportproc" && grep -q 'Depends on: Q<n>' "$exportproc" && grep -q 'GDD › Open Questions' "$exportproc" || wired="$wired export.md(skip path)"
grep -q 'Q<n>' "$proc/tasks.md" && grep -q 'Open Questions' "$proc/procedures/next-task.md" || wired="$wired tasks.md/next-task.md(Q<n> in Depends on)"
grep -q '"/builds/"' "$src/install.sh" && grep -q '^/builds/$' "$src/examples/market-day/.gitignore" || wired="$wired /builds/ gitignore line"
[ -z "$wired" ] && ok "export is wired into the rules, the skill, the docs, the onboarding skip path and the gitignore" \
  || bad "export isn't wired into:$wired"
# Release: the procedure, skill, workflow template and script exist and are wired in, and
# tools/release.sh runs the configured commands, with no network, templates or real credentials.
missing=""
for file in framework/.godot-director/procedures/release.md framework/.claude/skills/release/SKILL.md \
    framework/.godot-director/templates/release-workflow.yml framework/tools/release.sh; do
  [ -f "$src/$file" ] || missing="$missing $file"
done
[ -z "$missing" ] && ok "the release procedure, skill, workflow template and script exist" || bad "release files missing:$missing"
wired=""
releaseproc="$proc/procedures/release.md"
grep -q 'release\.md' "$proc/rules.md" || wired="$wired rules.md"
grep -q 'release\.md' "$src/framework/.claude/skills/release/SKILL.md" || wired="$wired skills/release"
grep -q '/release' "$src/README.md" || wired="$wired README.md"
grep -q 'release\.md' "$src/ONBOARDING.md" && grep -q 'Set up release' "$src/ONBOARDING.md" || wired="$wired ONBOARDING.md"
grep -q 'release\.cfg' "$releaseproc" && grep -q 'tools/release\.sh' "$releaseproc" && grep -q 'when the human asks to promote' "$releaseproc" || wired="$wired release.md(config, script, production gate)"
grep -q 'When the human skips it' "$releaseproc" && grep -q 'Depends on: Q<n>' "$releaseproc" && grep -q 'GDD › Open Questions' "$releaseproc" || wired="$wired release.md(skip path)"
grep -q 'environment: production' "$proc/templates/release-workflow.yml" && grep -q 'tools/release\.sh uat' "$proc/templates/release-workflow.yml" || wired="$wired release-workflow.yml"
[ -z "$wired" ] && ok "release is wired into the rules, the skill, the docs, the onboarding skip path and the workflow template" \
  || bad "release isn't wired into:$wired"
unpinned="$(grep -E '^[[:space:]]*(- )?uses:' "$proc/templates/release-workflow.yml" | grep -Ev 'uses: [^@ ]+@[0-9a-f]{40} # v[0-9]+(\.[0-9]+)*$')"
[ -z "$unpinned" ] && ok "every action in the release workflow template is pinned to a full commit SHA, with its version in a comment" \
  || bad "release-workflow.yml has actions not pinned by commit" "$unpinned"
rel="$work/release"
mkdir -p "$rel/builds/Web" "$rel/builds/Empty"
printf 'x\n' > "$rel/builds/Web/index.html"
printf '[Web]\nuat = echo uploading-uat $RELEASE_TEST_TARGET\nproduction = echo uploading-production\nsecrets = RELEASE_TEST_SECRET\n[Empty]\nuat = echo never\n' > "$rel/release.cfg"
out="$(cd "$rel" && bash "$src/framework/tools/release.sh" uat Web 2>&1)"; expect_status "release.sh stops when a named secret is unset" 2 $? "$out"
expect_output "release.sh names the missing secret" "secret RELEASE_TEST_SECRET is not set" "$out"
expect_no_output "release.sh runs nothing before that" "uploading-uat" "$out"
out="$(cd "$rel" && bash "$src/framework/tools/release.sh" uat Web --dry-run 2>&1)"; expect_status "release.sh --dry-run needs no secrets" 0 $? "$out"
expect_output "release.sh --dry-run lists the command and uploads nothing" "dry run, nothing uploaded" "$out"
out="$(cd "$rel" && RELEASE_TEST_SECRET=hunter2 RELEASE_TEST_TARGET=here bash "$src/framework/tools/release.sh" uat Web 2>&1)"; expect_status "release.sh runs the uat command" 0 $? "$out"
expect_output "release.sh ran it with the environment" "^uploading-uat here$" "$out"
expect_no_output "release.sh never prints a secret value" "hunter2" "$out"
out="$(cd "$rel" && RELEASE_TEST_SECRET=x bash "$src/framework/tools/release.sh" production Web 2>&1)"; expect_output "release.sh runs the production command only when asked for it" "^uploading-production$" "$out"
out="$(cd "$rel" && RELEASE_TEST_SECRET=x bash "$src/framework/tools/release.sh" uat 2>&1)"; expect_status "release.sh refuses a preset with no build" 2 $? "$out"
out="$(cd "$work" && bash "$src/framework/tools/release.sh" uat 2>&1)"; expect_status "release.sh needs release.cfg" 2 $? "$out"
# UI design: the procedure, skill, capture tools and seeds exist and are wired in.
missing=""
for file in framework/.godot-director/procedures/ui-design.md framework/.claude/skills/ui-design/SKILL.md \
    framework/tools/ui_capture.sh framework/tools/ui_capture.gd framework/tools/ui_catalog.gd framework/tools/ui_lint.gd \
    framework/tools/ui_overlay.gd framework/tools/ui_drawing.gd project/tools/ui_screens.gd project/tools/ui_capture.cfg \
    project/design/ui/README.md examples/market-day/design/ui/README.md \
    tests/ui-drawing/fixture.excalidraw tests/ui-drawing/fixture-scaled.excalidraw tests/ui-drawing/fixture.elements.json \
    tests/ui-drawing/fixture.expected.json tests/ui-drawing/fixture.png tests/ui-drawing/starter.expected.excalidraw \
    examples/market-day/tools/ui_screens.gd examples/market-day/tools/ui_capture.cfg; do
  [ -f "$src/$file" ] || missing="$missing $file"
done
[ -z "$missing" ] && ok "the ui-design procedure, skill, capture tools and seeds exist" || bad "ui-design files missing:$missing"
wired=""
uiproc="$proc/procedures/ui-design.md"
grep -q 'ui-design\.md' "$proc/rules.md" || wired="$wired rules.md(procedure)"
grep -q 'tools/ui_screens\.gd' "$proc/rules.md" && grep -q 'godot_director_capture' "$proc/rules.md" || wired="$wired rules.md(UI)"
grep -q 'ui-design\.md' "$src/framework/.claude/skills/ui-design/SKILL.md" || wired="$wired skills/ui-design"
grep -q 'ui_capture\.sh --list' "$uiproc" && grep -q 'design/ui/captures/' "$uiproc" && grep -q 'Exit 3' "$uiproc" \
  && grep -q '\.elements\.json' "$uiproc" && grep -q '\.map\.png' "$uiproc" && grep -q '\.lint\.txt' "$uiproc" || wired="$wired ui-design.md(list, capture, outputs)"
for rule in squeezed-text stretched-control off-screen overlap unreachable no-default-focus hard-coded-position; do
  grep -q "\"$rule\"" "$src/framework/tools/ui_lint.gd" && grep -q "\`$rule\`" "$uiproc" || wired="$wired lint($rule)"
done
grep -q 'process <screen>' "$src/framework/.claude/skills/ui-design/SKILL.md" || wired="$wired skills/ui-design(process)"
grep -q '^- `process <screen>`' "$uiproc" && grep -q 'tools/ui_drawing\.gd' "$uiproc" && grep -q '\.drawing\.json' "$uiproc" \
  && grep -q '\.starter\.excalidraw' "$uiproc" && grep -q 'Never read the raw' "$uiproc" && grep -q '^### The screen spec' "$uiproc" || wired="$wired ui-design.md(process, reader, spec)"
grep -q '`design/ui/<screen>\.md`' "$proc/rules.md" && grep -q '`director/ui/`' "$proc/rules.md" || wired="$wired rules.md(one place)"
grep -q '^- \*\*`UI:`\*\*' "$proc/tasks.md" || wired="$wired tasks.md(UI)"
grep -q 'ui-design\.md' "$proc/procedures/design.md" || wired="$wired design.md"
grep -q 'director/\.gdignore' "$src/ONBOARDING.md" || wired="$wired ONBOARDING.md(director/.gdignore)"
grep -q 'Excalidraw' "$src/project/design/ui/README.md" && cmp -s "$src/project/design/ui/README.md" "$src/examples/market-day/design/ui/README.md" || wired="$wired design/ui/README.md seed"
grep -q '"Bash(bash tools/ui_capture.sh \*)"' "$settings" || wired="$wired settings.json"
grep -q '"/design/ui/captures/"' "$src/install.sh" && grep -q '^/design/ui/captures/$' "$src/examples/market-day/.gitignore" || wired="$wired captures gitignore line"
grep -q '"/tools/ui_\*\.gd text eol=lf"' "$src/install.sh" || wired="$wired .gitattributes line"
grep -q '^extends "res://tools/ui_catalog\.gd"$' "$src/project/tools/ui_screens.gd" || wired="$wired ui_screens.gd seed"
[ -z "$wired" ] && ok "ui-design is wired into the rules, the skill, the settings, the lint and the installer's lines" \
  || bad "ui-design isn't wired into:$wired"
# UI design, part 3: verify, the workflow hooks, the lint in the check and overlays.
wired=""
[ -f "$src/framework/tools/ui_verify.gd" ] || wired="$wired tools/ui_verify.gd"
grep -q '^- `verify <screen>`' "$uiproc" && grep -q '^## verify' "$uiproc" && grep -q 'ui_capture\.sh <id> --verify' "$uiproc" \
  && grep -q 'tools/ui_overlay\.gd -- compare' "$uiproc" && grep -q 'compare@<W>x<H>\.png' "$uiproc" || wired="$wired ui-design.md(verify)"
grep -q "^## If you can't view images" "$uiproc" && grep -q 'ui_capture\.sh --missing' "$uiproc" || wired="$wired ui-design.md(text paths, --missing)"
grep -q '^## The lint in the check' "$uiproc" && grep -q 'check_in_check' "$uiproc" && grep -q 'enforce' "$uiproc" || wired="$wired ui-design.md(lint in the check)"
grep -q '"overlays": \["/root/Hud"\]' "$uiproc" && ! grep -q "isn't in it" "$uiproc" || wired="$wired ui-design.md(overlays)"
grep -q '"overlays"' "$src/framework/tools/ui_catalog.gd" && grep -q '_show_overlays' "$src/framework/tools/ui_capture.gd" || wired="$wired overlays in capture"
grep -q '^5\. \*\*Screens\*\*' "$proc/procedures/build.md" && grep -q '^   Screen: ' "$proc/procedures/build.md" && grep -q -- '--verify' "$proc/procedures/build.md" || wired="$wired build.md"
grep -q '^3\. \*\*Screens\*\*' "$proc/procedures/review.md" && grep -q 'compare@' "$proc/procedures/review.md" || wired="$wired review.md"
grep -q 'compare@' "$proc/procedures/function-check.md" && grep -q -- '--verify' "$proc/procedures/function-check.md" || wired="$wired function-check.md"
grep -q 'ui_capture\.sh --missing' "$proc/procedures/align.md" && grep -q 'sha1' "$proc/procedures/align.md" && grep -q '`UI:`' "$proc/procedures/align.md" || wired="$wired align.md"
grep -q 'tools/check.cfg tools/ui_capture.cfg' "$src/framework/tools/check.sh" && grep -q 'check_in_check' "$src/framework/tools/check.sh" || wired="$wired check.sh(fingerprint, lint)"
grep -q '^check_in_check=true$' "$src/project/tools/ui_capture.cfg" && grep -q '^enforce=\["\*"\]$' "$src/project/tools/ui_capture.cfg" \
  && grep -q '^tolerance_pct=4.0$' "$src/project/tools/ui_capture.cfg" && cmp -s "$src/project/tools/ui_capture.cfg" "$src/examples/market-day/tools/ui_capture.cfg" || wired="$wired ui_capture.cfg seed"
grep -q 'check_in_check=false' "$src/install.sh" || wired="$wired install.sh(upgrade writes the lint off)"
grep -q 'director designs (director/ui/), agent builds' "$src/project/AGENTS.md" && grep -q '`design/ui/`' "$src/project/AGENTS.md" || wired="$wired AGENTS.md template"
grep -q '`design/ui/`' "$src/examples/market-day/AGENTS.md" && grep -q '^/tools/ui_verify\.gd$' "$src/examples/market-day/.gitignore" || wired="$wired example AGENTS.md, .gitignore"
grep -q 'director designs (director/ui/), agent builds' "$src/ONBOARDING.md" && grep -q 'ui_capture\.sh --missing' "$src/ONBOARDING.md" \
  && grep -q 'check_in_check=false' "$src/ONBOARDING.md" || wired="$wired ONBOARDING.md"
grep -q '(`/ui-design`)' "$src/README.md" && grep -q 'tools/ui_screens\.gd' "$src/README.md" && grep -q 'director/ui/' "$src/README.md" || wired="$wired README.md"
grep -q 'verify <screen>' "$src/framework/.claude/skills/ui-design/SKILL.md" || wired="$wired skills/ui-design(verify)"
[ -z "$wired" ] && ok "ui-design verify, the build, review, function check and align hooks, the lint in the check and overlays are wired in" \
  || bad "ui-design verify and the hooks aren't wired into:$wired"
# The play log: the framework's base, the game's seed (hooks marked PLACEHOLDER), the example's wiring,
# the five rules, onboarding's autoload line and the installer's lines.
wired=""
for file in framework/tools/play_log_base.gd project/tools/play_log.gd examples/market-day/tools/play_log.gd \
    examples/market-day/tests/test_play_log.gd tests/play-log/selftest_play_log.gd; do
  [ -f "$src/$file" ] || wired="$wired $file"
done
grep -q '^extends "res://tools/play_log_base\.gd"$' "$src/project/tools/play_log.gd" \
  && [ "$(grep -c '## PLACEHOLDER' "$src/project/tools/play_log.gd")" -ge 3 ] || wired="$wired play_log.gd seed"
for hook in '_session_extras() -> Dictionary' '_build_snapshot() -> Dictionary' 'progress_block_reason() -> String' \
    'log_snapshot() -> void' 'start_capture() -> void' 'begin_run() -> String' 'continue_run(id: String) -> void'; do
  grep -qF "func $hook" "$src/framework/tools/play_log_base.gd" || wired="$wired base($hook)"
done
grep -q 'OS\.add_logger' "$src/framework/tools/play_log_base.gd" && grep -q 'extends Logger' "$src/framework/tools/play_log_base.gd" || wired="$wired base(Logger)"
grep -q '^PlayLog="\*res://tools/play_log\.gd"$' "$src/examples/market-day/project.godot" \
  && grep -q '^settings/gdscript/always_track_call_stacks=true$' "$src/examples/market-day/project.godot" || wired="$wired example project.godot"
grep -q '^   settings/gdscript/always_track_call_stacks=true$' "$src/ONBOARDING.md" || wired="$wired ONBOARDING.md(call stacks)"
grep -q '^func _install_id() -> String:$' "$src/project/tools/play_log.gd" || wired="$wired play_log.gd seed(_install_id)"
grep -q 'PlayLog="\*res://tools/play_log\.gd"' "$src/ONBOARDING.md" && grep -q 'Migrate PlayLog to extend tools/play_log_base\.gd' "$src/ONBOARDING.md" || wired="$wired ONBOARDING.md"
grep -q '"/tools/play_log_base\.gd text eol=lf"' "$src/install.sh" && grep -q '^/tools/play_log_base\.gd$' "$src/examples/market-day/.gitignore" \
  && grep -q '^/tools/play_log_base\.gd text eol=lf$' "$src/examples/market-day/.gitattributes" || wired="$wired installer lines"
for rule in 'Everything is logged' 'Every action is drivable' 'Agent-visible state' 'Seeded randomness' 'Privacy'; do
  grep -q "^- \*\*$rule\.\*\*" "$proc/rules.md" || wired="$wired rules.md($rule)"
done
grep -q "use the editor's Remote scene tree instead" "$proc/rules.md" && wired="$wired rules.md(the Remote tree sentence is still there)"
grep -q 'start_capture()' "$proc/rules.md" && grep -q 'dev menu' "$proc/rules.md" || wired="$wired rules.md(start_capture, dev menu)"
grep -q 'tools/play_log_base\.gd' "$src/README.md" && grep -q 'tools/play_log\.gd' "$src/README.md" || wired="$wired README.md"
[ -z "$wired" ] && ok "the play log is wired in: base, seed, example, the five rules, onboarding and the installer's lines" \
  || bad "the play log isn't wired into:$wired"
# Autoplay: the driver, the adapter and scenario bases, the game's seeds (stubs marked PLACEHOLDER,
# a smoke scenario), the example's wiring, the capture's shared element map writer and the
# installer's lines.
wired=""
for file in framework/tools/autoplay.sh framework/tools/autoplay.gd framework/tools/autoplay_adapter_base.gd \
    framework/tools/autoplay_catalog.gd project/tools/autoplay_adapter.gd project/tools/autoplay_scenarios.gd \
    project/tools/autoplay_invariants.gd examples/market-day/tools/autoplay_adapter.gd \
    examples/market-day/tools/autoplay_scenarios.gd examples/market-day/tools/autoplay_invariants.gd; do
  [ -f "$src/$file" ] || wired="$wired $file"
done
grep -q '^extends "res://tools/autoplay_adapter_base\.gd"$' "$src/project/tools/autoplay_adapter.gd" \
  && [ "$(grep -c '^## PLACEHOLDER' "$src/project/tools/autoplay_adapter.gd")" -ge 7 ] || wired="$wired autoplay_adapter.gd seed"
grep -q '^extends "res://tools/autoplay_catalog\.gd"$' "$src/project/tools/autoplay_scenarios.gd" \
  && grep -q '"id": "smoke", .*"kind": "smoke"' "$src/project/tools/autoplay_scenarios.gd" || wired="$wired autoplay_scenarios.gd seed(smoke)"
grep -q '^func check(_state: Dictionary, _adapter: Object) -> PackedStringArray:$' "$src/project/tools/autoplay_invariants.gd" \
  && grep -q 'PLACEHOLDER' "$src/project/tools/autoplay_invariants.gd" || wired="$wired autoplay_invariants.gd seed"
for hook in 'start_run(_run_seed: int) -> void' 'load_save(_path: String) -> bool' 'list_actions() -> Array\[Dictionary\]' \
    'perform(_action: Dictionary) -> bool' 'state() -> Dictionary' 'progress_block_reason() -> String' 'is_run_over() -> bool'; do
  grep -q "^func $hook:$" "$src/framework/tools/autoplay_adapter_base.gd" || wired="$wired adapter base($hook)"
done
grep -q 'a smoke scenario is required' "$src/framework/tools/autoplay_catalog.gd" || wired="$wired autoplay_catalog.gd(smoke required)"
grep -q 'Engine.set_meta(AUTOPLAY_META, true)' "$src/framework/tools/autoplay.gd" && grep -q 'Input.parse_input_event' "$src/framework/tools/autoplay.gd" \
  && grep -q 'lint.element_map(' "$src/framework/tools/autoplay.gd" && grep -q 'lint.element_map(' "$src/framework/tools/ui_capture.gd" \
  && ! grep -q '^func _element_map' "$src/framework/tools/ui_capture.gd" || wired="$wired autoplay.gd(meta, real input, the capture's element map writer)"
grep -q '"/playtesting/autoplay/"' "$src/install.sh" && grep -q '^/playtesting/autoplay/$' "$src/examples/market-day/.gitignore" \
  && grep -q '"/tools/autoplay\.gd text eol=lf"' "$src/install.sh" && grep -q '^/tools/autoplay_adapter_base\.gd text eol=lf$' "$src/examples/market-day/.gitattributes" \
  && grep -q '^/tools/autoplay_catalog\.gd$' "$src/examples/market-day/.gitignore" || wired="$wired installer lines"
[ -z "$wired" ] && ok "autoplay is wired in: driver, bases, seeds with a smoke scenario, the example, the shared element map and the installer's lines" \
  || bad "autoplay isn't wired into:$wired"
# Log review: the tool and its wrapper, the signatures.tsv seed (a header only, the same in the
# example), the normalisation fixture and the installer's lines.
wired=""
for file in framework/tools/log_review.sh framework/tools/log_review.gd project/playtesting/signatures.tsv \
    examples/market-day/playtesting/signatures.tsv tests/log-review/signature-cases.tsv; do
  [ -f "$src/$file" ] || wired="$wired $file"
done
[ "$(cat "$src/project/playtesting/signatures.tsv")" = "$(printf 'id\tkind\ttext\tfirst_seen_build')" ] \
  && cmp -s "$src/project/playtesting/signatures.tsv" "$src/examples/market-day/playtesting/signatures.tsv" || wired="$wired signatures.tsv seed(header, example copy)"
grep -q 'GODOT_BIN' "$src/framework/tools/log_review.sh" && grep -q '\[ "\$minor" -lt 5 \]' "$src/framework/tools/log_review.sh" \
  && grep -q 'tools/log_review.gd' "$src/framework/tools/log_review.sh" || wired="$wired log_review.sh(Godot lookup, 4.5 minimum)"
grep -q '"/tools/log_review\.gd text eol=lf"' "$src/install.sh" && grep -q '"/playtesting/signatures\.tsv text eol=lf"' "$src/install.sh" \
  && grep -q '^/tools/log_review\.gd text eol=lf$' "$src/examples/market-day/.gitattributes" \
  && grep -q '^/playtesting/signatures\.tsv text eol=lf$' "$src/examples/market-day/.gitattributes" \
  && grep -q '^/tools/log_review\.sh$' "$src/examples/market-day/.gitignore" && grep -q '^/tools/log_review\.gd$' "$src/examples/market-day/.gitignore" || wired="$wired installer lines"
[ -z "$wired" ] && ok "log review is wired in: tool, wrapper, the signatures.tsv seed with its header, the fixture and the installer's lines" \
  || bad "log review isn't wired into:$wired"
# The dev menu: the base, the game's seed (PLACEHOLDER marked), the example's wiring, the rules,
# onboarding's question and recorded answer, the upgrade step and the installer's lines.
wired=""
for file in framework/tools/dev_menu_base.gd project/tools/dev_menu.gd examples/market-day/tools/dev_menu.gd \
    examples/market-day/tests/test_dev_menu.gd tests/dev-menu/selftest_dev_menu.gd; do
  [ -f "$src/$file" ] || wired="$wired $file"
done
grep -q '^extends "res://tools/dev_menu_base\.gd"$' "$src/project/tools/dev_menu.gd" \
  && [ "$(grep -c 'PLACEHOLDER' "$src/project/tools/dev_menu.gd")" -ge 3 ] \
  && grep -q '^func setting_enabled() -> bool:$' "$src/project/tools/dev_menu.gd" || wired="$wired dev_menu.gd seed"
for hook in 'register_system(system_name: String, node: Object' 'is_available() -> bool' 'actions_of(system_name: String)' \
    'inspect(system_name: String) -> Dictionary' 'inspect_text(system_name: String) -> String' 'log_text() -> String' \
    'run_action(system_name: String, method: String'; do
  grep -qF "func $hook" "$src/framework/tools/dev_menu_base.gd" || wired="$wired base($hook)"
done
grep -q '"debug/dev_menu"' "$src/framework/tools/dev_menu_base.gd" && grep -q '"--dev-menu"' "$src/framework/tools/dev_menu_base.gd" \
  && grep -q 'KEY_F12' "$src/framework/tools/dev_menu_base.gd" || wired="$wired base(setting, flag, F12)"
grep -q '^DevMenu="\*res://tools/dev_menu\.gd"$' "$src/examples/market-day/project.godot" \
  && grep -q '^- Dev menu: in game (F12, debug builds only)$' "$src/examples/market-day/AGENTS.md" || wired="$wired example project.godot, AGENTS.md"
grep -q 'register_system(name, node)' "$proc/rules.md" && grep -q 'tools/dev_menu_base\.gd' "$proc/rules.md" && grep -q 'debug_inspect()' "$proc/rules.md" || wired="$wired rules.md(dev menu base, registration)"
grep -q '^- Dev menu: \*\*ask the human' "$src/ONBOARDING.md" && grep -q '^  Dev menu: in game (F12, debug builds only)$' "$src/ONBOARDING.md" \
  && grep -q '`debug/dev_menu=true`' "$src/ONBOARDING.md" && grep -q -- '`-- --dev-menu`' "$src/ONBOARDING.md" \
  && grep -q 'AGENTS.md › Project rules' "$src/ONBOARDING.md" || wired="$wired ONBOARDING.md(dev menu step)"
grep -q '^7\. \*\*The dev menu\.\*\*' "$src/CHANGELOG.md" || wired="$wired CHANGELOG.md(upgrade step)"
grep -q '^- Dev menu: ' "$src/project/AGENTS.md" && grep -q 'tools/dev_menu_base\.gd' "$src/README.md" || wired="$wired project/AGENTS.md, README.md"
grep -q '"/tools/dev_menu_base\.gd text eol=lf"' "$src/install.sh" && grep -q '^/tools/dev_menu_base\.gd$' "$src/examples/market-day/.gitignore" \
  && grep -q '^/tools/dev_menu_base\.gd text eol=lf$' "$src/examples/market-day/.gitattributes" || wired="$wired installer lines"
[ -z "$wired" ] && ok "the dev menu is wired in: base, seed, example, the rule, onboarding's question and answer format, the upgrade step and the installer's lines" \
  || bad "the dev menu isn't wired into:$wired"
# /autoplay and the workflow around it: the procedure and the skill that point at each other, the
# request list's "check the logs", the (autoplay) tag, every procedure that uses autoplay, the
# settings' allowed commands, the check's [autoplay] section and the seeds, README and onboarding.
wired=""
autoproc="$proc/procedures/autoplay.md"
autoskill="$src/framework/.claude/skills/autoplay/SKILL.md"
[ -f "$autoproc" ] && [ -f "$autoskill" ] || wired="$wired autoplay.md/skill(missing)"
grep -q '^name: autoplay$' "$autoskill" && grep -q 'procedures/autoplay\.md' "$autoskill" && grep -q -- '--player' "$autoskill" \
  && grep -q -- '--replay' "$autoskill" && grep -q 'check the logs' "$autoskill" || wired="$wired skills/autoplay"
grep -q '/autoplay' "$autoproc" && grep -q 'tools/autoplay\.sh' "$autoproc" && grep -q 'tools/log_review\.sh' "$autoproc" \
  && grep -q -- '--replay <run folder>' "$autoproc" && grep -q -- '--player' "$autoproc" || wired="$wired autoplay.md(commands)"
grep -q '^## Who owns what' "$autoproc" && grep -q 'Framework-owned' "$autoproc" && grep -q 'Project-owned' "$autoproc" \
  && grep -q "can't view images" "$autoproc" && grep -q '\.elements\.json' "$autoproc" && grep -q 'review\.md' "$autoproc" \
  && grep -q '^## Report' "$autoproc" && grep -q 'File and confirm' "$autoproc" && grep -q 'Never edit `director/`' "$autoproc" || wired="$wired autoplay.md(owners, element maps, report, bugs)"
grep -q '^- \*\*autoplay\.md:\*\*' "$proc/rules.md" && grep -q '"Check the logs"' "$proc/rules.md" && grep -q '/autoplay --player' "$proc/rules.md" || wired="$wired rules.md(request list)"
for file in rules.md tasks.md procedures/next-task.md procedures/build.md procedures/review.md; do
  grep -q '(autoplay)' "$proc/$file" || wired="$wired $file((autoplay))"
done
for file in next-task build review function-check playtest align; do
  grep -qi 'autoplay' "$proc/procedures/$file.md" || wired="$wired $file.md(autoplay)"
done
grep -q 'build\.md` step 6' "$proc/procedures/next-task.md" && grep -q '^6\. \*\*Autoplay\*\*' "$proc/procedures/build.md" && grep -q '^   Autoplay: ' "$proc/procedures/build.md" \
  && grep -q 'plus `smoke`\|and `smoke`' "$proc/procedures/build.md" && grep -q "delta line" "$proc/procedures/build.md" || wired="$wired build.md(autoplay step, report line)"
grep -q 'Logging and drivability' "$proc/procedures/review.md" && grep -q 'list_actions()' "$proc/procedures/review.md" && grep -q 'opened by `smoke`' "$proc/procedures/review.md" || wired="$wired review.md(logging, drivability)"
grep -q 'Pre-verified by autoplay' "$proc/procedures/function-check.md" && grep -q 'run folder' "$proc/procedures/function-check.md" || wired="$wired function-check.md(pre-verified)"
grep -q 'Machine review' "$proc/procedures/playtest.md" && grep -q 'tools/autoplay\.sh smoke' "$proc/procedures/playtest.md" || wired="$wired playtest.md(machine review)"
grep -q 'Scenario gaps' "$proc/procedures/align.md" && grep -q 'Logging gaps' "$proc/procedures/align.md" && grep -q 'never fails\|none of it fails' "$proc/procedures/align.md" || wired="$wired align.md(gaps)"
for command in 'tools/autoplay.sh \*' 'tools/autoplay.sh' 'tools/log_review.sh \*' 'tools/log_review.sh'; do
  grep -q "\"Bash(bash $command)\"" "$settings" || wired="$wired settings.json($command)"
done
grep -q '^\[autoplay\]$' "$src/project/tools/check.cfg" && grep -q '^check_in_check=true$' "$src/project/tools/check.cfg" && grep -q '^enforce=\["smoke"\]$' "$src/project/tools/check.cfg" \
  && grep -q '^\[autoplay\]$' "$src/examples/market-day/tools/check.cfg" || wired="$wired check.cfg seeds"
grep -q "sed .s/^/GDIR-FAIL: /." "$src/framework/tools/check.sh" && grep -q "GDIR_LOCK_HELD=1" "$src/framework/tools/check.sh" \
  && grep -q "GDIR_LOCK_HELD" "$src/framework/tools/autoplay.sh" && grep -q "tools/check.cfg > \[autoplay\]" "$src/framework/tools/check.sh" || wired="$wired check.sh([autoplay])"
grep -q 'old_version' "$src/install.sh" && grep -q "tools/check.cfg" "$src/install.sh" && grep -q 'autoplay in the check off' "$src/install.sh" || wired="$wired install.sh(check.cfg off on an upgrade)"
grep -q '^### Auto-playtesting' "$src/README.md" && grep -q '(`/autoplay`)' "$src/README.md" && grep -q 'framework-owned\|Godot Director owns' "$src/README.md" \
  && grep -q "can't view images" "$src/README.md" && grep -q 'check_in_check' "$src/README.md" || wired="$wired README.md(auto-playtesting)"
grep -q '^8\. \*\*The workflow\.\*\*' "$src/CHANGELOG.md" && grep -q '^- \*\*New: `/autoplay`' "$src/CHANGELOG.md" && grep -q 'Wire autoplay' "$src/CHANGELOG.md" || wired="$wired CHANGELOG.md"
grep -q 'autoplay_adapter\.gd' "$src/ONBOARDING.md" && grep -q '^8\. \*\*Autoplay\.\*\*' "$src/ONBOARDING.md" || wired="$wired ONBOARDING.md(autoplay)"
[ -z "$wired" ] && ok "/autoplay is wired in: procedure and skill, the request list, the (autoplay) tag, the workflow procedures, the settings, the check's [autoplay] section and the docs" \
  || bad "/autoplay isn't wired into:$wired"
# The minimum Godot is 4.5 (the engine Logger) everywhere it's stated and checked. A Godot Director
# version such as v4.3.0 (a tag or a `version:` line) isn't a Godot version.
stale="$(cd "$src" && grep -nE '4\.3([^0-9.]|$)|-lt [0-4] \]; \}|-ge [0-4] \]; \}' README.md ONBOARDING.md CLAUDE.md \
  skills/godot-director/SKILL.md selftest.sh framework/tools/check.sh framework/tools/setup-clone.sh framework/tools/ui_capture.sh framework/tools/autoplay.sh \
  framework/tools/log_review.sh framework/.godot-director/procedures/ui-design.md examples/market-day/AGENTS.md)"
if [ -z "$stale" ] && grep -q 'Godot 4\.5 or newer' "$src/README.md" && grep -q "compatibility: 'Godot 4\.5 or newer" "$installer" \
    && grep -q 'Godot 4\.5+' "$src/ONBOARDING.md" && grep -q '"4\.5"' "$src/examples/market-day/project.godot" \
    && grep -q '\[ "\$minor" -lt 5 \]' "$src/framework/tools/check.sh" && grep -q '\[ "\$minor" -lt 5 \]' "$src/framework/tools/ui_capture.sh" \
    && grep -q '\[ "\$minor" -lt 5 \]' "$src/framework/tools/autoplay.sh" \
    && grep -q '\[ "\$minor" -ge 5 \]' "$src/framework/tools/setup-clone.sh"; then
  ok "the minimum Godot is 4.5 everywhere it's stated and checked"
else
  bad "the minimum Godot is 4.5 everywhere it's stated and checked" "$stale"
fi
# The old name (Claude4Godot, 2.x and earlier) is left only in history and in the 2.x migration.
allowed=" CHANGELOG.md install.sh selftest.sh ONBOARDING.md framework/tools/check.gd framework/tools/check.sh framework/tools/setup-clone.sh "
leftovers=""
for file in $(cd "$src" && grep -rIli --exclude-dir=.git --exclude-dir=.godot -e claude4godot -e c4g . | sed 's|^\./||'); do
  case "$allowed" in *" $file "*) ;; *) leftovers="$leftovers $file" ;; esac
done
[ -z "$leftovers" ] && ok "the old name is left only in the changelog and the 2.x migration" \
  || bad "the old name (claude4godot, c4g) is still in:$leftovers"
out="$(cd "$src" && git grep -P '[\x{2013}\x{2014}]' -- '*.md' '*.sh' '*.gd' '*.cfg' '*.json' '*.txt' 2>/dev/null)"
[ -z "$out" ] && ok "no en or em dashes in tracked text files" \
  || bad "en or em dashes found" "$out"
mismatch=""
for size in XS S M L XL; do
  sid="$(grep "| \`$size\` |" "$src/framework/.godot-director/procedures/refresh-model-sizing.md" \
    | head -n1 | awk -F'|' '{gsub(/[` ]/, "", $3); print $3}')"
  oid="$(grep "^  - $size:" "$src/ONBOARDING.md" | awk '{print $NF}')"
  [ "$sid" = "$oid" ] || mismatch="$mismatch $size"
done
[ -z "$mismatch" ] && ok "ONBOARDING.md model IDs match refresh-model-sizing.md" \
  || bad "ONBOARDING.md model IDs don't match refresh-model-sizing.md (sizes:$mismatch)"
# User stories, which onboarding turns on or off: the template (framework-owned, so a game with them
# off never gets the file) and the example's own file have the header line, the sections and rows in
# the story format; the item format carries Stories:; the check.cfg seed has the cadence; the rules,
# the procedures, the settings and the docs name them, each step only with them on; and Market Day
# uses them, with a Stories: line on every agent item. tools/stories.sh --due is tested under
# "user stories", with them on, off and unanswered.
ex_tasks="$src/examples/market-day/TASKS.md"
wired=""
[ -f "$stories_tpl" ] && [ -f "$src/framework/tools/stories.sh" ] && [ -f "$stories_ex" ] || wired="$wired files"
[ -e "$src/project/design/user-stories.md" ] && wired="$wired project/design/user-stories.md(a seed would reach a game with them off)"
grep -q '^<!-- Godot Director user stories template · framework-owned' "$stories_tpl" \
  && [ "$(sed -n 2p "$stories_tpl")" = '# User stories: {{PROJECT_NAME}}' ] || wired="$wired template(header, title)"
check_stories() { # check_stories <file> <label>: the header line, the sections, the rows, the IDs and the roles
  local file="$1" label="$2" rows next ids role
  grep -qE '^\*\*Next ID:\*\* US-[0-9]+ · \*\*Last validated:\*\* (never|[0-9]{4}-[0-9]{2}-[0-9]{2}( at `[0-9a-f]{7,40}`)?)$' "$file" \
    || wired="$wired $label(Next ID and Last validated)"
  grep -q '^## The value in one paragraph per role$' "$file" && grep -q '^## Roles$' "$file" || wired="$wired $label(sections)"
  rows="$(grep -E '^\| US-' "$file")"
  [ -n "$rows" ] && grep -q '^| ID | Story | Confirmed |$' "$file" || wired="$wired $label(tables)"
  printf '%s\n' "$rows" | grep -vqE '^\| US-[0-9]+ \| As an? [^|]+ I [^|]+, so [^|]+\. \| ([0-9]{4}-[0-9]{2}-[0-9]{2}|unconfirmed) \|$' \
    && wired="$wired $label(a row isn't | US-<n> | As a <role> I ..., so ... | <date> or unconfirmed |)"
  next="$(sed -n 's/^\*\*Next ID:\*\* US-\([0-9]*\) .*/\1/p' "$file")"
  ids="$(printf '%s\n' "$rows" | sed -n 's/^| US-\([0-9]*\) .*/\1/p')"
  [ -n "$next" ] && [ -z "$(printf '%s\n' "$ids" | awk -v next_id="$next" '$1 + 0 >= next_id + 0 || seen[$1]++')" ] \
    || wired="$wired $label(IDs unique and below Next ID)"
  for role in $(printf '%s\n' "$rows" | sed -n 's/^| US-[0-9]* | As an\{0,1\} \([A-Za-z]*\) I .*/\1/p' | tr 'A-Z' 'a-z' | awk '!seen[$0]++'); do
    sed -n '/^## Roles$/,/^## [^R]/p' "$file" | tr 'A-Z' 'a-z' | grep -q "^- \*\*$role:\*\*" || wired="$wired $label(role $role not in Roles)"
  done
}
check_stories "$stories_tpl" template
check_stories "$stories_ex" example
grep -q '^- User stories: on$' "$src/examples/market-day/AGENTS.md" || wired="$wired example AGENTS.md(rule)"
gdd_line='Why each feature is built, and for whom: `design/user-stories.md`.'
grep -qxF "$gdd_line" "$src/examples/market-day/design/gdd.md" && grep -qF "$gdd_line" "$proc/procedures/design.md" || wired="$wired GDD link(example, design.md)"
no_field="$(awk '/^### / { if (item != "" && !has) printf " %s", item; item = ($0 ~ / · agent( |$)/ && $2 !~ /^R/) ? $2 : ""; has = 0; next }
  /^- Stories: / { has = 1 } END { if (item != "" && !has) printf " %s", item }' "$ex_tasks")"
[ -z "$no_field" ] || wired="$wired example TASKS.md(no Stories: on$no_field)"
for id in $(sed -n 's/^- Stories: //p' "$ex_tasks" | tr ',' '\n' | tr -d ' ' | grep '^US-'); do
  grep -q "^| $id |" "$stories_ex" || wired="$wired example TASKS.md($id isn't a story)"
done
for id in $(grep -E '^\| US-' "$stories_ex" | sed -n 's/^| \(US-[0-9]*\) .*/\1/p'); do
  grep -qE "^- Stories: (.*[ ,])?$id(,|$)" "$ex_tasks" || wired="$wired example($id served by no item)"
done
grep -q '^/tools/stories\.sh$' "$src/examples/market-day/.gitignore" || wired="$wired example .gitignore"
grep -q '^- Stories: US-[0-9]' "$proc/tasks.md" && grep -q '^- \*\*`Stories:`\.\*\* Only in a game that uses user stories' "$proc/tasks.md" || wired="$wired tasks.md"
grep -q '^- User stories: on$' "$src/project/AGENTS.md" || wired="$wired project/AGENTS.md(example rule)"
sed -n '/^\[stories\]$/,/^\[/p' "$src/project/tools/check.cfg" | grep -q '^every=10$' || wired="$wired project/tools/check.cfg"
grep -q '^| Whom the game is for, and why each feature is built (a game that uses user stories) | `design/user-stories\.md`' "$proc/rules.md" \
  && grep -q '^- \*\*Why it.s built\.\*\* User stories are the game.s choice' "$proc/rules.md" \
  && grep -q '`design/user-stories\.md` when a story was drafted for it' "$proc/rules.md" || wired="$wired rules.md"
for heading in '## User stories' '### Turning them on' '### Validate the stories' '### Still right? in a playtest or function check'; do
  grep -qxF "$heading" "$proc/procedures/design.md" || wired="$wired design.md($heading)"
done
grep -qF 'skip every step about stories in the procedures, and this section except Turning them on, which runs when the human asks for it' "$proc/procedures/design.md" \
  && grep -q 'bash tools/stories\.sh --due' "$proc/procedures/design.md" && grep -q 'its `Stories:`' "$proc/procedures/design.md" \
  && grep -qF '.godot-director/templates/user-stories.md' "$proc/procedures/design.md" \
  && grep -qF -- '- [ ] Still right   - [ ] Needs a change' "$proc/procedures/design.md" || wired="$wired design.md"
grep -q 'bash tools/stories\.sh --due' "$proc/procedures/next-task.md" && grep -q '\[stories\] every' "$proc/procedures/next-task.md" \
  && grep -q 'not due: user stories are off' "$proc/procedures/next-task.md" \
  && grep -q 'With user stories on, a feature item (not a research item) with no story gets one before it is built' "$proc/procedures/next-task.md" \
  && grep -q 'with `design/user-stories\.md` when the claim drafted a story' "$proc/procedures/next-task.md" || wired="$wired next-task.md"
grep -qF -- '- [ ] Still right   - [ ] Needs a change' "$proc/procedures/function-check.md" && grep -q '^4\. \*\*Stories\*\* (with user stories on)' "$proc/procedures/function-check.md" \
  || wired="$wired function-check.md"
grep -q '`## User stories` section' "$proc/procedures/playtest.md" && grep -q '^6\. \*\*Stories\*\* (with user stories on)' "$proc/procedures/playtest.md" || wired="$wired playtest.md"
grep -q 'stories no item serves' "$proc/procedures/align.md" && grep -q 'feature items with no story' "$proc/procedures/align.md" \
  && grep -q 'stories unconfirmed past the cadence' "$proc/procedures/align.md" && grep -q 'bugs with no story' "$proc/procedures/align.md" \
  && grep -q 'skip it unless AGENTS.md › Project rules says `User stories: on`' "$proc/procedures/align.md" || wired="$wired align.md"
for file in design align; do
  grep -q 'were written from the code on <date>, before the game kept user stories\.' "$proc/procedures/$file.md" || wired="$wired $file.md(written from the code)"
done
grep -q 'design/user-stories\.md' "$proc/procedures/build.md" || wired="$wired build.md"
for file in design next-task function-check playtest ui-design drift-reset; do
  grep -q 'with user stories on\|With user stories on' "$proc/procedures/$file.md" || wired="$wired $file.md(only with them on)"
done
grep -qF '"Bash(bash tools/stories.sh --due)",' "$settings" && ! grep -qF '"Bash(bash tools/stories.sh*)"' "$settings" \
  && ! grep -qF '"Bash(bash tools/stories.sh *)"' "$settings" || wired="$wired settings.json"
grep -q '^### User stories (fresh start, existing game and migrate)$' "$src/ONBOARDING.md" \
  && grep -qF '`- User stories: on` or `- User stories: off`' "$src/ONBOARDING.md" \
  && grep -qF '`.godot-director/procedures/design.md` › User stories › Turning them on' "$src/ONBOARDING.md" \
  && grep -q '^   5\. whether the game uses user stories' "$src/ONBOARDING.md" && grep -q '`\[stories\] every`' "$src/ONBOARDING.md" \
  || wired="$wired ONBOARDING.md"
grep -q 'design/user-stories\.md' "$src/README.md" && grep -q 'tools/stories\.sh' "$src/README.md" \
  && grep -q 'In a game that uses user stories' "$src/framework/playtesting/README.md" && grep -q 'Still right' "$src/framework/playtesting/README.md" \
  || wired="$wired README.md, playtesting/README.md"
grep -q '^- \*\*User stories, if the game wants them\.\*\*' "$src/CHANGELOG.md" || wired="$wired CHANGELOG.md"
[ -z "$wired" ] && ok "user stories: the template and the example's stories have their header, sections and rows, and Stories:, the cadence, the rules, the procedures (each only with them on), the settings and the docs name them" \
  || bad "the user stories aren't wired into:$wired"

# Prototypes: the procedure, the skill and tools/prototype.sh exist and are wired in. rules.md routes the
# procedure and says a prototype session is outside the loop and reaches main only through the harvest, the
# item format has Prototype:, the design procedure harvests one and files nothing without the human, the
# settings allow the script, the hooks know proto/ branches, and the docs name it. The script and the hooks
# run under "prototype".
_pp="$proc/procedures/prototype.md"
wired=""
for file in framework/.godot-director/procedures/prototype.md framework/.claude/skills/prototype/SKILL.md framework/tools/prototype.sh framework/.githooks/pre-push; do
  [ -f "$src/$file" ] || wired="$wired $file"
done
grep -q 'procedures/prototype\.md' "$src/framework/.claude/skills/prototype/SKILL.md" || wired="$wired SKILL.md"
grep -q '^## Start$' "$_pp" && grep -q '^## In a prototype session$' "$_pp" && grep -q '^## Harvest$' "$_pp" \
  && grep -qF 'bash tools/prototype.sh start <name>' "$_pp" && grep -qF 'bash tools/prototype.sh harvest <name>' "$_pp" \
  && grep -qF 'bash tools/prototype.sh remove <name>' "$_pp" && grep -qF 'bash tools/prototype.sh list' "$_pp" \
  && grep -qF 'git diff main...proto/<name>' "$_pp" && grep -qF 'Never push a `proto/` branch' "$_pp" \
  && grep -qF 'git branch -D proto/<name>' "$_pp" && grep -qF 'Never force it' "$_pp" \
  && grep -q 'Nothing is filed without the human.s answer' "$_pp" && grep -qF 'Commits need no approval' "$_pp" \
  && grep -qF '`ui-design.md` › capture' "$_pp" && grep -q 'Run `design\.md` on them' "$_pp" \
  && grep -qF 'git pull --ff-only' "$_pp" && grep -qF 'start <name> --as-is' "$_pp" \
  && grep -q "ask the human to stop the prototype's game and close its session" "$_pp" && grep -qF 'import cache' "$_pp" \
  || wired="$wired prototype.md"
grep -qF '**The game can run.**' "$_pp" && grep -qF 'bash tools/autoplay.sh smoke' "$_pp" && grep -qF 'bash tools/log_review.sh --player' "$_pp" \
  && grep -qF 'bash tools/check.sh --only tests/<file>.gd' "$_pp" && grep -qF '**A playtest:**' "$_pp" \
  && grep -qF 'the GDD changes, decisions, user stories (with user stories on) and items' "$_pp" \
  || wired="$wired prototype.md(the game can run, the harvest)"
grep -qF "gitleaks is optional in every other commit" "$_pp" && grep -qF "it won't start, or commit, without one" "$_pp" \
  && grep -qF 'tools/godot_bin.local' "$_pp" || wired="$wired prototype.md(gitleaks, Godot path)"
grep -qF 'Unlike Record step 4, a drafted story the human doesn' "$proc/procedures/design.md" || wired="$wired design.md(unanswered story)"
grep -qF '**prototype.md:**' "$proc/rules.md" && grep -q '^- \*\*Prototypes\.\*\*' "$proc/rules.md" \
  && grep -q 'That session is outside the loop' "$proc/rules.md" && grep -q 'reaches main only through the harvest' "$proc/rules.md" \
  && grep -qF 'The game can run there.' "$proc/rules.md" || wired="$wired rules.md"
grep -q '^- \*\*`Prototype:`\*\* (optional)\. `proto/<name>`' "$proc/tasks.md" || wired="$wired tasks.md"
grep -q '^## Harvest a prototype$' "$proc/procedures/design.md" && grep -q 'or harvest a prototype (Harvest a prototype, below)' "$proc/procedures/design.md" \
  && grep -qF -- '- Prototype: proto/<name>' "$proc/procedures/design.md" && grep -qF '(prototype: proto/<name>)' "$proc/procedures/design.md" \
  && grep -qF 'came from the prototype proto/<name>' "$proc/procedures/design.md" \
  && grep -q 'Nothing is filed without the human.s answer' "$proc/procedures/design.md" || wired="$wired design.md"
grep -qF '"Bash(bash tools/prototype.sh *)",' "$settings" || wired="$wired settings.json"
grep -qF 'bash tools/prototype.sh here' "$src/framework/.githooks/pre-commit" && grep -qF 'bash tools/prototype.sh here' "$src/framework/.claude/hooks/stop-check.sh" \
  && grep -qF 'refs/heads/proto/' "$src/framework/.githooks/pre-push" && grep -qF 'pre-commit pre-push' "$src/framework/tools/setup-clone.sh" || wired="$wired hooks"
grep -qF '[ -f PROTOTYPE.md ] && [ -f tools/prototype.sh ] && bash tools/prototype.sh here' "$src/framework/.githooks/pre-commit" \
  && grep -qF '[ -f PROTOTYPE.md ] && [ -f tools/prototype.sh ] && bash tools/prototype.sh here' "$src/framework/.claude/hooks/stop-check.sh" \
  && grep -qF '[ -n "$gd" ] && [ -n "$gc" ] && [ "$gd" != "$gc" ]' "$src/framework/tools/prototype.sh" \
  && grep -qF 'gitleaks:allow' "$src/framework/.githooks/pre-commit" && grep -qF 'if [[ -f $root/PROTOTYPE.md ]]; then' "$src/framework/.claude/hooks/guard-protected.sh" \
  && grep -qF '**The gates are the human' "$_pp" && grep -qF 'a staged `gitleaks:allow` comment' "$_pp" \
  && grep -qF 'refs="$(cat)"; printf' "$src/framework/tools/prototype.sh" && grep -qF 'refs="$(cat)"; printf' "$src/framework/tools/setup-clone.sh" \
  && grep -qF 'refs="$(cat)"; printf' "$_pp" || wired="$wired hooks(prototype checks, gates, chaining)"
grep -qF 'A session in a checkout that `bash tools/prototype.sh here` calls a prototype (a linked worktree on a `proto/` branch with `PROTOTYPE.md` at its root) is a prototype session: read `prototype.md` › In a prototype session before any work.' "$proc/rules.md" \
  && grep -qF 'git diff main...proto/<name> -- <path>' "$proc/procedures/build.md" || wired="$wired rules.md(prototype session) build.md"
grep -qF '`/prototype {name}`' "$src/README.md" && grep -qF 'tools/prototype.sh' "$src/README.md" && grep -qF '· prototype ·' "$src/README.md" || wired="$wired README.md"
grep -qF '`/prototype`' "$src/ONBOARDING.md" && grep -qF '.githooks/pre-commit .githooks/pre-push' "$src/ONBOARDING.md" || wired="$wired ONBOARDING.md"
grep -q '^/tools/prototype\.sh$' "$src/examples/market-day/.gitignore" || wired="$wired example .gitignore"
grep -q '^- \*\*A prototype tries a change before it.s built against the design\.\*\*' "$src/CHANGELOG.md" || wired="$wired CHANGELOG.md"
[ -z "$wired" ] && ok "prototypes: the procedure, the skill and tools/prototype.sh exist, and the rules, the item format, the design procedure, the settings, the hooks and the docs name them" \
  || bad "prototypes aren't wired into:$wired"

# Nothing is written without the human's approval of a summary (Director-Driven-Development T282): rules.md has the
# bullet right after the design-call bullet; design.md holds the answers in the conversation, has Summary and approval
# between For each question and Record each decision in one change, and Finish writes what the summary lists; every
# procedure that records from a conversation carries the pointer (design.md's stories switch, validation and
# harvest, research.md, next-task.md, drift-reset.md, ui-design.md, playtest.md, function-check.md, export.md,
# release.md, align.md and ONBOARDING.md); export.md and release.md show their summary between the last round and
# "Write it down"; align's fixes and the stories' on and off switch are part of a summary.
wired=""
_ap_ptr='Write nothing until the human approves a summary of all of it (`design.md` › Summary and approval); a chat message or an "Other" answer before then re-opens the options.'
_ap_rules="$proc/rules.md"
_ap_dm="$proc/procedures/design.md"
_ap_bullet='- **Nothing is written without the human'"'"'s explicit approval.** While a session runs, the answers stay in the conversation. A chat message or an "Other" answer during a session is a scope change or a modification, not an answer to record: it re-opens the options it touches, and the session reassesses, then restarts or continues. Once everything is chosen, show a summary of every file, line, item and story to be written (`design.md` › Summary and approval), and write and commit all of it in one change only after the human approves the summary.'
_ap_call="$(grep -n '^- A design call is a mechanic' "$_ap_rules" | cut -d: -f1)"
_ap_rule="$(grep -nxF -- "$_ap_bullet" "$_ap_rules" | cut -d: -f1)"
[ -n "$_ap_call" ] && [ -n "$_ap_rule" ] && [ "$_ap_rule" -eq $((_ap_call + 1)) ] \
  || wired="$wired rules.md(the approval bullet right after the design-call bullet)"
_ap_each="$(grep -n '^## For each question$' "$_ap_dm" | cut -d: -f1)"
_ap_sum="$(grep -n '^## Summary and approval$' "$_ap_dm" | cut -d: -f1)"
_ap_rec="$(grep -n '^## Record each decision in one change$' "$_ap_dm" | cut -d: -f1)"
[ -n "$_ap_each" ] && [ -n "$_ap_sum" ] && [ -n "$_ap_rec" ] && [ "$_ap_each" -lt "$_ap_sum" ] && [ "$_ap_sum" -lt "$_ap_rec" ] \
  || wired="$wired design.md(Summary and approval between For each question and Record)"
grep -qF 'Hold the answer in the conversation: nothing is recorded yet, and an answered part is not recorded by itself.' "$_ap_dm" \
  && ! grep -qF 'record only that part' "$_ap_dm" || wired="$wired design.md(the wait holds the answers)"
grep -qF 'Nothing is written before the human approves it.' "$_ap_dm" && grep -qF 'Approve this summary, or tell me what to change?' "$_ap_dm" \
  && grep -qF 'Only a yes to the summary as shown approves it.' "$_ap_dm" && grep -qF 'the research notes and `R<n>` items.' "$_ap_dm" \
  || wired="$wired design.md(the summary and its list)"
grep -qF 'Write everything the approved summary lists and commit it as one change, `docs: <summary>`' "$_ap_dm" \
  && grep -qF 'The approval of the summary is the approval to commit (`rules.md` › Git).' "$_ap_dm" || wired="$wired design.md(Finish)"
[ "$(grep -cF -- "$_ap_ptr" "$_ap_dm")" -ge 4 ] || wired="$wired design.md(pointers: turning user stories on and off, the validation, the harvest)"
grep -qF 'The switch is set only after the approval' "$_ap_dm" && grep -qF 'and with it the stories file, the GDD link and the items' "$_ap_dm" \
  && grep -qF 'The summary lists the `User stories: off` line' "$_ap_dm" || wired="$wired design.md(the stories switch is in the summary)"
grep -qF "the procedure's summary lists them" "$_ap_dm" || wired="$wired design.md(the Still right? ticks go into a summary)"
for _ap_f in research next-task ui-design playtest function-check align export release; do
  grep -qF -- "$_ap_ptr" "$proc/procedures/$_ap_f.md" || wired="$wired $_ap_f.md(pointer)"
done
[ "$(grep -cF -- "$_ap_ptr" "$proc/procedures/drift-reset.md")" -ge 2 ] || wired="$wired drift-reset.md(pointers in the reset and the postmortem)"
grep -qF -- "$_ap_ptr" "$src/ONBOARDING.md" && grep -q '^### Summary and approval$' "$src/ONBOARDING.md" \
  && grep -qF 'the records below are drafts, until the human approves the summary at the end of this section' "$src/ONBOARDING.md" \
  && grep -qF 'List the mechanical fixes it finds, and write them after the human approves them' "$src/ONBOARDING.md" \
  || wired="$wired ONBOARDING.md(pointer, Summary and approval, the align fixes)"
grep -qF 'Hold the note and the item in the conversation.' "$proc/procedures/research.md" \
  && grep -qF 'outside a design session shows its own summary of the note and the item' "$proc/procedures/research.md" \
  && grep -qF '› Research items step 2 describes' "$proc/procedures/research.md" || wired="$wired research.md(holds the note and the item)"
grep -qF 'the summary lists its records, as `design.md` lists them' "$proc/procedures/next-task.md" || wired="$wired next-task.md(blocked)"
grep -qF 'the decision lines word for word, the Open Questions removed or added, the design diff' "$proc/procedures/drift-reset.md" \
  && grep -qF 'each TASKS.md item in full' "$proc/procedures/drift-reset.md" \
  && grep -qF 'what the postmortem will write: `postmortem.md` as it will read' "$proc/procedures/drift-reset.md" \
  && grep -qF 'are written as the analysis runs.' "$proc/procedures/drift-reset.md" || wired="$wired drift-reset.md(the summaries)"
grep -qF 'The summary lists the spec, the decision lines, the open questions and the item' "$proc/procedures/ui-design.md" || wired="$wired ui-design.md(the summary's list)"
for _ap_f in playtest function-check; do
  grep -qF 'The summary lists the `B` items, the story rewrites and ticks' "$proc/procedures/$_ap_f.md" || wired="$wired $_ap_f.md(the summary's list)"
done
grep -qF 'straight away' "$proc/procedures/playtest.md" "$src/framework/playtesting/README.md" "$src/examples/scenarios.md" && wired="$wired playtest.md(bugs are no longer filed straight away)"
grep -qF 'during onboarding they are approved where onboarding approves the install commit' "$proc/procedures/align.md" \
  && grep -qF 'Inside a session the fixes join its summary' "$proc/procedures/align.md" \
  && grep -qF 'rerunning the installer is a fix: it runs once the human approves the summary' "$proc/procedures/align.md" || wired="$wired align.md(the fixes are part of the summary)"
for _ap_f in export release; do
  _ap_p="$proc/procedures/$_ap_f.md"
  _ap_s="$(grep -n '^3\. \*\*Summary and approval\.\*\*' "$_ap_p" | cut -d: -f1)"
  _ap_w="$(grep -n '^4\. \*\*Write it down\.\*\*' "$_ap_p" | cut -d: -f1)"
  _ap_t="$(grep -n '^5\. \*\*Try it\.\*\*' "$_ap_p" | cut -d: -f1)"
  [ -n "$_ap_s" ] && [ -n "$_ap_w" ] && [ -n "$_ap_t" ] && [ "$_ap_s" -lt "$_ap_w" ] && [ "$_ap_w" -lt "$_ap_t" ] \
    && grep -qF 'show a summary of everything "Write it down" will write' "$_ap_p" \
    && grep -qF '"Write it down" starts after the approval, and "Try it" runs on what it wrote.' "$_ap_p" \
    && grep -qF 'go into the summary (step 3)' "$_ap_p" || wired="$wired $_ap_f.md(a summary between the last round and Write it down)"
done
grep -q 'once the human approves a summary of them' "$src/framework/.claude/skills/design/SKILL.md" || wired="$wired skills/design/SKILL.md(description)"
grep -qF '**Nothing is written until you approve a summary of it.**' "$src/README.md" || wired="$wired README.md"
grep -q '^- \*\*Nothing is written until the director approves a summary of it\.\*\*' "$src/CHANGELOG.md" || wired="$wired CHANGELOG.md"
[ -z "$wired" ] && ok "nothing is written until the human approves a summary: the rule, design.md's Summary and approval, and the pointer in each procedure that records from a conversation" \
  || bad "the approval of a summary isn't wired into:$wired"

}

l_installer_a() {
# --- installer ----------------------------------------------------------------------------------
echo "installer"
game="$work/market-day"
cp -R "$src/examples/market-day" "$game"
rm -rf "$game/.godot" "$game/.claude" "$game/.godot-director" "$game/.githooks" "$game/tools/godot_bin.local"
(cd "$game" && git init -q && git config core.autocrlf false && git add -A && git_q commit -qm "example") || exit 1
cd "$game" || exit 1

out="$(bash "$src/install.sh" . 2>&1)"; expect_status "installs" 0 $? "$out"
if [ -f .godot-director/manifest ] && [ -f .godot-director/procedures/next-task.md ] && [ -f tools/check.gd ] \
    && [ -f tools/setup-clone.sh ] && [ -f .claude/skills/next-task/SKILL.md ] && [ -f .claude/hooks/guard-git.sh ]; then
  ok "copies the core and the Claude adapter, and writes the manifest"
else
  bad "copies the core and the Claude adapter, and writes the manifest" "$out"
fi
if [ -f .godot-director/procedures/research.md ] && [ -f .godot-director/research-domain.md ] && [ -f .claude/agents/researcher.md ] \
    && [ -f .claude/skills/research/SKILL.md ] && [ -f design/research/README.md ]; then
  ok "installs the research assistant: procedure, domain file, researcher, skill and note folder"
else
  bad "installs the research assistant: procedure, domain file, researcher, skill and note folder" "$out"
fi
if [ -f .godot-director/procedures/export.md ] && [ -f .claude/skills/export/SKILL.md ] && grep -q '^/builds/$' .gitignore; then
  ok "installs /export: procedure, skill and the builds/ gitignore line"
else
  bad "installs /export: procedure, skill and the builds/ gitignore line" "$out"
fi
if [ -f .godot-director/procedures/release.md ] && [ -f .godot-director/templates/release-workflow.yml ] && [ -f .claude/skills/release/SKILL.md ] && [ -x tools/release.sh ]; then
  ok "installs /release: procedure, workflow template, skill and tools/release.sh"
else
  bad "installs /release: procedure, workflow template, skill and tools/release.sh" "$out"
fi
if [ -x tools/ui_capture.sh ] && [ -f tools/ui_capture.gd ] && [ -f tools/ui_lint.gd ] && [ -f tools/ui_drawing.gd ] && [ -f design/ui/README.md ] && [ -f .claude/skills/ui-design/SKILL.md ] \
    && grep -q '^/design/ui/captures/$' .gitignore && grep -q '"shop"' tools/ui_screens.gd; then
  ok "installs /ui-design: procedure, skill, capture tools and the captures gitignore line, keeping the game's catalog"
else
  bad "installs /ui-design: procedure, skill, capture tools and the captures gitignore line, keeping the game's catalog" "$out"
fi
if [ -f tools/play_log_base.gd ] && cut -f2 .godot-director/manifest | grep -q '^tools/play_log_base\.gd$' && grep -q 'RunState' tools/play_log.gd; then
  ok "installs the play log base, keeping the game's own PlayLog"
else
  bad "installs the play log base, keeping the game's own PlayLog" "$out"
fi
if [ -x tools/autoplay.sh ] && [ -f tools/autoplay.gd ] && [ -f tools/autoplay_adapter_base.gd ] && [ -f tools/autoplay_catalog.gd ] \
    && cut -f2 .godot-director/manifest | grep -q '^tools/autoplay_adapter_base\.gd$' && grep -q 'RunState' tools/autoplay_adapter.gd \
    && grep -q '"trade_week"' tools/autoplay_scenarios.gd && grep -q '^/playtesting/autoplay/$' .gitignore; then
  ok "installs autoplay and the run folders' gitignore line, keeping the game's adapter and scenarios"
else
  bad "installs autoplay and the run folders' gitignore line, keeping the game's adapter and scenarios" "$out"
fi
if [ -x tools/log_review.sh ] && [ -f tools/log_review.gd ] && cut -f2 .godot-director/manifest | grep -q '^tools/log_review\.gd$' \
    && [ "$(cat playtesting/signatures.tsv)" = "$(printf 'id\tkind\ttext\tfirst_seen_build')" ] \
    && grep -q '^/tools/log_review\.gd text eol=lf$' .gitattributes && grep -q '^/playtesting/signatures\.tsv text eol=lf$' .gitattributes; then
  ok "installs log review, the signatures.tsv seed and the .gitattributes lines for both"
else
  bad "installs log review, the signatures.tsv seed and the .gitattributes lines for both" "$out"
fi
if [ -f tools/dev_menu_base.gd ] && cut -f2 .godot-director/manifest | grep -q '^tools/dev_menu_base\.gd$' && grep -q 'register_system("Run", RunState' tools/dev_menu.gd \
    && grep -q '^/tools/dev_menu_base\.gd text eol=lf$' .gitattributes; then
  ok "installs the dev menu base and its .gitattributes line, keeping the game's own DevMenu"
else
  bad "installs the dev menu base and its .gitattributes line, keeping the game's own DevMenu" "$out"
fi
if [ -x tools/stories.sh ] && [ -f .godot-director/templates/user-stories.md ] && cut -f2 .godot-director/manifest | grep -q '^tools/stories\.sh$' \
    && cut -f2 .godot-director/manifest | grep -q '^\.godot-director/templates/user-stories\.md$' && cmp -s design/user-stories.md "$stories_ex"; then
  ok "installs tools/stories.sh and the user stories template, keeping the game's own stories"
else
  bad "installs tools/stories.sh and the user stories template, keeping the game's own stories" "$out"
fi
if [ -f .godot-director/procedures/prototype.md ] && [ -f .claude/skills/prototype/SKILL.md ] && [ -x tools/prototype.sh ] && [ -x .githooks/pre-push ] \
    && cut -f2 .godot-director/manifest | grep -q '^tools/prototype\.sh$' && cut -f2 .godot-director/manifest | grep -q '^\.githooks/pre-push$'; then
  ok "installs prototypes: the procedure, the skill, tools/prototype.sh and the pre-push hook"
else
  bad "installs prototypes: the procedure, the skill, tools/prototype.sh and the pre-push hook" "$out"
fi
if [ -x .claude/hooks/session-touched.sh ] && cut -f2 .godot-director/manifest | grep -q '^\.claude/hooks/session-touched\.sh$' \
    && git check-ignore -q .godot/godot-director/sessions/design.touched && git check-ignore -q .godot/godot-director/sessions/design.before; then
  ok "installs the session record hook, and git ignores the records it keeps"
else
  bad "installs the session record hook, and git ignores the records it keeps" "$(cat .gitignore)"
fi
if [ -x .claude/hooks/release-check.sh ] && cut -f2 .godot-director/manifest | grep -q '^\.claude/hooks/release-check\.sh$' \
    && grep -q 'release-check\.sh' .claude/settings.json && git check-ignore -q .godot/godot-director/latest-release; then
  ok "installs the release check hook, wires it into settings.json, and git ignores the cache it keeps"
else
  bad "installs the release check hook, wires it into settings.json, and git ignores the cache it keeps" "$(cat .gitignore)"
fi
if [ -x .claude/hooks/orphan-report.sh ] && cut -f2 .godot-director/manifest | grep -q '^\.claude/hooks/orphan-report\.sh$' && grep -q 'orphan-report\.sh' .claude/settings.json; then
  ok "installs the orphan report hook and wires it into settings.json"
else
  bad "installs the orphan report hook and wires it into settings.json" "$(cat .claude/settings.json)"
fi
grep -q "Market Day" AGENTS.md && ok "keeps the project's own files" || bad "keeps the project's own files"
[ -z "$(git status --porcelain)" ] && ok "adds no duplicate .gitignore/.gitattributes lines" || bad "adds no duplicate lines" "$(git status --porcelain)"
out="$(bash "$src/install.sh" . 2>&1)"; expect_output "a second run changes nothing" "0 new, 0 updated" "$out"

echo "# my own note" >> .godot-director/procedures/prune.md
out="$(bash "$src/install.sh" . 2>&1)"
if grep -q "my own note" .godot-director/procedures/prune.md && [ ! -f .godot-director/procedures/prune.md.gdir-new ]; then
  ok "keeps a local edit when this version doesn't change the file"
else
  bad "keeps a local edit when this version doesn't change the file" "$out"
fi
# Pretend the installed version had a different prune.md: now both sides changed.
awk -F'\t' -v OFS='\t' '$2 == ".godot-director/procedures/prune.md" { $1 = "0000000000000000000000000000000000000000" } { print }' \
  .godot-director/manifest > "$work/manifest" && cp "$work/manifest" .godot-director/manifest
out="$(bash "$src/install.sh" . 2>&1)"
if [ -f .godot-director/procedures/prune.md.gdir-new ] && grep -q "my own note" .godot-director/procedures/prune.md; then
  ok "writes .gdir-new when both sides changed a file"
else
  bad "writes .gdir-new when both sides changed a file" "$out"
fi
mv .godot-director/procedures/prune.md.gdir-new .godot-director/procedures/prune.md
# An unchanged file from an older version is replaced.
printf 'old version\n' > .godot-director/procedures/align.md
awk -F'\t' -v OFS='\t' -v h="$(hash_of .godot-director/procedures/align.md)" '$2 == ".godot-director/procedures/align.md" { $1 = h } { print }' \
  .godot-director/manifest > "$work/manifest" && cp "$work/manifest" .godot-director/manifest
out="$(bash "$src/install.sh" . 2>&1)"
cmp -s .godot-director/procedures/align.md "$src/framework/.godot-director/procedures/align.md" \
  && ok "replaces a file unchanged since the last install" || bad "replaces a file unchanged since the last install" "$out"

printf 'extends RefCounted\n' > tools/retired.gd; printf 'uid://x\n' > tools/retired.gd.uid
printf '%s\ttools/retired.gd\n' "$(hash_of tools/retired.gd)" >> .godot-director/manifest
out="$(bash "$src/install.sh" . 2>&1)"
[ ! -f tools/retired.gd ] && [ ! -f tools/retired.gd.uid ] && ok "removes a dropped file and its .uid" || bad "removes a dropped file and its .uid" "$out"

# Upgrading a 2.x install, made by turning a fresh install back into the 2.x layout.
legacy="$work/legacy"; new_repo "$legacy"
bash "$src/install.sh" "$legacy" >/dev/null 2>&1
(
  cd "$legacy" || exit 1
  git_q add -A && git_q commit -qm "install" && git mv .godot-director .claude4godot || exit 1
  printf 'old rules\n' > .claude4godot/rules.md                       # unchanged since the 2.x install
  echo "# my own note" >> .claude4godot/procedures/prune.md          # edited; 3.0.0 doesn't change it
  echo "# my own note" >> .claude4godot/procedures/align.md          # edited; 2.x had another version
  awk -F'\t' -v OFS='\t' -v rules="$(hash_of .claude4godot/rules.md)" '
    /^# godot-director / { print "# claude4godot 2.0.2"; next }
    $2 == ".godot-director/rules.md" { $1 = rules }
    $2 == ".godot-director/procedures/align.md" { $1 = "0000000000000000000000000000000000000000" }
    { sub(/^\.godot-director\//, ".claude4godot/", $2); print }' .claude4godot/manifest > "$work/manifest"
  cp "$work/manifest" .claude4godot/manifest
  for file in .gitignore .gitattributes; do
    sed -e 's|^# Godot Director$|# Claude4Godot|' -e 's|\.gdir-new|.c4g-new|' -e 's|/\.godot-director/|/.claude4godot/|' "$file" > "$work/lines"
    cp "$work/lines" "$file"
  done
  printf 'x\n' > tools/check.sh.c4g-new
  printf '#!/usr/bin/env bash\n# Claude4Godot: runs the project'"'"'s committed pre-commit hook. Installed by tools/setup-clone.sh.\nexit 0\n' \
    > "$(git rev-parse --git-path hooks)/pre-commit"
  mkdir -p .godot/claude4godot && : > .godot/claude4godot/check.log
  git_q add -A && git_q commit -qm "2.x layout"
)
out="$(bash "$src/install.sh" "$legacy" 2>&1)"; expect_status "upgrades a 2.x install" 0 $? "$out"
expect_output "reports the upgrade from 2.x and the migration" "upgraded from 2\.0\.2 to .*migrated from the 2\.x names" "$(printf '%s' "$out" | tr '\n' ' ')"
cd "$legacy" || exit 1
if [ ! -e .claude4godot ] && [ -f .godot-director/manifest ] && grep -qE "^# godot-director $(tr -d '\r\n' < "$src/VERSION")( [+] unreleased [(].*[)])?$" .godot-director/manifest \
    && ! grep -q claude4godot .godot-director/manifest && [ -n "$(git diff --cached --name-status -M | grep '^R.*\.claude4godot/LICENSE')" ]; then
  ok "moves .claude4godot/ to .godot-director/ with git mv, and rewrites the manifest"
else
  bad "moves .claude4godot/ to .godot-director/ with git mv, and rewrites the manifest" "$out$nl$(git status --short)"
fi
if grep -q "my own note" .godot-director/procedures/prune.md && [ ! -f .godot-director/procedures/prune.md.gdir-new ] \
    && grep -q "my own note" .godot-director/procedures/align.md && [ -f .godot-director/procedures/align.md.gdir-new ] \
    && cmp -s .godot-director/rules.md "$src/framework/.godot-director/rules.md"; then
  ok "carries the 2.x manifest over: local edits kept or flagged, unchanged files replaced"
else
  bad "carries the 2.x manifest over: local edits kept or flagged, unchanged files replaced" "$out"
fi
[ -f tools/check.sh.gdir-new ] && [ ! -f tools/check.sh.c4g-new ] && ok "renames a leftover .c4g-new to .gdir-new" \
  || bad "renames a leftover .c4g-new to .gdir-new" "$out"
if ! grep -qi "claude4godot\|c4g" .gitignore .gitattributes && [ "$(grep -c '^\*\.gdir-new$' .gitignore)" -eq 1 ] \
    && [ "$(grep -c '^/\.godot-director/\*\* text eol=lf$' .gitattributes)" -eq 1 ]; then
  ok "replaces the 2.x .gitignore and .gitattributes lines without duplicates"
else
  bad "replaces the 2.x .gitignore and .gitattributes lines without duplicates" "$(cat .gitignore .gitattributes)"
fi
grep -q "^# Godot Director: runs" "$(git rev-parse --git-path hooks)/pre-commit" && [ ! -e .godot/claude4godot ] \
  && ok "updates the clone's 2.x pre-commit shim and drops the old runtime folder" \
  || bad "updates the clone's 2.x pre-commit shim and drops the old runtime folder" "$out"
cd "$game" || exit 1
}

l_installer_b() {
cd "$work" || exit 1
# Upgrading from the last release, v3.10.0 (taken from git history; skipped where the tag isn't there):
# the new files and seeds arrive, the game keeps its own AGENTS.md and check.cfg, the layout lint in
# the check ends up off, and align lists the screens the catalog doesn't cover without failing.
if git -C "$src" rev-parse -q --verify 'v3.10.0^{commit}' >/dev/null 2>&1; then
  old_release="$work/v3.10.0"; mkdir -p "$old_release"
  git -C "$src" archive v3.10.0 | (cd "$old_release" && tar -xf -)
  upgraded="$work/upgraded"
  cp -R "$old_release/examples/market-day" "$upgraded"
  (cd "$upgraded" && git init -q && git config core.autocrlf false && git add -A && git_q commit -qm "example") || exit 1
  bash "$old_release/install.sh" "$upgraded" >/dev/null 2>&1
  (cd "$upgraded" && git add -A && { git_q commit -qm "install 3.10.0" >/dev/null 2>&1 || true; } && cp AGENTS.md "$work/up-agents" && cp tools/check.cfg "$work/up-check-cfg")
  out="$(bash "$src/install.sh" "$upgraded" 2>&1)"; expect_status "upgrades a game from v3.10.0" 0 $? "$out"
  if [ -f "$upgraded/tools/ui_screens.gd" ] && [ -f "$upgraded/tools/ui_capture.cfg" ] && [ -f "$upgraded/design/ui/README.md" ] && [ -f "$upgraded/design/director-gdd.md" ] \
      && grep -q '^/design/ui/captures/$' "$upgraded/.gitignore" && grep -q 'tools/ui_verify\.gd$' "$upgraded/.godot-director/manifest" \
      && grep -q 'procedures/ui-design\.md$' "$upgraded/.godot-director/manifest" && grep -q 'skills/ui-design/SKILL\.md$' "$upgraded/.godot-director/manifest"; then
    ok "the upgrade adds the stubs, the human-written GDD template, the captures .gitignore line and the manifest entries"
  else
    bad "the upgrade adds the stubs, the human-written GDD template, the captures .gitignore line and the manifest entries" "$out"
  fi
  if [ -f "$upgraded/tools/autoplay_adapter.gd" ] && [ -f "$upgraded/tools/autoplay_scenarios.gd" ] && [ -f "$upgraded/tools/autoplay_invariants.gd" ] \
      && grep -q 'tools/autoplay\.gd$' "$upgraded/.godot-director/manifest" && grep -q '^/playtesting/autoplay/$' "$upgraded/.gitignore"; then
    ok "the upgrade adds autoplay, its seeds and the run folders' .gitignore line"
  else
    bad "the upgrade adds autoplay, its seeds and the run folders' .gitignore line" "$out"
  fi
  if [ -x "$upgraded/tools/log_review.sh" ] && grep -q 'tools/log_review\.gd$' "$upgraded/.godot-director/manifest" \
      && cmp -s "$upgraded/playtesting/signatures.tsv" "$src/project/playtesting/signatures.tsv" \
      && grep -q '^/playtesting/signatures\.tsv text eol=lf$' "$upgraded/.gitattributes"; then
    ok "the upgrade adds log review, the signatures.tsv seed and its .gitattributes line"
  else
    bad "the upgrade adds log review, the signatures.tsv seed and its .gitattributes line" "$out"
  fi
  if cmp -s "$upgraded/tools/dev_menu.gd" "$src/project/tools/dev_menu.gd" && grep -q 'tools/dev_menu_base\.gd$' "$upgraded/.godot-director/manifest" \
      && grep -q '^/tools/dev_menu_base\.gd text eol=lf$' "$upgraded/.gitattributes" && ! grep -q '^DevMenu=' "$upgraded/project.godot"; then
    ok "the upgrade adds the dev menu base and its seed, and leaves it unregistered until the human answers"
  else
    bad "the upgrade adds the dev menu base and its seed, and leaves it unregistered until the human answers" "$out"
  fi
  cmp -s "$upgraded/AGENTS.md" "$work/up-agents" && cmp -s "$upgraded/tools/check.cfg" "$work/up-check-cfg" \
    && ok "the upgrade keeps the game's own AGENTS.md and tools/check.cfg" || bad "the upgrade keeps the game's own AGENTS.md and tools/check.cfg"
  if grep -q '^check_in_check=false$' "$upgraded/tools/ui_capture.cfg" && grep -q '^enforce=\[\]$' "$upgraded/tools/ui_capture.cfg"; then
    ok "the upgrade writes the layout lint in the check off (check_in_check=false, enforce=[])"
  else
    bad "the upgrade writes the layout lint in the check off" "$(cat "$upgraded/tools/ui_capture.cfg")"
  fi
  if [ -n "$godot" ]; then
    cp "$upgraded/scenes/shop_screen.tscn" "$upgraded/scenes/extra_screen.tscn"
    out="$(cd "$upgraded" && GODOT_BIN="$godot" bash tools/ui_capture.sh --missing 2>&1)"; expect_status "align's screen listing doesn't fail" 0 $? "$out"
    if printf '%s\n' "$out" | grep -q '^missing: scenes/extra_screen\.tscn' && ! printf '%s\n' "$out" | grep -q '^missing: scenes/shop_screen\.tscn'; then
      ok "align lists a screen scene the catalog doesn't cover, and not the one it does"
    else
      bad "align lists a screen scene the catalog doesn't cover, and not the one it does" "$out"
    fi
    rm -f "$upgraded/scenes/extra_screen.tscn" "$upgraded/scenes/extra_screen.tscn.uid"
    out="$(cd "$upgraded" && GODOT_BIN="$godot" bash tools/check.sh 2>&1)"; expect_status "the upgraded game's check passes with the lint off" 0 $? "$out"
    expect_no_output "and runs no layout lint" "ui lint" "$out"
  fi
else
  echo "  skip  upgrade from v3.10.0: no v3.10.0 tag in this checkout"
fi
}

l_installer_c() {
cd "$work" || exit 1
core_only="$work/core-only"; new_repo "$core_only"
out="$(bash "$src/install.sh" --tools none "$core_only" 2>&1)"
if [ ! -e "$core_only/.claude" ] && [ ! -e "$core_only/CLAUDE.md" ] && [ -f "$core_only/AGENTS.md" ] && [ -f "$core_only/.godot-director/rules.md" ]; then
  ok "--tools none installs the tool-neutral core only"
else
  bad "--tools none installs the tool-neutral core only" "$out"
fi
if [ -f "$core_only/.godot-director/procedures/research.md" ] && [ -f "$core_only/.godot-director/research-domain.md" ] \
    && [ -f "$core_only/design/research/README.md" ] && [ -f "$core_only/tools/ui_screens.gd" ] && [ -f "$core_only/tools/ui_capture.cfg" ] && grep -q '^\*\*Next IDs:\*\* T[0-9]* · B[0-9]* · R[0-9]*$' "$core_only/TASKS.md"; then
  ok "a new game gets the research procedure and domain file, the note folder, the screen catalog and capture settings, and an R counter in TASKS.md, even with --tools none"
else
  bad "a new game gets the research procedure and domain file, the note folder, the screen catalog and capture settings, and an R counter in TASKS.md" "$out"
fi
if [ -f "$core_only/tools/play_log_base.gd" ] && cmp -s "$core_only/tools/play_log.gd" "$src/project/tools/play_log.gd"; then
  ok "a new game gets the play log base and the PlayLog seed, even with --tools none"
else
  bad "a new game gets the play log base and the PlayLog seed, even with --tools none" "$out"
fi
if [ -x "$core_only/tools/autoplay.sh" ] && [ -f "$core_only/tools/autoplay.gd" ] \
    && cmp -s "$core_only/tools/autoplay_adapter.gd" "$src/project/tools/autoplay_adapter.gd" \
    && cmp -s "$core_only/tools/autoplay_scenarios.gd" "$src/project/tools/autoplay_scenarios.gd" \
    && cmp -s "$core_only/tools/autoplay_invariants.gd" "$src/project/tools/autoplay_invariants.gd" && grep -q '^/playtesting/autoplay/$' "$core_only/.gitignore"; then
  ok "a new game gets autoplay, the adapter, scenario and invariant seeds and the run folders' gitignore line, even with --tools none"
else
  bad "a new game gets autoplay, the adapter, scenario and invariant seeds and the run folders' gitignore line, even with --tools none" "$out"
fi
if [ -x "$core_only/tools/log_review.sh" ] && [ -f "$core_only/tools/log_review.gd" ] \
    && cmp -s "$core_only/playtesting/signatures.tsv" "$src/project/playtesting/signatures.tsv"; then
  ok "a new game gets log review and the signatures.tsv seed, even with --tools none"
else
  bad "a new game gets log review and the signatures.tsv seed, even with --tools none" "$out"
fi
if [ -f "$core_only/tools/dev_menu_base.gd" ] && cmp -s "$core_only/tools/dev_menu.gd" "$src/project/tools/dev_menu.gd"; then
  ok "a new game gets the dev menu base and the DevMenu seed, even with --tools none"
else
  bad "a new game gets the dev menu base and the DevMenu seed, even with --tools none" "$out"
fi
if [ -f "$core_only/design/director-gdd.md" ] && grep -q '^# Game Design Document (GDD): ' "$core_only/design/director-gdd.md"; then
  ok "a new game gets the human-written GDD template, even with --tools none"
else
  bad "a new game gets the human-written GDD template, even with --tools none" "$out"
fi
if [ -x "$core_only/tools/stories.sh" ] && [ -f "$core_only/.godot-director/templates/user-stories.md" ] && [ ! -e "$core_only/design/user-stories.md" ]; then
  ok "a new game gets tools/stories.sh and the user stories template, and no design/user-stories.md until it turns them on"
else
  bad "a new game gets tools/stories.sh and the user stories template, and no design/user-stories.md until it turns them on" "$out"
fi
# Installing from a Godot Director folder that is itself a git clone, or sits inside the game.
gdir_clone="$work/gdir-clone"; cp -R "$src" "$gdir_clone"; rm -rf "$gdir_clone/.git"
(cd "$gdir_clone" && git init -q && git config core.autocrlf false && git add -A && git_q commit -qm gdir) >/dev/null 2>&1
from_clone="$work/from-clone"; new_repo "$from_clone"
out="$(bash "$gdir_clone/install.sh" "$from_clone" 2>&1)"; expect_status "installs from a Godot Director git clone" 0 $? "$out"
inside="$work/inside"; new_repo "$inside"; cp -R "$gdir_clone" "$inside/Godot-Director"; rm -rf "$inside/Godot-Director/.git"
printf '/Godot-Director/\n' >> "$inside/.git/info/exclude"
out="$(bash "$inside/Godot-Director/install.sh" "$inside" 2>&1)"; expect_status "installs from a Godot Director folder inside the game" 0 $? "$out"
[ -f "$inside/.godot-director/LICENSE" ] && ok "installs the license copy" || bad "installs the license copy" "$out"

# An install from a source with unreleased changes says so. A copy of the installer and its files, in
# a git repository of its own (so the commit is known), with the CHANGELOG given. The copy leaves out
# the rest of this folder (tests, node_modules) to stay quick.
snap_version="$(tr -d '\r\n' < "$src/VERSION")"
snapshot_source() { # snapshot_source <folder> <CHANGELOG to use>
  rm -rf "$1" && mkdir -p "$1" \
    && cp -R "$src/framework" "$src/project" "$src/install.sh" "$src/VERSION" "$1/" \
    && cp "$2" "$1/CHANGELOG.md" \
    && (cd "$1" && git init -q && git config core.autocrlf false && git add -A && git_q commit -qm snapshot) >/dev/null 2>&1
}
printf '# Changelog\n\n## Unreleased\n\n- **New: a snapshot entry.**\n\n## %s (2026-10-17)\n\n- Earlier.\n' "$snap_version" > "$work/changelog-unreleased.md"
printf '# Changelog\n\n## Unreleased\n\n## %s (2026-10-17)\n\n- Earlier.\n' "$snap_version" > "$work/changelog-empty.md"
printf '# Changelog\n\n## %s (2026-10-17)\n\n- Earlier.\n' "$snap_version" > "$work/changelog-release.md"

snap="$work/snapshot"
snapshot_source "$snap" "$work/changelog-unreleased.md" || bad "builds a source with unreleased entries"
snap_commit="$(git -C "$snap" rev-parse --short HEAD 2>/dev/null)"
snap_app="$work/snapshot-app"; new_repo "$snap_app"
out="$(bash "$snap/install.sh" "$snap_app" 2>&1)"; expect_status "installs from a source with unreleased entries" 0 $? "$out"
if [ "$(sed -n 1p "$snap_app/.godot-director/manifest")" = "# godot-director $snap_version + unreleased ($snap_commit)" ] \
    && [ "$(sed -n 2p "$snap_app/.godot-director/manifest")" = "# source $snap_commit" ]; then
  ok "the manifest says unreleased, with the source commit on its own line"
else
  bad "the manifest says unreleased, with the source commit on its own line" "$(head -n 3 "$snap_app/.godot-director/manifest")"
fi
closing="Installed $snap_version + unreleased ($snap_commit): a development snapshot, not a release. The latest release is at https://github.com/Freakling/Godot-Director/releases."
printf '%s\n' "$out" | grep -qxF "$closing" \
  && ok "the closing lines say the install is a development snapshot" \
  || bad "the closing lines say the install is a development snapshot" "$out"

empty="$work/snapshot-empty"
snapshot_source "$empty" "$work/changelog-empty.md" || bad "builds a source with an empty Unreleased section"
empty_commit="$(git -C "$empty" rev-parse --short HEAD 2>/dev/null)"
empty_app="$work/empty-app"; new_repo "$empty_app"
out="$(bash "$empty/install.sh" "$empty_app" 2>&1)"; expect_status "installs from a source with an empty Unreleased section" 0 $? "$out"
if [ "$(sed -n 1p "$empty_app/.godot-director/manifest")" = "# godot-director $snap_version" ] \
    && [ "$(sed -n 2p "$empty_app/.godot-director/manifest")" = "# source $empty_commit" ]; then
  ok "an empty Unreleased section records the plain version and the commit"
else
  bad "an empty Unreleased section records the plain version and the commit" "$(head -n 3 "$empty_app/.godot-director/manifest")"
fi
expect_no_output "an empty Unreleased section adds no closing line" "development snapshot" "$out"

# A release records the plain version, and its commit when it comes from a git checkout. A release
# zip has no .git, and an enclosing repository's commit must not be recorded for it.
rel="$work/snapshot-release"
snapshot_source "$rel" "$work/changelog-release.md" || bad "builds a release source"
rel_commit="$(git -C "$rel" rev-parse --short HEAD 2>/dev/null)"
rel_app="$work/release-app"; new_repo "$rel_app"
out="$(bash "$rel/install.sh" "$rel_app" 2>&1)"; expect_status "installs from a release checkout" 0 $? "$out"
if [ "$(sed -n 1p "$rel_app/.godot-director/manifest")" = "# godot-director $snap_version" ] \
    && [ "$(sed -n 2p "$rel_app/.godot-director/manifest")" = "# source $rel_commit" ]; then
  ok "a release checkout records the plain version and its commit"
else
  bad "a release checkout records the plain version and its commit" "$(head -n 3 "$rel_app/.godot-director/manifest")"
fi
expect_no_output "a release adds no closing line about snapshots" "development snapshot" "$out"

zip_app="$work/zip-app"; new_repo "$zip_app"
mkdir -p "$zip_app/Godot-Director"
cp -R "$rel/framework" "$rel/project" "$rel/install.sh" "$rel/VERSION" "$rel/CHANGELOG.md" "$zip_app/Godot-Director/"
out="$(bash "$zip_app/Godot-Director/install.sh" "$zip_app" 2>&1)"; expect_status "installs from a release folder with no git, inside an app repository" 0 $? "$out"
if [ "$(sed -n 1p "$zip_app/.godot-director/manifest")" = "# godot-director $snap_version" ] \
    && [ "$(grep -c '^# source' "$zip_app/.godot-director/manifest")" -eq 0 ]; then
  ok "a release folder with no git records no commit"
else
  bad "a release folder with no git records no commit" "$(head -n 3 "$zip_app/.godot-director/manifest")"
fi

# A snapshot folder with no git: the suffix without a commit, and no # source line.
zip_snap="$work/zip-snapshot-app"; new_repo "$zip_snap"
mkdir -p "$zip_snap/Godot-Director"
cp -R "$rel/framework" "$rel/project" "$rel/install.sh" "$rel/VERSION" "$zip_snap/Godot-Director/"
cp "$work/changelog-unreleased.md" "$zip_snap/Godot-Director/CHANGELOG.md"
out="$(bash "$zip_snap/Godot-Director/install.sh" "$zip_snap" 2>&1)"; expect_status "installs from an unreleased folder with no git" 0 $? "$out"
if [ "$(sed -n 1p "$zip_snap/.godot-director/manifest")" = "# godot-director $snap_version + unreleased" ] \
    && [ "$(grep -c '^# source' "$zip_snap/.godot-director/manifest")" -eq 0 ] \
    && printf '%s\n' "$out" | grep -qxF "Installed $snap_version + unreleased: a development snapshot, not a release. The latest release is at https://github.com/Freakling/Godot-Director/releases."; then
  ok "an unreleased folder with no git records the suffix without a commit, and says so"
else
  bad "an unreleased folder with no git records the suffix without a commit, and says so" "$out"
fi

# An upgrade from the unreleased install reads the old version without its suffix (and skips the
# # source line): the next release, 9.9.9, upgrades it, and the message says so.
next="$work/snapshot-next"
snapshot_source "$next" "$work/changelog-release.md" && printf '9.9.9\n' > "$next/VERSION" \
  || bad "builds the next release source"
out="$(bash "$next/install.sh" "$snap_app" 2>&1)"; expect_status "upgrades from an unreleased install" 0 $? "$out"
expect_output "the upgrade reads the old version without the unreleased suffix" "upgraded from $snap_version to 9[.]9[.]9 in " "$out"
expect_no_output "the # source line isn't read as a file" "no longer part of Godot Director" "$out"
expect_no_output "the upgrade to a release closes without the snapshot line" "development snapshot" "$out"

mkdir -p "$core_only/sub"
out="$(bash "$src/install.sh" "$core_only/sub" 2>&1)"; expect_status "refuses a folder that isn't the repository root" 1 $? "$out"

# A Windows clone with core.autocrlf=true, and an editor that saved CRLF.
crlf_src="$work/crlf-src"; new_repo "$crlf_src"
bash "$src/install.sh" "$crlf_src" >/dev/null 2>&1 && (cd "$crlf_src" && git add -A && git_q commit -qm install)
git -c core.autocrlf=true clone -q "$crlf_src" "$work/crlf" && cd "$work/crlf" && git config core.autocrlf true
[ -f .godot-director/rules.md ] && ok "a clone carries the installed framework" || bad "a clone carries the installed framework"
awk '{ printf "%s\r\n", $0 }' .godot-director/rules.md > "$work/crlf-rules" && cp "$work/crlf-rules" .godot-director/rules.md
out="$(bash "$src/install.sh" . 2>&1)"; status=$?
expect_status "reinstalls in a CRLF clone" 0 "$status" "$out"
expect_output "reports that clone as reinstalled" "reinstalled" "$out"
expect_no_output "CRLF line endings don't count as local edits" "CONFLICT|kept your changes" "$out"
}

l_guard() {
lane_game base
echo "git guard"
guard_dir="$work/guard-cases"; mkdir -p "$guard_dir"
for cmd in 'git commit -m x --no-verify' 'git commit -nm "x"' 'git push origin main --force' \
    'git push --force-with-lease=main origin' 'git push origin +main' 'git reset HEAD --hard' \
    'git -c core.hooksPath=/dev/null commit -m x' 'git config core.hooksPath ""' 'cd x && git clean -fd' \
    'git checkout -- .' 'git restore .' 'git stash drop' 'git branch -D topic' 'git reset --har HEAD' \
    'git -c core.hookspath=/dev/null commit -m x' 'git commit --no-veri -m x' 'git clean --force -d' \
    'git checkout -f main' 'git switch --discard-changes main'; do
  guard 2 "$cmd"
done
# A git command on a later line is read whatever indents it: spaces, a tab (JSON carries it as \t), a
# carriage return, and a flag at the end of a line or a tab between the words is as much a flag as one before a space.
for cmd in $'cd x\n\tgit log --output=/tmp/probe.txt' $'cd x\n\t\tgit push --force origin main' $'cd x\n \tgit commit -nm x' \
    $'cd x\r\n\tgit branch -D topic' $'cd x\n  \t  git reset --hard' $'cd x\n\tgit\tworktree remove --force y' \
    $'git\tpush\t--force' $'git\tlog\t--output=/tmp/probe.txt' $'git push origin main --force\necho done' \
    $'git push origin main --force\r\necho done' $'git push origin main --force\n\tgit status' $'git clean -fd\necho done'; do
  guard 2 "$cmd"
done
for cmd in $'cd x\n\tgit log --oneline -3' $'cd x\n\t\tgit commit -m "fix a --force bug" -- a.gd' $'git\tlog\t--oneline' \
    $'git status\n\techo done' $'git push origin feature\necho done'; do
  guard 0 "$cmd"
done
guard_run
guard_report "$git_fail" "the guard hook doesn't block every destructive git command, on a later line, after a tab or before a line break, or it blocks a plain form" "the guard hook blocks the destructive git commands, on a later line, after a tab and before a line break, and passes the plain forms"
# -n and --no-verify skip the hooks, and a spelling that quotes or splits the flag is the flag: the quoted
# word, the quote inside it, an empty quote between its letters, a short flag inside a cluster, the long flag
# abbreviated, a backslash and a line break inside it, and the words of a later line. After -- come paths.
for cmd in "git commit '-n' -m x" 'git commit "-n" -m x' 'git commit -""n -m x' "git commit -a''n -m x" 'git commit -n"" -m x' \
    "git commit --no-ve''rify -m x" 'git commit "--no-verify" -m x' 'git commit --no-v -m x' 'git commit --no-verif -m x' \
    $'git commit --no-ver\\\nify -m x' $'git commit -\\\nn -m x' "git commit -m x '-n'" 'git commit -m x "--no-verify"' \
    $'cd x\n\tgit commit "-n" -m x' $'cd x\n\tgit commit -m x --no-ve\'\'rify' 'git commit -am x "-n"' "git commit -m x --amend '--no-verify'"; do
  guard 2 "$cmd"
done
for cmd in 'git commit -m x -- -nx.gd' 'git commit -m "a -n b" -- a.gd' 'git commit --amend --no-edit' 'git commit --no-post-rewrite -m x' \
    "git commit -m 'fix the n handling' -- a.gd" 'git commit -a -m x' 'git commit -F - --no-status'; do
  guard 0 "$cmd"
done
guard_run
guard_report "$git_fail" "the guard hook doesn't block every quoted, split or abbreviated -n and --no-verify, or it blocks a path after --" "the guard hook blocks -n and --no-verify however they are quoted, split or abbreviated, and passes a path after --"
# A prototype's worktree is removed with `git worktree remove` and its branch deleted by the human
# (prototype.md), so the ways to discard a worktree's changes or a branch's commits stay with the human in
# every spelling: forced removal, forced or unmerged deletion, overwrites, an unquoted brace expansion or
# $IFS, past git's global options.
for cmd in \
    'git branch -D proto/quick-add' \
    'git worktree remove --force ../market-day-proto-quick-add' \
    'git worktree remove --forc ../x' \
    'git worktree remove --f ../x' \
    "git worktree remove '--force' ../x" \
    'git worktree remove ../market-day-proto-quick-add -f' \
    'git worktree remove -ff ../x' \
    'git -C ../market-day worktree remove --fo ../x' \
    'git branch -d -f proto/quick-add' \
    'git branch --delete --force proto/quick-add' \
    'git branch --del --forc proto/quick-add' \
    'git branch -df proto/quick-add' \
    'git branch -qD proto/quick-add' \
    'git worktree remove --{force,} x' \
    'git worktree remove -{f,f} x' \
    'git worktree remove x$IFS--force' \
    'git worktree remove x${IFS}--force' \
    'git branch -{D,} x' \
    'git branch -{d..f} x' \
    'git --git-dir .git worktree remove --forc x' \
    'git --work-tree . branch -df x' \
    'git --config-env x=Y worktree remove -f x' \
    'git branch -M a b' \
    'git branch -C a b' \
    'git branch -m -f a b' \
    'git branch --move --force a b' \
    'git branch -cf a b' \
    'git worktree add -B proto/x ../x main' \
    'git worktree add -f ../x proto/x' \
    'git worktree add --forc ../x proto/x'; do
  guard 2 "$cmd"
done
for cmd in \
    'git worktree add --no-track -b proto/quick-add ../market-day-proto-quick-add main' \
    'git worktree remove ../market-day-proto-quick-add' \
    'git branch -d proto/quick-add' \
    'git branch -f topic main' \
    'git branch -uorigin/feature-dev' \
    'git commit -m "git branch -d -f x"' \
    'git log HEAD@{1}' \
    'git log --oneline @{u}..HEAD' \
    'git diff stash@{0}' \
    'git branch -m old new' \
    'git branch -c old new' \
    'git commit -m "a {b,c} message"' \
    'bash tools/prototype.sh start quick-add' \
    'bash tools/prototype.sh remove quick-add'; do
  guard 0 "$cmd"
done
# The same rules in the PowerShell tool, in a substitution, in a wrapper's script and on a continued line, with
# --pathspec-from-file beside them.
for cmd in 'git branch -D x' 'git worktree remove --force x' 'git worktree add -B x ../x' 'git restore --pathspec-from-file=x'; do
  guard 2 "$cmd" PowerShell
  guard 2 "Write-Output \$($cmd)" PowerShell
  guard 2 "echo \$($cmd)"
  guard 2 "bash -c '$cmd'"
done
for cmd in $'git branch `\n-D x' $'git worktree remove `\n--force x' $'git worktree add `\n-B x ../x' $'git restore `\n--pathspec-from-file=x'; do
  guard 2 "$cmd" PowerShell
done
for cmd in $'git branch \\\n-D x' $'git worktree remove \\\n--force x' $'git worktree add \\\n-B x ../x' $'git restore \\\n--pathspec-from-file=x' \
    $'# note\\\ngit branch -D x'; do
  guard 2 "$cmd"
done
for cmd in 'git branch -d x' 'git worktree remove ../x' 'git worktree add -b x ../x main' 'git restore a.gd'; do
  guard 0 "$cmd" PowerShell
done
guard_run
guard_report "$git_fail" "the guard hook doesn't block every forced worktree removal, branch deletion or overwrite, in Bash and PowerShell, or it blocks a plain form" "the guard hook blocks forced worktree removal, branch deletion and overwrites in every spelling, in Bash and PowerShell, in a substitution, a wrapper and on a continued line, and passes the plain forms"
# settings.json no longer asks before `git restore` and `git checkout --`, so the guard keeps every
# whole-tree form with the human: the pathspecs of the whole tree, quoted or not, --pathspec-from-file,
# a git restore that names no file, and git on a later line of the command.
for cmd in 'git restore' 'git restore --staged' 'git restore --source=HEAD~3' 'git restore --source HEAD~3 .' \
    'git restore -s HEAD :/' 'git restore -- .' 'git restore ./' 'git restore "*"' "git restore ':(top)'" \
    'git restore --pathspec-from-file=list.txt' 'git checkout -- :/' "git checkout -- '.'" 'git checkout HEAD -- *' \
    'git checkout --pathspec-from-file=list.txt' 'git -C sub restore .' $'echo start\ngit push --force' \
    $'cat <<EOF\nhi\nEOF\ngit commit -nm x' $'cat <<EOF\n$(git commit -n -m x)\nEOF' \
    $'cat <<\'EOF\'\nnever closed\ngit commit -nm x'; do
  guard 2 "$cmd"
done
for cmd in 'git status --short' 'git commit -m "feat: x (T12)" -- a.gd' 'git commit --amend --no-edit' \
    'git push origin feature-flag' 'git restore --staged a.gd' 'git checkout -b topic' 'bash tools/check.sh' \
    'git commit -m "docs: grep -n usage" -- a.md' "git commit -m 'fix: handle -f flag' -- a.gd" \
    'git reset --soft HEAD~1' 'git switch main'; do
  guard 0 "$cmd"
done
# The single-file forms run without a prompt now, and a heredoc body is data: a script body that says
# "commit" and later " -len (x)" isn't git commit -n (The Guildkeeper hit this). The body goes to node here: the guard blocks a
# Python that reads its script from a heredoc, whatever the body (the cases for it are with the hang cases below).
for cmd in 'git restore a.gd' 'git checkout -- scripts/systems/market.gd' 'git restore --source=HEAD~1 scripts/a.gd' \
    'git restore -s HEAD~1 -- scripts/a.gd' 'git restore --staged scripts/a.gd && git checkout -- scripts/a.gd' \
    "git commit -m 'docs: git restore . is blocked' -- a.md" 'git commit -m "docs: git checkout -- * is blocked" -- a.md' \
    $'node - <<\'EOF\'\n# commit totals per day\nx = -len (rows)\nEOF' \
    $'node - <<EOF\n# commit totals per day\nx = -len (rows)\nEOF' \
    $'cd x && node - <<-PY\n\t# commit totals\n\ty = -n + 1\n\tPY\necho done' \
    $'git commit -q -F - <<\'EOF\'\nfix: handle -n in the parser\nEOF'; do
  guard 0 "$cmd"
done
for cmd in $'python3 - <<\'EOF\'\n# commit totals per day\nx = -len (rows)\nEOF' \
    $'python3 - <<EOF\n# commit totals per day\nx = -len (rows)\nEOF' \
    $'cd x && python3 - <<-PY\n\t# commit totals\n\ty = -n + 1\n\tPY\necho done'; do
  guard 2 "$cmd"
done
for cmd in 'git restore ":(top)"' "git checkout -- '*'" 'git restore .' 'git restore'; do
  guard 2 "$cmd" PowerShell
done
guard 0 'git restore README.md' PowerShell
# Git for Windows reads a backslash in a pathspec as a slash, so .\ is the top folder, as ./ is; ./. and ./* are the whole tree too.
for cmd in "git restore '.\\'" "git checkout -- '.\\'" 'git restore .\' 'git restore ./.' "git restore './.'" 'git checkout -- ./.' \
    "git restore '.\\.'" 'git restore "./*"'; do
  guard 2 "$cmd" PowerShell
done
for cmd in "git restore '.\\'" "git checkout -- '.\\'" 'git restore ./.' 'git checkout -- "./."' 'git restore "./*"'; do
  guard 2 "$cmd"
done
for cmd in 'git restore ./a.gd' "git restore '.\\a.gd'" 'git checkout -- ./scripts/x.gd'; do
  guard 0 "$cmd"; guard 0 "$cmd" PowerShell
done
guard_run
guard_report "$git_fail" "the guard hook doesn't block every whole-tree restore or checkout, or it blocks a single-file form or a heredoc body that is data" "the guard hook blocks the whole-tree restore and checkout forms, quoted or not, and passes the single-file forms and heredoc bodies that are data"
asks="$(sed -n '/"ask": \[/,/\]/p' .claude/settings.json)"
if printf '%s' "$asks" | grep -q 'git restore' || printf '%s' "$asks" | grep -q 'git checkout'; then
  bad "settings.json no longer asks before git restore and git checkout --" "$asks"
elif printf '%s' "$asks" | grep -q '"Bash(git push \*)"' && printf '%s' "$asks" | grep -q '"Bash(git rebase \*)"' \
    && printf '%s' "$asks" | grep -q '"Bash(git -c \*)"' && printf '%s' "$asks" | grep -q '"Bash(git config \*)"'; then
  ok "settings.json asks before push, rebase, -c and config, and not before a single-file restore or checkout"
else
  bad "settings.json keeps asking before push, rebase, -c and config" "$asks"
fi

# The wildcard git allow rules (`git diff *`, `git log *`, `git show *`, `git commit *`) take any
# flag, and some flags write a file (--output), read a file outside the repository (--no-index,
# commit -F and --file, a `git diff` of a path outside it) or run a configured command (--ext-diff),
# with no prompt. The hook reads the command as the shell hands it to git, so a flag that is quoted,
# escaped, attached to a short option or hidden behind another command is still seen, and a flag
# named inside a commit message or a heredoc body is not. The deny rules in settings.json cover the
# plain forms; the hook covers the rest, and commit -F, where a rule can't tell `-F <path>` from
# `-F -` (the docs repo's security assessment, product/security/2026-10-29.md, F1).
for cmd in \
    'git log -1 --format=probe --output=/tmp/probe.txt' \
    'git log --output /tmp/probe.txt' \
    'git show --output /tmp/probe.txt HEAD' \
    'git diff --output=probe.txt' \
    'git stash show --output=/tmp/probe.txt' \
    "git log '--output=/tmp/probe.txt'" \
    'git log "--no-index"' \
    'git log --out\put=/tmp/probe.txt' \
    'git log --output="/tmp/my probe.txt"' \
    'git diff --no-index a b' \
    'git diff --no-index /dev/null /etc/hosts' \
    'git log -p --ext-diff' \
    'git diff --ext-diff' \
    'git diff /etc/hosts README.md' \
    'git diff ../other.txt README.md' \
    'git commit -F /tmp/msg.txt' \
    'git commit -F/tmp/msg.txt' \
    'git commit -aF /tmp/msg.txt' \
    'git commit -F "/tmp/my msg.txt"' \
    'git commit --file /tmp/msg.txt' \
    'git commit --file=/tmp/msg.txt' \
    'git commit -F - -F /tmp/msg.txt' \
    'git add -A && git commit -F /tmp/msg.txt' \
    'git -C work/Godot-Director log --output=/tmp/probe.txt' \
    $'git commit -q -F - <<\'EOF\'\nmsg\nEOF\ngit log --output=/tmp/probe.txt'; do
  guard 2 "$cmd"
done
for cmd in \
    'git log --oneline -5' \
    'git diff HEAD' \
    'git diff --cached --stat' \
    'git diff origin/main..HEAD -- docs/index.md' \
    'git show HEAD:README.md' \
    'git commit -m "fix the --output handling"' \
    'git commit -F -' \
    'git commit --file=-' \
    $'git commit -q -F - <<\'EOF\'\nfix the --output and --no-index handling, not -F /tmp/x\nEOF' \
    'git stash list' \
    'git worktree list'; do
  guard 0 "$cmd"
done
guard_run
guard_report "$git_fail" "the guard hook doesn't block every git flag that writes a file, reads outside the repository or runs a configured command, or it blocks a plain form" "the guard hook blocks the git flags that write a file, read outside the repository or run a configured command, and passes the plain forms"
# The settings template has to deny those flags next to its wildcard git rules, since the deny rules
# are the harness's own layer under the hook. Tested on planted settings, so a change that stops the
# check flagging a missing rule fails here.
git_deny_missing() { # git_deny_missing <settings file>: the deny rules it lacks, when it allows a wildcard git rule
  local rule deny
  sed -n '/"allow": *\[/,/\]/p' "$1" | grep -qE '"Bash\(git (diff|log|show|stash|commit) \*\)"' || return 0
  deny="$(sed -n '/"deny": *\[/,/\]/p' "$1")"
  for rule in 'Bash(git *--output*)' 'Bash(git *--no-index*)' 'Bash(git *--ext-diff*)' 'Bash(git commit *--file*)'; do
    printf '%s\n' "$deny" | grep -qF "\"$rule\"" || printf '%s\n' "$rule"
  done
}
if [ ! -f "$settings" ]; then
  bad "the settings template is missing, so its git deny rules can't be checked"
elif [ -n "$(git_deny_missing "$settings")" ]; then
  bad "the settings template allows a wildcard git rule but doesn't deny these (git flags that write or read any file):" "$(git_deny_missing "$settings")"
else
  ok "the settings template denies git's file-writing, file-reading and external-command flags next to its wildcard git rules"
fi
git_planted=""
printf '{\n  "permissions": {\n    "allow": [\n      "Bash(git diff *)"\n    ],\n    "deny": [\n      "Read(.env)"\n    ]\n  }\n}\n' > "$work/git-deny-none.json"
[ "$(git_deny_missing "$work/git-deny-none.json" | wc -l | tr -d ' ')" = 4 ] || git_planted="$git_planted none"
for git_rule in 'git log' 'git show' 'git stash' 'git commit'; do
  printf '{\n  "permissions": {\n    "allow": [\n      "Bash(%s *)"\n    ],\n    "deny": [\n      "Bash(git *--output*)"\n    ]\n  }\n}\n' \
    "$git_rule" > "$work/git-deny-one.json"
  [ "$(git_deny_missing "$work/git-deny-one.json" | wc -l | tr -d ' ')" = 3 ] || git_planted="$git_planted $git_rule"
done
printf '{\n  "permissions": {\n    "allow": [\n      "Bash(git status)",\n      "Bash(git add *)"\n    ]\n  }\n}\n' > "$work/git-deny-no-wildcard.json"
[ -z "$(git_deny_missing "$work/git-deny-no-wildcard.json")" ] || git_planted="$git_planted no-wildcard"
[ -z "$git_planted" ] && ok "the git deny check flags each missing deny rule, and passes settings with no wildcard git rule" \
  || bad "the git deny check misses a planted case:$git_planted"

# Hangs: a Python that reads its script from a heredoc, unbounded waits, a Godot run without a time limit, a long sleep.
out="$(printf '{"tool_name":"Bash","tool_input":{"command":"timeout 600 godot --headless --script run_one.gd"}}' | bash .claude/hooks/guard-git.sh 2>&1)"
expect_output "the Godot-run refusal points to the supported way to run one test file" 'bash tools/check\.sh --only tests/<file>\.gd' "$out"
for cmd in $'python3 - <<\'EOF\' 2>/dev/null || echo "no python"\nEOF' $'python - <<EOF\nEOF' \
    $'py.exe - <<-"EOF"\n  EOF  ' $'python3 - <<\'EOF\' 2>/dev/null || python - <<\'EOF2\'\nEOF\nprint(1)\nEOF2' \
    $'cd x && python3 - <<EOF\nEOF\necho done' \
    $'python3 - <<\'EOF\'\nprint("hi")\nEOF' $'python3 - <<EOF\nimport sys\nEOF' \
    'until grep -q "^exit" /tmp/t/tasks/b1.output; do sleep 5; done' 'until [ -f done ]; do sleep 5; done' \
    'while true; do sleep 10; done' 'timeout 600 bash -c "until [ -f x ]; do sleep 5; done"' \
    'timeout 5m bash -c "until [ -f x ]; do sleep 5; done"' \
    '"$GODOT_BIN" --headless --path . --script run_tests.gd' \
    'G=$(cat tools/godot_bin.local); "$G" --headless --path . --script run_tests.gd' \
    '/c/tools/Godot_v4.7.2-stable_win64_console.exe --headless --import' 'godot --headless --script x.gd' \
    'timeout 300 "$GODOT_BIN" --headless --script x.gd' 'sleep 300' 'sleep 6m' 'echo wait && sleep 1h'; do
  guard 2 "$cmd"
done
for cmd in 'python3 --version 2>/dev/null || echo "no python"' \
    'timeout 240 bash -c "until [ -f x ]; do sleep 5; done"' '(timeout 4m bash -c "while [ ! -f x ]; do sleep 2; done")' \
    'cd x && timeout 280s bash -c "until [ -f x ]; do sleep 5; done"' \
    'until grep -q "exited with code" /tmp/t/tasks/b1.output; do sleep 5; done' \
    'until grep -qE "exited with code|\[killed\]" /tmp/t/tasks/b1.output; do sleep 5; done' \
    'sleep 5' 'sleep 280' 'sleep 4m' \
    'timeout 120 "$GODOT_BIN" --headless --path . --script run_tests.gd' \
    'G=$(cat tools/godot_bin.local); timeout 120 "$G" --headless --path . --script run_tests.gd' \
    'G=$(cat tools/godot_bin.local) && (timeout 2m "$G" --headless --import)' \
    'timeout 60 /c/tools/Godot_v4.7.2-stable_win64_console.exe --headless --import' \
    'bash tools/check.sh' 'bash tools/autoplay.sh smoke' 'bash tools/ui_capture.sh --list' \
    'git commit -m "docs: until loops with sleep 600 need a timeout; godot --headless too" -- a.md'; do
  guard 0 "$cmd"
done
# A Godot run is read in every reading of the command (Director-Driven-Development T278): behind a quoted path, on a continued
# line, in a wrapper's script, a substitution or a heredoc body a shell runs, and in the PowerShell tool. A message or a file
# body that names one is text, and a timeout of 280 seconds or less before the run, or above its wrapper, bounds it. The Godot
# path that tools/setup-clone.sh saves, G=$(cat tools/godot_bin.local), is read as $GODOT_BIN is (B45 reads any other
# variable as a command's name), so a git subcommand or a destructive flag after it is still blocked. A global option that takes a
# value (--git-dir, --work-tree, --namespace) takes the word after it, which is no subcommand, and the subcommand after that is
# judged (Director-Driven-Development T289).
for cmd in \
    'G=$(cat tools/godot_bin.local); $G push --force' \
    'G=$(cat tools/godot_bin.local); "$G" --force' \
    'G=$(cat tools/godot_bin.local); "$G" --work-tree . restore .' \
    'G=$(cat tools/godot_bin.local); "$G" --git-dir .git branch -D x' \
    'G=$(cat tools/godot_bin.local); "$G" --namespace x restore .' \
    'G=$(cat tools/godot_bin.local); "$G" --config-env x=Y worktree remove -f x' \
    'G=$(cat tools/godot_bin.local); timeout 60 "$G" commit -m x' \
    'G=$(cat x.txt); timeout 120 "$G" --headless --import' \
    'G=$(cat tools/godot_bin.local); G=$(cat x); timeout 60 "$G" --headless --import' \
    'G=$(cat tools/godot_bin.local; cat x); timeout 60 "$G" --headless --import' \
    'G=$(cat tools/godot_bin.local) && "$G" --headless --script x.gd' \
    'bash -c "G=\$(cat tools/godot_bin.local); timeout 60 \$G --headless --import"' \
    'timeout 300 godot --headless --import' \
    'godot --import' \
    'Godot_v4.7.2-stable_win64_console.exe --headless --script x.gd' \
    'bash -c "godot --headless --script x.gd"' \
    'timeout 600 bash -c "godot --headless --script x.gd"' \
    'eval "godot --headless --import"' \
    'echo $(godot --headless --script x.gd)' \
    'timeout 60 echo "$(godot --headless --script x.gd)"' \
    $'bash <<\'EOF\'\ngodot --headless --import\nEOF' \
    '"C:/Program Files/Godot/godot.exe" --headless --import' \
    $'godot \\\n--headless --import' \
    'cd x && GODOT_BIN=/x/godot "$GODOT_BIN" --headless --import' \
    'git commit -m x && sleep 600' \
    'git commit -m "godot --headless" && godot --headless --import'; do
  guard 2 "$cmd"
done
for cmd in \
    '& "C:\Tools\Godot_v4.7.2-stable_win64_console.exe" --headless --import' \
    '& $env:GODOT_BIN --headless --script x.gd' \
    $'godot `\n--headless --import'; do
  guard 2 "$cmd" PowerShell
done
for cmd in \
    'G="$(cat tools/godot_bin.local)"; timeout 60 "$G" --headless --import' \
    'G=$(head -n 1 tools/godot_bin.local); timeout 60 "$G" --headless --import' \
    'G=$(cat tools/godot_bin.local); timeout 2m "$G" --version' \
    'G=$(cat tools/godot_bin.local); timeout 120 "$G" --headless --script tests/run.gd' \
    'timeout 240 bash -c "godot --headless --script x.gd"' \
    'timeout 120 "C:/Program Files/Godot/godot.exe" --headless --import' \
    'git commit -m "run godot --headless under timeout" -- a.md' \
    $'git commit -q -F - <<\'EOF\'\nfix: godot --headless --script x.gd needs a timeout\nEOF' \
    $'cat > notes.md <<\'EOF\'\ngodot --headless --import\nEOF' \
    'echo "godot --headless --import"' \
    'grep -n -- --headless README.md' \
    'bash tools/check.sh --only tests/test_market.gd'; do
  guard 0 "$cmd"
done
guard 0 'Write-Output "godot --headless"' PowerShell
# Godot's name in any case and as the downloads and packages spell it: Godot, godot.EXE, godot4, the Windows, Linux and macOS
# builds, the Flatpak, and $GODOT_BIN or $env:godot_bin in any case.
for cmd in \
    'Godot --headless --import' \
    'godot.EXE --headless --import' \
    'GODOT --headless --script x.gd' \
    '/Applications/Godot.app/Contents/MacOS/Godot --headless --import' \
    './Godot_v4.6-stable_linux.x86_64 --headless --import' \
    'Godot_v4.7.2-stable_win64.exe --headless --script x.gd' \
    'godot4 --headless --import' \
    'flatpak run org.godotengine.Godot --headless --import' \
    '"$godot_bin" --headless --script x.gd'; do
  guard 2 "$cmd"
done
for cmd in \
    '& $env:godot_bin --headless --script x.gd' \
    '& $env:GODOT_BIN --headless --script x.gd' \
    'Godot --headless --import' \
    '& "C:\Godot\Godot_v4.6-stable_win64_console.exe" --headless --import'; do
  guard 2 "$cmd" PowerShell
done
for cmd in \
    'timeout 120 /Applications/Godot.app/Contents/MacOS/Godot --headless --import' \
    'timeout 60 ./Godot_v4.6-stable_linux.x86_64 --headless --import' \
    'cd framework/.godot-director && grep -n -- --script rules.md' \
    'git commit -m "Godot --headless needs a timeout"'; do
  guard 0 "$cmd"
done
# A wait loop with a loop nested in it runs to its own done (the do and done of each inner loop are counted), and a sleep
# count with a fraction is read to the millisecond.
for cmd in \
    'while true; do for f in a b; do :; done; sleep 5; done' \
    'while true; do while read l; do :; done < f; sleep 5; done' \
    $'until false\ndo\n  for f in a; do echo $f; done\n  sleep 5\ndone' \
    'while true; do for f in a; do :; done;sleep 9;done' \
    'for ((;;)); do until true; do :; done; sleep 1; done' \
    'sleep 600.5' 'sleep 280.5' 'sleep 4.7m' 'echo x; sleep 300.0'; do
  guard 2 "$cmd"
done
for cmd in \
    'while read l; do for f in a; do :; done; done < x; sleep 5' \
    'for f in a b; do while read l; do :; done < f; done' \
    'timeout 240 bash -c "while true; do for f in a; do :; done; sleep 5; done"' \
    'sleep 0.5' 'sleep 280.0' 'sleep 4.5m' 'sleep 1.'; do
  guard 0 "$cmd"
done
for cmd in 'Start-Sleep -Seconds 600.5' 'Start-Sleep 280.5' 'Start-Sleep -Milliseconds 280000.5'; do guard 2 "$cmd" PowerShell; done
for cmd in 'Start-Sleep -Seconds 0.5' 'Start-Sleep -Milliseconds 280000.0'; do guard 0 "$cmd" PowerShell; done
# A loop that polls a background command's tasks/<id>.output waits for its end marker under any timeout and any wrapper:
# bash with options before -c, and PowerShell's while and do { } while.
for cmd in \
    "timeout 240 bash -e -c 'until grep -q x tasks/b1.output; do sleep 5; done'" \
    "timeout 240 bash --norc -c 'until grep -q x tasks/b1.output; do sleep 5; done'" \
    "timeout 240 bash -c 'until grep -q x tasks/b1.output; do sleep 5; done'" \
    'timeout 240 bash -c "until grep -q x \"/tmp/t/tasks/b1.output\"; do sleep 5; done"'; do
  guard 2 "$cmd"
done
for cmd in \
    'timeout 240 pwsh -c "while (-not (Select-String -Quiet x tasks/b1.output)) { Start-Sleep 5 }"' \
    'do { Start-Sleep 5 } while (-not (Select-String -Quiet x tasks/b1.output))'; do
  guard 2 "$cmd" PowerShell
done
for cmd in \
    "timeout 240 bash -c 'until grep -q \"exited with code\" tasks/b1.output; do sleep 5; done'" \
    'git commit -m "poll tasks/b1.output while you wait" -- a.md' \
    'cat tasks/b1.output'; do
  guard 0 "$cmd"
done
guard_run
guard_report "$git_fail" "the guard hook doesn't block every hang (a Python that reads its script from a heredoc, an unbounded wait, a Godot run without a time limit, a long sleep), or it blocks a bounded form" "the guard hook blocks a Python that reads its script from a heredoc, an unbounded wait, a Godot run without a time limit and a long sleep, in every reading of the command, and passes the bounded forms"

# A Python that reads its script from a heredoc (Director-Driven-Development T309, which closes B64): the guard blocks python, python3,
# python3.13, pythonw and py (with or without .exe, bare or behind a path, quoted or not) when the script comes from a heredoc or a
# here-string, whatever the body, with a time limit above it or not. The older rule saw only an empty body on the next line, so a quoted
# multi-line string after the header (B64) hid the form. A script file fed data from a heredoc, -c, -m and --version pass, and so does a
# message, a quoted echo or grep, or a cat body that names the form. Each blocked case also checks that the refusal names Python, in the
# Bash and the PowerShell tool both.
out="$(printf '{"tool_name":"Bash","tool_input":{"command":"python3 - <<EOF\\nprint(1)\\nEOF"}}' | bash .claude/hooks/guard-git.sh 2>&1)"
expect_output "the refusal of a Python heredoc says why" 'python reading its script from a heredoc can hang: on Windows it can wait for console input and never return\.' "$out"
expect_output "and names the forms that work" 'Write the script to a file with Write and run it \(python3 script\.py\), use python3 -c for one line, and run python3 --version to test whether Python is there\.' "$out"
py_msg='python reading its script from a heredoc can hang'
py_block() { # py_block <command>...: each command is blocked in the Bash and the PowerShell tool, with a refusal that names Python
  local c t
  for c in "$@"; do for t in Bash PowerShell; do guard 2 "$c" "$t" "$py_msg"; done; done
}
py_pass() { # py_pass <command>...: each command passes in the Bash and the PowerShell tool
  local c t
  for c in "$@"; do for t in Bash PowerShell; do guard 0 "$c" "$t"; done; done
}
# The interpreter's names: python, python3, any minor version, pythonw and py, with or without .exe, in any case, bare, behind a path
# with forward or back slashes, or quoted.
py_block \
    $'python - <<\'E\'\nprint(1)\nE' $'python3 - <<\'E\'\nprint(1)\nE' $'python3.13 - <<E\nprint(1)\nE' $'pythonw - <<E\nprint(1)\nE' \
    $'py - <<E\nprint(1)\nE' $'python.exe - <<E\nprint(1)\nE' $'py.exe - <<E\nprint(1)\nE' $'python3.13.exe - <<E\nprint(1)\nE' \
    $'PYTHON3 - <<E\nprint(1)\nE' $'/usr/bin/python3 - <<E\nprint(1)\nE' $'~/.venv/Scripts/python.exe - <<E\nprint(1)\nE' \
    $'C:\\Python313\\python.exe - <<E\nprint(1)\nE' $'C:/Python313/python.exe - <<E\nprint(1)\nE' \
    $'"C:/Program Files/Python313/python.exe" - <<E\nprint(1)\nE' $'\'C:\\Program Files\\Python313\\python.exe\' - <<E\nprint(1)\nE' \
    $'"python3" - <<E\nprint(1)\nE' $'\'py\' - <<E\nprint(1)\nE'
# With the - or without it, with interpreter options before it, and an empty body too.
py_block \
    $'python <<\'E\'\nprint(1)\nE' $'python3 <<E\nprint(1)\nE' $'python3 -u - <<E\nprint(1)\nE' $'python3 -X utf8 - <<E\nprint(1)\nE' \
    $'py -3 - <<E\nprint(1)\nE' $'python3 -W ignore - <<E\nprint(1)\nE' $'python3 -u -X utf8 - <<E\nprint(1)\nE' $'python3 -u <<E\nprint(1)\nE' \
    $'python3 - <<\'EOF\'\nEOF' $'python3 - <<EOF\n\nEOF'
# Each heredoc form, and a here-string.
py_block \
    $'python3 - <<E\nprint(1)\nE' $'python3 - <<\'E\'\nprint(1)\nE' $'python3 - <<"E"\nprint(1)\nE' $'python3 - <<\\E\nprint(1)\nE' \
    $'python3 - <<-E\n\tprint(1)\n\tE' $'python3 - << E\nprint(1)\nE' \
    $'python - <<<\'print(1)\'' $'python <<<"print(1)"' $'python3 - <<<$X'
# Behind a wrapper or in a chain, with a time limit above it (no bound is shown to stop it through the Windows Store alias), and after
# an assignment, a redirect or a separator.
py_block \
    $'timeout 60 python - <<E\nprint(1)\nE' $'timeout 5 "C:/Program Files/Python313/python.exe" - <<E\nprint(1)\nE' \
    $'env X=1 python - <<E\nprint(1)\nE' $'FOO=1 python3 - <<E\nprint(1)\nE' $'PYTHONPATH="a b" python3 - <<E\nprint(1)\nE' \
    $'uv run python - <<E\nprint(1)\nE' $'nohup python3 - <<E\nprint(1)\nE' $'cd x && python - <<E\nprint(1)\nE' \
    $'python3 tool.py && python3 - <<E\nprint(1)\nE' $'if true; then python3 - <<E\nprint(1)\nE\nfi' $'echo hi\npython3 - <<E\nprint(1)\nE' \
    $'python3 - <<E 2>/dev/null || true\nprint(1)\nE' $'python3 - 2>/dev/null <<E\nprint(1)\nE' $'python3 - <<E 2>&1\nprint(1)\nE' \
    $'python3 - <<E | tee out.txt\nprint(1)\nE' $'python3 - <<E &\nprint(1)\nE' 'x=$(python3 - <<<"print(1)")'
# Piped in from a heredoc or a here-string.
py_block \
    $'cat <<\'E\' | python -\nprint(1)\nE' $'cat <<E | python3\nprint(1)\nE' $'cat <<E | tr a b | python3 -\nprint(1)\nE' \
    $'x=1 && cat <<E | python3 -\nprint(1)\nE' 'echo $(cat <<<x | python3)'
# Inside a heredoc body that a shell runs, and inside a script given to a shell.
py_block \
    $'bash <<\'X\'\npython3 - <<\'E\'\nprint(1)\nE\nX' $'bash <<X\npython3 - <<\'E\'\nprint(1)\nE\nX' \
    $'cat > x.sh <<\'E\'\npython3 - <<\'X\'\nprint(1)\nX\nE\nbash x.sh' $'bash -c "python3 - <<\'E\'\nprint(1)\nE"'
# B64: the empty body after a quoted multi-line string. The quoted string closes on the second line, so the shell starts the heredoc's
# body after it and the body is empty; the older rule took the line after the header as the body and never reached the delimiter.
py_block \
    $'python3 - <<\'E\' 2>/dev/null || node -e "\nx()"\nE' $'python3 - <<\'E\' 2>/dev/null || node -e "\nconsole.log(1)\n"\nE'
# A comment with an apostrophe before the header pairs with nothing after its line.
py_block \
    $'# what\'s here\npython3 - <<\'E\'\nprint(1)\nE' $'ls  # it\'s\npython3 - <<\'E\'\nprint(1)\nE'
# A continuation: a backslash joins the lines in Bash, a backtick in PowerShell.
guard 2 $'python3 \\\n- <<\'EOF\'\nprint(1)\nEOF' Bash "$py_msg"
guard 2 $'python3 \\\n- <<\'EOF\'\nEOF' Bash "$py_msg"
guard 2 $'python3 `\n- <<\'EOF\'\nprint(1)\nEOF' PowerShell "$py_msg"
guard 2 $'python3 `\n- <<\'EOF\'\nEOF' PowerShell "$py_msg"
# PowerShell's here-string piped in, in the form of a single or a double quote, behind a path, an option or the call operator.
for cmd in \
    $'@\'\nprint(1)\n\'@ | python -' $'@"\nprint(1)\n"@ | python' $'@\'\nprint(\'it\')\n\'@ | python -' $'@\'\nprint(1)\n\'@ | py -3 -' \
    $'@\'\nprint(1)\n\'@ | & "C:\\Program Files\\Python313\\python.exe" -' $'@\'\nprint(1)\n\'@ | python3.13' \
    $'$s = 1\n@\'\nprint(1)\n\'@ | python -' $'@\'\nprint(1)\n\'@ | python - | Out-File x.txt'; do
  guard 2 "$cmd" PowerShell "$py_msg"
done
# A script file fed data from a heredoc, -c and -m with or without a heredoc of data, and --version pass, and so do the same forms
# with the interpreter's options, a quoted script name and a pipe.
py_pass \
    $'python tool.py <<\'E\'\ndata\nE' $'python3 tool.py --flag <<E\ndata\nE' $'python3 -u tool.py <<E\ndata\nE' $'py -3 tool.py <<E\ndata\nE' \
    $'python3 "my tool.py" <<E\ndata\nE' $'python3 -X utf8 tool.py <<E\ndata\nE' $'python3 -x tool.py <<E\ndata\nE' \
    $'python3 -c "import sys; print(sys.stdin.read())" <<\'E\'\ndata\nE' $'python -m json.tool <<E\n{}\nE' $'python3 -Im json.tool <<E\n{}\nE' \
    $'python3 -c \'print(1)\' <<<"data"' 'python -c "print(1)"' 'python -m pytest -q tests/' 'python3 --version' 'py -3 --version' \
    'python3 --version 2>/dev/null || echo "no python"' 'python3 tool.py' 'python3 tool.py --flag' $'python3 - < script.py' \
    $'cat <<\'E\' | python3 tool.py\ndata\nE' $'cat <<E | python -c "import sys"\ndata\nE' $'cat <<E | python -m json.tool\n{}\nE' \
    $'cat <<E | grep python\ndata\nE' 'cat file | python3' $'python3 tool.py && python3 - < in.py'
for cmd in \
    $'@\'\nprint(1)\n\'@ | python -c "import sys"' $'@\'\nprint(1)\n\'@ | python x.py' $'@\'\nprint(1)\n\'@ | python -m json.tool' \
    $'@\'\nprint(1)\n\'@ | Set-Content x.py; python x.py' $'@\'\nprint(1)\n\'@ | Set-Content x.py\npython x.py' \
    $'@\'\npython3 - <<\'E\' is blocked\n\'@ | Set-Content doc.md' $'@"\nuse python3 - <<E never\n"@ | Set-Content doc.md'; do
  guard 0 "$cmd" PowerShell
done
# A message, a quoted echo or grep, and a cat or tee body nothing runs may name the form. A heredoc whose delimiter is PY writes a
# file, and a word py or python that isn't a command (a package, a pattern, a path) is no interpreter.
py_pass \
    $'git commit -q -F - <<\'E\'\nfix: python3 - <<\'X\' is blocked\nE' $'git commit -q -F - <<E\nfix: python3 - <<X is blocked\nE' \
    $'git tag -a v1 -F - <<\'E\'\npython3 - <<\'X\'\nE' $'gh pr create --body-file - <<\'E\'\nUse python3 - <<\'X\' never\nE' \
    $'gh pr create --title t --body "$(cat <<\'E\'\npython3 - <<\'X\'\nE\n)"' \
    'git commit -m "docs: python3 - <<\"E\" is blocked" -- a.md' "git commit -m 'docs: python3 - <<\"E\" is blocked' -- a.md" \
    $'echo "python3 - <<\'E\'"' $'echo \'python3 - <<"E"\'' 'grep -n "python3 - <<" rules.md' "grep -rn 'python - <<' ." 'printf "%s\n" "python <<E"' \
    $'cat > notes.md <<\'E\'\npython3 - <<\'X\'\nprint(1)\nX\nE' $'tee notes.md <<\'E\'\npython3 - <<X\nprint(1)\nX\nE' \
    $'cat > run.py <<\'PY\'\nprint(1)\nPY' $'cat > x.py <<PY\nprint(1)\nPY' $'cat > x.py <<-PY\n\tprint(1)\n\tPY' $'cat > x.py << PY\nprint(1)\nPY' \
    $'cat > x.py <<"PY"\nprint(1)\nPY' $'cat > x.py <<\\PY\nprint(1)\nPY' $'git commit -q -F - <<\'PY\'\nfix\nPY' \
    'ls tools/*.py' 'pip install python-dotenv' 'cp a.py b.py' 'pytest tests' 'git add tools/usage.py' 'pip list | grep -i python' \
    'which python3' 'command -v python3' 'docker run python:3.12 --version' \
    $'# python3 - <<\'E\' is blocked\nls' $'ls # python3 - <<E\nls' 'echo python <<<foo' $'grep python <<<"$x"' $'psql <<\'SQL\'\nselect \'python\'\nSQL'
guard_run
guard_report "$git_fail" "the guard hook doesn't block a Python that reads its script from a heredoc or a here-string, or it blocks a script file fed data, -c, -m, a message that names the form, or a heredoc whose delimiter is PY" "the guard hook blocks python, python3, py and pythonw reading their script from a heredoc or a here-string, whatever the body, bounded by a timeout or not (B64's form too), says so, and passes a script file fed data from a heredoc, -c, -m, --version and a message that names the form"

# A Python with nothing to run (Director-Driven-Development B66): python3 -, python or py -3 with no script, no -c, no -m and nothing
# fed to it waits for input that never comes, so it is blocked bare, with options, behind a path, a quote or a wrapper, in a chain,
# with a time limit above it or a redirect after it, in the Bash and the PowerShell tool, and the refusal names it. A file fed to it
# (python3 - < x.py), a pipe into it, a script file, -c, -m, --version and the like, and text that names Python (command -v python3,
# pip install python, a quoted message) pass.
bare_msg='python with no script'
for cmd in \
    'python3 -' \
    'python' \
    'py -3' \
    'python3 2>/dev/null || true' \
    'python3 - 2>/dev/null; sed -n 1p x' \
    'python -' \
    'python3' \
    'pythonw' \
    'python3.13 -' \
    'python.exe' \
    'py' \
    'py -3.13' \
    'PYTHON3' \
    'Python.EXE -' \
    '/usr/bin/python3 -' \
    'C:/Python313/python.exe -' \
    'C:\Python313\python.exe' \
    '"C:/Program Files/Python313/python.exe" -' \
    $'\'/usr/bin/python3\' -' \
    'python3 -u' \
    'python3 -u -' \
    'python3 -X utf8' \
    'python3 -Xutf8 -' \
    'python -W ignore -' \
    'python3 -B -E' \
    'cd x && python3 -' \
    'cd x; python3 -' \
    'false || python3 -' \
    'python3 - && echo ok' \
    'python3 - | tee log' \
    'python3 2>&1 | head' \
    'python3 - &' \
    'python3 >out.txt' \
    'python3 > out.txt 2>&1' \
    'python3 &> out.txt' \
    'timeout 60 python3 -' \
    'timeout -k 5 60 python3 -' \
    'timeout 2m python' \
    'env python3 -' \
    '/usr/bin/env python3 -' \
    'env X=1 python3 -' \
    'X=1 python3 -' \
    'PYTHONPATH="a b" python3 -' \
    'sudo python3 -' \
    'nohup python3 -' \
    'nice -n 5 python3 -' \
    'time python3 -' \
    'exec python3 -' \
    'command python3 -' \
    'winpty python' \
    'uv run python' \
    'poetry run python3 -' \
    'if python3 -; then echo x; fi' \
    'x=$(python3 -)' \
    '(python3 -)' \
    '{ python3 -; }' \
    '! python3 -' \
    'echo "a"; python3 -; echo "b"' \
    $'echo \'a\'; python3 -; echo \'b\'' \
    $'cd x\npython3 -\necho done' \
    'python3 -c "print(1)"; python3 -' \
    'cat x | head; python3 -' \
    'bash -c "python3 -"' \
    'eval "python3 -"' \
    $'python3 \\\n  -' \
    $'python3 \\\n  -u \\\n  -' \
    $'timeout 60 \\\n  python3 -' \
    $'# note \\\npython3 -' \
    $'cat <<E | head\nx\nE\npython3' \
    $'bash <<\'X\'\npython3 -\nX'; do
  guard 2 "$cmd" Bash "$bare_msg"
done
for cmd in \
    'python -' \
    'python' \
    'python | Out-Null' \
    'python 2>$null' \
    'python *> $null' \
    '& python -' \
    '& python.exe' \
    'py -3' \
    'Set-Location x; python -' \
    $'python `\n  -' \
    $'echo \'a\'; python -; echo \'b\''; do
  guard 2 "$cmd" PowerShell "$bare_msg"
done
for cmd in \
    'python3 - < x.py' \
    'python3 < x.py' \
    'python3 -u - < x.py' \
    'python3 - </dev/null' \
    'cat x.py | python3 -' \
    'cat x.py | python3' \
    'cat x | timeout 60 python3 -' \
    'git show HEAD:x.py | python3 -' \
    'cat x |& python3 -' \
    'python3 --version' \
    'python --version 2>&1' \
    'python3 -V' \
    'python3 -VV' \
    'python3 -h' \
    'python3 --help' \
    'python3 --help-env' \
    'python -?' \
    'py --list' \
    'py --list-paths' \
    'py -0' \
    'py -0p' \
    'py -V:3.13 x.py' \
    'python3 -c "print(1)"' \
    'python3 -c print' \
    'python -m pytest' \
    'python3 -mpytest' \
    'python3 -um pip list' \
    'python3 -Bc "x"' \
    'python3 x.py' \
    'python3 tool.py --flag' \
    'python -I script.py' \
    'python3 -u x.py' \
    'python3 -X utf8 x.py' \
    'python3 -Xdev x.py' \
    'python -W ignore x.py' \
    'py -3 x.py' \
    'py -3 -c "x"' \
    'py install 3.13' \
    'python3 "$f"' \
    'python3 $f' \
    'python3 "x y.py"' \
    'python3 $(ls x.py)' \
    'if python3 --version; then echo x; fi' \
    'command -v python' \
    'command -V python3' \
    'command -v python3 >/dev/null || echo no' \
    'which python3' \
    'where python' \
    'where.exe python' \
    'type python' \
    'type -p python3' \
    'hash python' \
    'pip install python' \
    'winget install python' \
    'brew install python' \
    'apt install python3' \
    'choco install python' \
    'echo python' \
    'echo python3 -' \
    'printf "%s" python' \
    'grep -rn python .' \
    'rg python' \
    'ls python' \
    'cd python' \
    'mkdir py' \
    'cat py' \
    'git add python' \
    'git log --grep python' \
    'case "$x" in python) echo y ;; esac' \
    'PY=python3' \
    'PY="python3"' \
    'PY=python3; $PY x.py' \
    'export PY=python3' \
    'export PY="python3"' \
    'x=$(command -v python3)' \
    '[ -x python ]' \
    'test -f python' \
    'git commit -m "python3 -"' \
    $'git commit -m \'run python\'' \
    'echo "a; python3 -; b"' \
    'gh pr view 1 --json body -q .body' \
    'find . -name "*.py" -exec python3 {} \;' \
    'ls *.py | xargs python3' \
    'xargs python3' \
    'python3 <(cat x.py)' \
    'sed -n "/python/p" x' \
    'node -e "python"' \
    $'git commit -m "a\npython\nb"' \
    $'echo \'x\npython3 -\ny\'' \
    $'cat > x.sh <<\'E\'\npython3 -\nE' \
    $'git commit -F - <<\'E\'\npython\nE' \
    $'python3 \\\n  tool.py' \
    $'python3 \\\n  tool.py --flag \\\n  --other' \
    $'python3 \\\n  -c "print(1)"' \
    $'python3 -u \\\n  x.py' \
    $'timeout 60 \\\n  python3 tool.py' \
    $'python3 \\\n  - < x.py' \
    $'cat x.py | \\\n  python3 -' \
    $'cat x.py |\n  python3 -' \
    $'# note \\\npython3 tool.py' \
    $'python3 tool.py <<\'PY\'\ndata\nPY' \
    $'python3 tool.py <<PY\ndata\nPY' \
    $'node x.js <<-PY\n\tdata\n\tPY' \
    $'ruby x.rb <<"python"\ndata\npython' \
    $'gh pr create --title t --body-file - <<\'E\'\npython3 -\nE'; do
  guard 0 "$cmd"
done
for cmd in \
    'Get-Content x.py -Raw | python -' \
    'Get-Command python' \
    '(Get-Command python).Source' \
    'gcm python' \
    'Write-Output python' \
    'Write-Host python' \
    'python --version' \
    $'python -c \'print(1)\'' \
    'python x.py' \
    'Start-Process python' \
    $'python `\n  x.py' \
    $'python `\n  -c \'print(1)\'' \
    $'Get-Content x.py -Raw |\n  python -' \
    'if (Get-Command python -ErrorAction SilentlyContinue) { python --version }'; do
  guard 0 "$cmd" PowerShell
done
guard_run
guard_report "$git_fail" "the guard hook passes a Python with no script, no -c, no -m and nothing fed to it, or blocks one that has a script, a file or a pipe fed to it, or text that names Python (B66)" "the guard hook blocks a Python with nothing to run, bare, behind a path, a quote or a wrapper, in a chain, in the Bash and the PowerShell tool, and passes one that has a script, a file or a pipe fed to it, and text that names Python (B66)"

# A command name written as a path (Director-Driven-Development T293): a quoted name with a space in its path, or an unquoted backslash
# path that starts with a drive, ., .., ~ or two backslashes, is read as its last part (git.exe is git) in the Bash and the PowerShell
# tool, after an assignment, a wrapper, a separator or a call operator. A quoted path that is an argument, a message or a body nothing
# runs is text, an escaped name (c\at) is still the shell's name, and the Godot path under a timeout still passes.
for cmd in \
    '"C:\Program Files\Git\bin\git.exe" push --force' \
    "& 'C:\\Program Files\\Git\\bin\\git.exe' push --force" \
    'C:\Git\bin\git.exe push --force' \
    '"C:\Program Files\Git\cmd\git.exe" push --force' \
    'FOO=1 "C:\Program Files\Git\bin\git.exe" push --force' \
    'env "C:\Program Files\Git\bin\git.exe" push --force' \
    'cd x && "C:\Program Files\Git\bin\git.exe" push --force' \
    'true; C:\Git\bin\git.exe push --force' \
    'echo $("C:\Program Files\Git\bin\git.exe" push --force)' \
    'timeout 60 "C:\Program Files\Git\bin\git.exe" push --force' \
    '"C:\Program Files\Git\bin\git.exe" -C x push --force' \
    '"C:\Program Files\Git\bin\git.exe" reset --hard' \
    '"C:\Program Files\Git\bin\git.exe" restore .' \
    '"C:\Program Files\Git\bin\git.exe" branch -D x' \
    '"C:\Program Files\Git\bin\git.exe" commit -m x --no-verify' \
    '..\bin\git.exe push --force' '~\bin\git.exe push --force' '\\server\share\git.exe push --force' \
    "bash -c '\"C:\\Program Files\\Git\\bin\\git.exe\" push --force'" \
    ". 'C:\\Git\\bin\\git.exe' push --force"; do
  guard 2 "$cmd"
  guard 2 "$cmd" PowerShell
done
guard 2 $'bash <<\'EOF\'\n"C:\\Program Files\\Git\\bin\\git.exe" push --force\nEOF'
for cmd in \
    "& 'C:\\Program Files\\Git\\bin\\git.exe' status" \
    '"C:\Program Files\Git\bin\git.exe" log -1' \
    '"C:\Program Files\Git\bin\git.exe" push origin main' \
    'git commit -q -m "docs: C:\Program Files\Git\bin\git.exe push --force is blocked"' \
    'echo "C:\Program Files\Git"' \
    'echo "C:\Program Files\Git\bin\git.exe push --force"' \
    'git log "C:\Program Files\Git\bin\git.exe"' \
    'git log --format="C:\Git\bin\git.exe push --force"' \
    'cp "C:\x y\git.exe" backup' \
    'c\at README.md' \
    'timeout 120 "C:\Tools\Godot_v4.7.2-stable_win64_console.exe" --headless --script x.gd' \
    'git commit -q -m "docs: a quoted C:\Tools\Godot_v4.7.2-stable_win64_console.exe needs a timeout" -- a.md'; do
  guard 0 "$cmd"
  guard 0 "$cmd" PowerShell
done
guard 0 $'cat > notes.md <<\'EOF\'\n"C:\\Program Files\\Git\\bin\\git.exe" push --force\nEOF\ngit add notes.md'
guard 0 $'git commit -q -F - <<\'EOF\'\ndocs: "C:\\Program Files\\Git\\bin\\git.exe" push --force is blocked\nEOF'
# The same paths in front of git's -c and program flags and in front of a shell (Director-Driven-Development T294): the name is its last
# part without .exe in any case, quoted with a space, as a backslash path, with forward slashes, behind a prefix, so the rules that read
# git's options and the shell wrapper's script judge them as they do the bare names.
for cmd in \
    '"C:\Program Files\Git\bin\git.exe" -c core.pager=calc log' \
    'C:\Git\bin\git.exe -c core.pager=calc log' \
    '"C:/Program Files/Git/bin/git.exe" -c core.pager=calc log' \
    '"C:\Program Files\Git\bin\GIT.EXE" -c core.sshCommand=calc fetch' \
    'env "C:\Program Files\Git\bin\git.exe" -c core.pager=calc log' \
    '..\bin\git.exe -c core.pager=calc log' \
    '\\server\share\git.exe -c core.pager=calc log' \
    '"C:\Program Files\Git\bin\git.exe" fetch --upload-pack=calc origin' \
    '"C:\Program Files\Git\bin\git.exe" ls-remote --upload-pack calc origin' \
    'C:\Git\bin\git.exe push --receive-pack=calc origin' \
    '"C:\Program Files\Git\bin\git.exe" clone -u calc u' \
    '"C:\Program Files\Git\bin\bash.exe" -c "git push --force"' \
    'C:\Git\bin\bash.exe -c "git push --force"' \
    '"C:\Program Files\Git\bin\sh.exe" -c "git reset --hard"' \
    'C:\Git\usr\bin\sh.exe -c "git push --force"' \
    '/c/Git/bin/BASH.EXE -c "git push --force"' \
    '"C:/Program Files/Git/bin/bash.exe" -c "git push --force"' \
    'C:/Git/bin/bash.exe -c "git push --force"' \
    '"C:\Program Files\Git\bin\BASH.EXE" -c "git push --force"' \
    '"C:\Program Files\Git\bin\zsh.exe" -c "git push --force"' \
    'env "C:\Program Files\Git\bin\bash.exe" -c "git push --force"' \
    'timeout 5 C:\Git\bin\bash.exe -c "git push --force"' \
    'x && C:\Git\bin\bash.exe -lc "git push --force"' \
    '..\bin\bash.exe -c "git push --force"' \
    '\\server\share\bash.exe -c "git push --force"' \
    '~\bin\sh.exe -c "git push --force"'; do
  guard 2 "$cmd"
  guard 2 "$cmd" PowerShell
done
for cmd in \
    '"C:\Program Files\Git\bin\git.exe" -c user.name=x log' \
    '"C:\Program Files\tool\app.exe" -c x' \
    'C:\tools\app.exe -c "git push --force"' \
    'echo "C:\Program Files\Git\bin\bash.exe -c foo"' \
    'echo "C:\Program Files\Git\bin\git.exe -c core.pager=calc log"' \
    'cp "C:\Program Files\Git\bin\bash.exe" backup' \
    'ls C:\Git\bin\bash.exe' \
    'C:\Windows\System32\notepad.exe C:\Git\bin\bash.exe -c foo' \
    'git log "C:\Program Files\Git\bin\bash.exe" -c' \
    'git commit -q -m "docs: C:\Program Files\Git\bin\git.exe -c core.pager=calc log is blocked"' \
    '"C:\Program Files\Git\bin\bash.exe" -c "echo hi"' \
    'C:\Git\bin\bash.exe tools/check.sh'; do
  guard 0 "$cmd"
  guard 0 "$cmd" PowerShell
done
for cmd in \
    '"C:\Tools\Godot_v4.7.2-stable_win64_console.exe" --headless --script x.gd' \
    '"C:\Tools\Godot_v4.7.2-stable_win64_console.exe" --headless --import' \
    "& 'C:\\Tools\\Godot_v4.7.2-stable_win64_console.exe' --headless --script x.gd"; do
  guard 2 "$cmd"
  guard 2 "$cmd" PowerShell
done
guard_run
guard_report "$git_fail" "the guard hook doesn't read a command name written as a path, quoted with a space or as a backslash path, so git passes behind it, or it blocks a path that is an argument, a message, a body nothing runs or the Godot path under a timeout" "the guard hook blocks git behind a quoted path with a space, a backslash path, an assignment, a wrapper, a separator, a call operator and a substitution, in the Bash and the PowerShell tool, and a heredoc body a shell runs, and passes the paths that are arguments and messages, an escaped name and the Godot path under a timeout"

# The credential stores: shell reads of ~/.ssh, git's credentials files and the gh CLI's config folders,
# and the commands that print a stored credential. A command that names a store without reading it, or
# reads a name that only ends in ssh, passes, and so do two commands on separate lines.
for cmd in 'cat ~/.ssh/id_ed25519' 'head "$HOME/.git-credentials"' 'cat ~/.config/gh/hosts.yml' \
    'less "/c/Users/V/AppData/Roaming/GitHub CLI/hosts.yml"' 'cat "C:\Users\V\.ssh\id_rsa"' \
    'tail -n 5 "${HOME}/.config/git/credentials"' 'strings .ssh/known_hosts' \
    'gh auth token' 'gh auth status -t' \
    "printf 'protocol=https\\nhost=github.com\\n' | git credential fill" \
    "printf 'protocol=https\\nhost=github.com\\n' | git credential get"; do
  guard 2 "$cmd"
done
for cmd in 'cat README.md' 'cat framework/.godot-director/rules.md' 'cat notes/x.ssh' \
    'grep -n ssh framework/.godot-director/rules.md' 'git log --oneline -3' 'ls ~/.ssh' 'gh auth status' \
    $'cat README.md\necho ~/.ssh'; do
  guard 0 "$cmd"
done
# A commit's or gh message, and a cat body nothing runs, may name the commands that print a credential; a body a shell runs, an
# unquoted message's substitution and a command after a message are read.
for cmd in \
    $'git commit -q -F - <<\'EOF\'\nfix: gh auth token is blocked\nEOF' \
    $'git commit -q -F - <<\'EOF\'\ndocs: git credential fill prints a token\nEOF' \
    $'gh pr edit 5 --body-file - <<\'EOF\'\nThe guard blocks gh auth token and git credential get.\nEOF' \
    $'cat > notes.md <<\'EOF\'\ngh auth token\nEOF'; do
  guard 0 "$cmd"
done
for cmd in \
    $'bash <<\'EOF\'\ngh auth token\nEOF' \
    $'git commit -q -F - <<EOF\n$(gh auth token)\nEOF' \
    $'git commit -q -F - <<\'EOF\'\nmsg\nEOF\ngh auth token' \
    $'cat > x.sh <<\'EOF\'\ngit credential fill\nEOF\nbash x.sh'; do
  guard 2 "$cmd"
done
guard_run
guard_report "$git_fail" "the guard hook doesn't block every shell read of a credential store or command that prints a stored credential, or it blocks an ordinary read" "the guard hook blocks shell reads of the credential stores and the commands that print a stored credential, and passes ordinary reads"
# The Read tool is the harness's own layer, and a Read rule doesn't reach a shell command, so the
# settings template denies the Read tool the same stores. Tested on planted settings, so a check that
# stops flagging a missing rule fails here.
read_deny_missing() { # read_deny_missing <settings file>: the Read deny rules it lacks
  local rule deny
  deny="$(sed -n '/"deny": *\[/,/\]/p' "$1")"
  for rule in 'Read(~/.ssh/**)' 'Read(~/.git-credentials)' 'Read(~/.config/git/credentials)' \
      'Read(~/.config/gh/**)' 'Read(~/AppData/Roaming/GitHub CLI/**)'; do
    printf '%s\n' "$deny" | grep -qF "\"$rule\"" || printf '%s\n' "$rule"
  done
}
read_planted=""
printf '{\n  "permissions": {\n    "deny": [\n      "Read(.env)"\n    ]\n  }\n}\n' > "$work/read-deny-none.json"
[ "$(read_deny_missing "$work/read-deny-none.json" | wc -l | tr -d ' ')" = 5 ] || read_planted=" none"
if [ ! -f "$settings" ]; then
  bad "the settings template is missing, so its Read deny rules can't be checked"
elif [ -n "$(read_deny_missing "$settings")" ]; then
  bad "the settings template doesn't deny the Read tool these credential stores:" "$(read_deny_missing "$settings")"
elif [ -n "$read_planted" ]; then
  bad "the Read deny check misses a planted case:$read_planted"
else
  ok "settings.json denies the Read tool the SSH folder, git's credentials and the gh CLI's config folders"
fi

# The hook runs under macOS's bash 3.2 too (CLAUDE.md > Scripts), so it holds no bash 4 form: case conversion (${x,,}, ${x^^}),
# an associative array, mapfile or readarray, coproc, |&, or a negative substring offset (${x: -1}). Comment lines are skipped.
bash4=$(grep -nE '^[^#]*(\$\{[A-Za-z_0-9]+(\[[^]]*\])?(,,|\^\^)\}|(declare|local|typeset) +-[a-zA-Z]*A|(^|[;&| ])(mapfile|readarray) +|(^|[;&| ])coproc +[A-Za-z]|[[:space:]]\|&[[:space:]]|\$\{[A-Za-z_0-9@*]+(\[[^]]*\])?: -[0-9])' .claude/hooks/guard-git.sh || true)
if [ -z "$bash4" ]; then ok "the guard hook uses no bash 4 form, so it runs under bash 3.2"
else bad "the guard hook uses a bash 4 form (bash 3.2 on macOS has none)" "$bash4"; fi
# bash 3.2 keeps the quotes of a quoted replacement string (${t//x/"$y"}), so the hook replaces text with str_swap, which quotes none.
bash43=$(grep -nE '^[^#]*\$\{[A-Za-z_0-9]+(\[[^]]*\])?//?("[^"]*"|[^/"}]+)/"' .claude/hooks/guard-git.sh || true)
if [ -z "$bash43" ]; then ok "the guard hook quotes no replacement string, which bash 3.2 would keep"
else bad "the guard hook quotes a replacement string (bash 3.2 keeps the quotes)" "$bash43"; fi

# The guard starts no other process (it runs on every Bash, Monitor and PowerShell call, and a process start is slow on Windows). With no
# PATH only a builtin can run, so "command not found" in its output names a process it tried to start. A spread of the cases that
# reach most of its rules (credential reads, wrappers, substitutions, loops, a Godot run, heredocs, git flags) is run that way.
nopath_fail=""
for cmd in \
    'git push origin main --force' 'git commit -m x --no-verify' $'git commit -q -F - <<\'EOF\'\nmsg\nEOF' 'git log --output=/tmp/x' \
    'git -c core.pager=x log' 'git branch -df x' 'git worktree remove --force x' 'GIT=git; $GIT push --force' 'git restore' \
    'cat ~/.git-credentials' 'cat ~/.ssh/id_rsa' 'Get-Content ~/.ssh/id_rsa' 'gh auth token' 'bash -c "git push --force"' 'eval "cat ~/.ssh/id_rsa"' \
    'echo $(git push --force)' 'git push "$(echo --force)"' $'git commit \\\n-n -m x' $'# note\\\ngit push --force' \
    'until test -f x; do sleep 1; done' 'sleep 300' 'for ((i=0;i<9;i++)); do sleep 1; done' $'python3 - <<\'EOF\'\nEOF' \
    $'python3 -X utf8 - <<EOF\nprint(1)\nEOF' $'cat <<E | python -\nx\nE' $'@\'\nprint(1)\n\'@ | python -' $'python3 tool.py <<EOF\ndata\nEOF' \
    'godot --headless --script x.gd' 'G=$(cat tools/godot_bin.local); timeout 60 "$G" --headless --import' \
    'Invoke-Expression "git push --force"' $'cat <<EOF | bash\ngit push --force\nEOF' 'git status' 'ls'; do
  json_str "$cmd"
  for tool in Bash PowerShell; do
    printf '{"session_id":"s","tool_name":"%s","tool_input":{"command":"%s","description":"run"}}' "$tool" "$JSON_STR" > "$guard_dir/nopath.json"
    err=$(PATH=/nonexistent "$BASH" .claude/hooks/guard-git.sh < "$guard_dir/nopath.json" 2>&1 >/dev/null)
    case $err in *"command not found"*) nopath_fail="$nopath_fail"$'\n'"  ($tool) ${cmd//$'\n'/ NL }: ${err//$'\n'/ | }" ;; esac
  done
done
rm -f "$guard_dir/nopath.json"
guard_report "$nopath_fail" "the guard starts another process" "the guard starts no other process"

# The guard reads a long file body in time (the hook's timeout in settings.json is 10 seconds): a 25 KB GDScript of $Node.method()
# lines, written from a Bash heredoc and from a PowerShell here-string, in a UTF-8 locale, each under 5 seconds (about 0.4 and 1.2
# seconds in Git Bash on Windows). A third body, 25 KB of text that spells py on two lines in three, is data fed to a Python script
# (python3 tool.py <<'EOF'): the guard keeps that body, since a script may run it, and reads only the lines that hold a <<.
# Bash's time keyword reads the clock, so the measurement starts no process of its own.
guard_report "$slow_fail" "the guard is too slow on a long file body" "the guard reads a 25 KB GDScript heredoc and here-string, 25 KB of data fed to a Python script, and a 14 KB heredoc and here-string that name bash.exe and git.exe -c, in under 5 seconds each:${slow_times%,}"

# A variable in the hook's environment named like a per-view array (vhang, vcov, vdep, vpx, vps) changes nothing: the arrays start
# empty, so an exported vhang=1 doesn't skip the git rules.
env_fail=""
printf '%s' '{"session_id":"s","tool_name":"Bash","tool_input":{"command":"git push --force","description":"run"}}' > "$guard_dir/env.json"
for v in vhang vcov vdep vpx vps; do
  env "$v=1" bash .claude/hooks/guard-git.sh < "$guard_dir/env.json" >/dev/null 2>&1
  [ $? -eq 2 ] || env_fail="$env_fail"$'\n'"  with $v=1 in the environment the guard passes git push --force"
done
rm -f "$guard_dir/env.json"
guard_report "$env_fail" "a variable in the hook's environment changes what the guard blocks" "a variable in the hook's environment named like the guard's per-view arrays changes nothing"

# The guard's reading of a command, case by case (Director-Driven-Development T278; the B numbers are its bug IDs): the PowerShell
# tool, the readers of the credential stores, continuations (a backslash in Bash, a backtick in PowerShell, and the comments
# that end in one), tabs, command substitutions, variables, shell wrappers, wait loops, heredoc bodies, git configuration
# and program flags, quoted and capitalised names, and Invoke-Expression.
if [ ! -f .claude/settings.json ]; then
  bad ".claude/settings.json is missing, so the guard's wiring can't be checked"
else
  git_fail=""
  perm_allow=$(sed -n '/"allow": *\[/,/\]/p' .claude/settings.json)
  if [ ! -f .claude/hooks/guard-git.sh ]; then
    git_fail="$git_fail"$'\n'"  .claude/hooks/guard-git.sh is missing"
  else
    for cmd in \
        'git log -1 --format=probe --output=/tmp/probe.txt' \
        'git log --output /tmp/probe.txt' \
        'git show --output /tmp/probe.txt HEAD' \
        'git diff --output=probe.txt' \
        'git stash show --output=/tmp/probe.txt' \
        "git log '--output=/tmp/probe.txt'" \
        'git log "--no-index"' \
        'git log --out\put=/tmp/probe.txt' \
        'git log --output="/tmp/my probe.txt"' \
        'git diff --no-index a b' \
        'git diff --no-index /dev/null /etc/hosts' \
        'git log -p --ext-diff' \
        'git diff --ext-diff' \
        'git diff /etc/hosts README.md' \
        'git diff ../other.txt README.md' \
        'git commit -F /tmp/msg.txt' \
        'git commit -F/tmp/msg.txt' \
        'git commit -aF /tmp/msg.txt' \
        'git commit -F "/tmp/my msg.txt"' \
        'git commit --file /tmp/msg.txt' \
        'git commit --file=/tmp/msg.txt' \
        'git commit -F - -F /tmp/msg.txt' \
        'git add -A && git commit -F /tmp/msg.txt' \
        'git -C work/Godot-Director log --output=/tmp/probe.txt' \
        $'git commit -q -F - <<\'EOF\'\nmsg\nEOF\ngit log --output=/tmp/probe.txt' \
        'cat ~/.ssh/id_ed25519' \
        'head "$HOME/.git-credentials"' \
        'cat ~/.config/gh/hosts.yml' \
        'less "/c/Users/V/AppData/Roaming/GitHub CLI/hosts.yml"' \
        'cat "C:\Users\V\.ssh\id_rsa"' \
        'cat "~/.ssh/id_rsa"' \
        "head '.git-credentials'" \
        'cat .git-credentials' \
        'head ./.config/gh/hosts.yml' \
        'cat "config/.config/gh/hosts.yml"' \
        'less .config/git/credentials' \
        "tail '.git-credentials'" \
        'tail -n 20 .git-credentials' \
        'cat README.md; cat .git-credentials' \
        'cat README.md .git-credentials' \
        'tail -n 20 .git-credentials' \
        'head -5 ~/.ssh/id_rsa' \
        'cat docs/a.md "~/.ssh/id_ed25519"' \
        'less -R .config/gh/hosts.yml' \
        'gh auth token' \
        'gh auth status -t' \
        "printf 'protocol=https\\nhost=github.com\\n' | git credential fill" \
        "printf 'protocol=https\\nhost=github.com\\n' | git credential get" \
        $'cd x\ngit branch -D y' \
        $'cd x\ngit commit --no-verify -m x' \
        $'cd x\n\tgit log --output=/tmp/x' \
        $'echo a\ngit push --force' \
        $'cd x\ngit commit -F /tmp/msg.txt' \
        $'cd x\ngit credential fill' \
        "git commit '-n' -m x" \
        'git commit "-n" -m x' \
        'git commit -""n -m x' \
        "git commit --no-ve''rify -m x" \
        "git commit -m -- '-n'" \
        $'git commit \\\n-n -m x' \
        $'git push \\\n--force' \
        $'git push origin \\\n+main' \
        $'git reset \\\n--hard' \
        $'git credential \\\nfill' \
        $'git log \\\n--output=/tmp/probe.txt' \
        $'cat \\\n.git-credentials' \
        $'cat README.md \\\n.git-credentials' \
        $'cat\t.git-credentials' \
        $'head\t-n\t20\t.git-credentials' \
        $'git\tpush --force' \
        $'git\tcommit -n -m x' \
        $'git\tlog --output=/tmp/probe.txt' \
        $'echo a\\\\\ngit push --force' \
        $'echo a\\\\\ngit commit -F /tmp/msg.txt' \
        $'sleep \\\n300'; do
      guard 2 "$cmd"
    done
    for cmd in \
        'git log --oneline -5' \
        'git diff HEAD' \
        'git diff --cached --stat' \
        'git diff origin/main..HEAD -- docs/index.md' \
        'git show HEAD:README.md' \
        'git commit -m "fix the --output handling"' \
        'git commit -m x -- docs/index.md' \
        "git commit -m x -- '-n'" \
        'git commit -F -' \
        'git commit --file=-' \
        $'git commit -q -F - <<\'EOF\'\nfix the --output and --no-index handling, not -F /tmp/x\nEOF' \
        'git stash list' \
        'git worktree list' \
        'git log --grep -O' \
        'bash tools/check.sh' \
        'bash tools/prototype.sh start quick-add' \
        'bash tools/check.sh && git log origin/main..HEAD' \
        'cat README.md' \
        'cat docs/how-to/where.md' \
        'cat README.md' \
        'cat docs/notes.md' \
        'head project.godot' \
        'cat export_presets.cfg' \
        'cat README.md docs/x.md' \
        'tail -n 20 README.md' \
        'head -5 notes.txt' \
        'cat README.md docs/notes.md' \
        'grep -n ssh docs/how-to/trouble.md' \
        'git log --oneline -3' \
        'ls ~/.ssh' \
        'gh auth status' \
        $'git status\ngit log --oneline -3' \
        $'git status\ngit commit -q -F - <<\'EOF\'\nfix the --output and --no-index handling, not -F /tmp/x\nEOF' \
        $'git commit -q -F - <<\'EOF\'\nfix the -n flag, not a flag\nEOF' \
        'echo x\\ngit branch -D y' \
        $'git log \\\n--oneline -3' \
        $'git status \\\n-s' \
        $'git diff \\\nHEAD' \
        $'echo a\\\\\nls' \
        $'cat README.md \\\ndocs/x.md' \
        $'cat\tREADME.md' \
        $'git\tstatus'; do
      guard 0 "$cmd"
    done
    # PowerShell (B24): its input carries the command as tool_input.command, like Bash's, so the hook must
    # exit the same way on a PowerShell payload. These are the git flags the deny rules and the guard block.
    for cmd in \
        'git push --force' \
        'git commit --no-verify -m x' \
        'git reset --hard HEAD~1' \
        'git log --output=/tmp/probe.txt' \
        'git diff --no-index a b' \
        'git commit -F /tmp/msg.txt' \
        'cat .git-credentials'; do
      guard 2 "$cmd" PowerShell
    done
    for cmd in 'git status' 'git log --oneline -5' 'git diff HEAD'; do
      guard 0 "$cmd" PowerShell
    done
  fi
  guard_run
  guard_report "$git_fail" "git's file-writing, file-reading and external-command flags, or the credential stores, are not all blocked when a continuation, a tab or a later line splits them, or a plain form is blocked (B24, B25)" "the guard hook blocks git's file-writing, file-reading and external-command flags and the credential-store reads on a later line, a continued line or after a tab, in Bash and PowerShell, and passes the plain forms (B24, B25)"

  # The PowerShell readers of credential stores (B27): Get-Content and its aliases gc and type, Select-String
  # and sls, and [IO.File]::ReadAll... block a credential store in any case, as cat does, and so does a reader
  # inside a -Command or -c string. The same readers of ordinary files pass, and the checks run for the Bash
  # tool too, since the hook reads every tool's command the same way.
  git_fail=""
  if [ -f .claude/hooks/guard-git.sh ]; then
    for reader in 'Get-Content' 'gc' 'type' 'GET-CONTENT' 'Select-String -Pattern x' 'sls x' \
        'Get-Content -Path' 'Get-Content -LiteralPath'; do
      for target in '.git-credentials' '.git-credentials' '.git-credentials*' '~/.ssh/id_rsa' '~/.ssh/id_ed25519' \
          '$HOME\.ssh\id_rsa' '~/.config/gh/hosts.yml' '"$env:APPDATA\GitHub CLI\hosts.yml"'; do
        guard 2 "$reader $target" PowerShell
      done
    done
    for cmd in \
        "[IO.File]::ReadAllText('.git-credentials')" \
        '[System.IO.File]::ReadAllLines(".git-credentials")' \
        '[io.file]::readallbytes("~/.ssh/id_rsa")' \
        '[IO.File]::ReadLines("$HOME\.ssh\id_rsa")' \
        'Get-Content README.md; Get-Content .git-credentials' \
        'powershell -NoProfile -Command "Get-Content .git-credentials"' \
        'powershell -c "gc .git-credentials"' \
        'cmd /c "type .git-credentials"' \
        "bash -c 'cat .git-credentials'" \
        'bash -c "cat .git-credentials"' \
        'cat .git-credentials*' \
        '\cat .git-credentials' \
        'echo `cat .git-credentials`' \
        'type .git-credentials' \
        'gc .git-credentials'; do
      guard 2 "$cmd"
    done
    for cmd in \
        'Get-Content README.md' \
        'gc docs/index.md' \
        'Get-Content -Path docs/index.md' \
        'Get-Content -LiteralPath README.md' \
        'Select-String -Path docs/index.md -Pattern title' \
        'Get-Content README.md' \
        'gc docs/notes.md' \
        '[IO.File]::ReadAllText("docs/index.md")' \
        'Get-ChildItem ~/.ssh' \
        'powershell -NoProfile -Command "Get-Content README.md"' \
        'type git'; do
      guard 0 "$cmd" PowerShell
    done
    guard 0 'type git'
    guard 0 'type README.md'
  fi
  guard_run
  guard_report "$git_fail" "the guard hook doesn't block every read of a credential store, or blocks a read of an ordinary file (B27)" "the guard hook blocks the PowerShell and Bash readers of credential stores, in any case, and passes the readers of ordinary files"

  # PowerShell's backtick (B28): a backtick that ends a line continues it, so a flag or a read it splits is
  # blocked as the plain form is, and a benign continuation passes. An escaped backtick (``) and a backtick
  # followed by spaces don't continue. In Bash a backtick is command substitution, so the same text passes
  # there. A comment that ends in a backtick still shows the next line, which the joined text would hide.
  git_fail=""
  if [ -f .claude/hooks/guard-git.sh ]; then
    for cmd in \
        $'git push `\n--force' \
        $'git commit `\n-n -m x' \
        $'cat `\n.git-credentials' \
        $'cat README.md `\n.git-credentials' \
        $'git push `\r\n--force' \
        $'git push `\r--force' \
        $'git log `\n--output=/tmp/probe.txt' \
        $'git pu`\nsh --force' \
        $'cat .git-cre`\ndentials' \
        $'# note`\ngit push --force'; do
      guard 2 "$cmd" PowerShell
    done
    for cmd in \
        $'git log `\n--oneline -3' \
        $'git status `\n-s' \
        $'cat ``\n.git-credentials' \
        $'git push ``\n--force' \
        $'git push ` \n--force'; do
      guard 0 "$cmd" PowerShell
    done
    guard 0 $'cat README.md `\n.git-credentials'
  fi
  guard_run
  guard_report "$git_fail" "the guard hook doesn't treat a PowerShell backtick at a line's end as a continuation, or treats a Bash or an escaped one as one (B28)" "the guard hook blocks a flag or a read that a PowerShell backtick continuation splits, and passes the benign continuations and the escaped and Bash backticks (B28)"

  # A Bash comment that ends in a backslash (B31): Bash ends the comment at the line break, so the line after it is a
  # command of its own, and the guard reads it as written. A continued command after such a comment is read from its
  # own line on. A # inside a word (a#b) is no comment, so its continuation is joined, as Bash joins it. The hang
  # check reads a heredoc header joined to its interpreter (B29): python3 with - <<'EOF' on the next line, with a body or not.
  git_fail=""
  if [ -f .claude/hooks/guard-git.sh ]; then
    for cmd in \
        $'# note\\\ngit push --force' \
        $'# note\\\ngit commit --no-verify -m x' \
        $'git status # note\\\ngit push --force' \
        $'# a\\\ngit commit \\\n-F /tmp/msg.txt' \
        $'# a\\\ngit push \\\n--force' \
        $'# a\\\n# b\\\ngit push \\\n--force' \
        $'git push origin main#\\\n  --force' \
        $'python3 \\\n- <<\'EOF\'\nEOF' \
        $'python3 \\\n- <<\'EOF\'\nprint(1)\nEOF'; do
      guard 2 "$cmd"
    done
    for cmd in \
        $'# note\\\ngit status' \
        $'git status # note\\\n-s' \
        $'echo a#b\\\n--force' \
        $'python3 \\\ntool.py <<\'EOF\'\ndata\nEOF'; do
      guard 0 "$cmd"
    done
  fi
  guard_run
  guard_report "$git_fail" "the guard hook reads a command after a Bash comment that ends in a backslash as hidden, or blocks a benign one (B31, B29)" "the guard hook reads the line after a Bash comment that ends in a backslash, and the command continued after it, as Bash does (B31, B29)"

  # A PowerShell comment that ends in a backtick (B35): PowerShell ends the comment at the line break too, so the line after it
  # is a command of its own, and a continued command after it is read from its own line on, as for a Bash comment (B31). A CRLF
  # break is the same. A comment that ends in a backtick, followed by a plain command, passes.
  git_fail=""
  if [ -f .claude/hooks/guard-git.sh ]; then
    for cmd in \
        $'# note`\ngit commit `\n-F x' \
        $'# note`\r\ngit commit `\r\n-F x'; do
      guard 2 "$cmd" PowerShell
    done
    guard 0 $'# note`\ngit status' PowerShell
  fi
  guard_run
  guard_report "$git_fail" "the guard hook doesn't read a command after a PowerShell comment that ends in a backtick, or blocks a plain one (B35)" "the guard hook reads the command after a PowerShell comment that ends in a backtick, and the command continued after it, as PowerShell does (B35)"

  # A quoted or path-qualified reader, a backtick inside a word and a StreamReader (B30): the call operator with a
  # quoted name (& 'Get-Content' .git-credentials), a reader by its path (/bin/cat, cat.exe, the Management module's
  # Get-Content), a backtick escape that leaves a letter or a dot in a reader or a name (Get-Con`tent, .git-cre`dentials),
  # and the StreamReader constructors are read as the plain forms are. A reader in a string with a backtick-escaped
  # quote and an ordinary file pass. In PowerShell the escape also reaches the git flag rules (--fo`rce).
  git_fail=""
  if [ -f .claude/hooks/guard-git.sh ]; then
    for cmd in \
        "& 'Get-Content' .git-credentials" \
        '& "gc" .git-credentials' \
        ". 'type' .git-credentials" \
        "& 'Get-Content' -Path '.git-credentials'" \
        "Get-Content '.git-credentials'" \
        'Get-Con`tent .git-credentials' \
        'gc .git-cre`dentials' \
        'type `.git-credentials' \
        'C:\Git\usr\bin\cat.exe .git-credentials' \
        'Microsoft.PowerShell.Management\Get-Content .git-credentials' \
        '[System.IO.StreamReader]::new(".git-credentials")' \
        "[IO.StreamReader]::new('.git-credentials')" \
        "New-Object System.IO.StreamReader('.git-credentials')" \
        'New-Object -TypeName System.IO.StreamReader -ArgumentList .git-credentials' \
        'git push --fo`rce' \
        'Write-Output x; & "gc" .git-credentials'; do
      guard 2 "$cmd" PowerShell
    done
    for cmd in \
        '/bin/cat .git-credentials' \
        '/usr/bin/head -n 5 .git-credentials' \
        "'/bin/cat' .git-credentials" \
        '/usr/bin/tail -n 20 .config/gh/hosts.yml'; do
      guard 2 "$cmd"
    done
    for cmd in \
        "& 'Get-Content' README.md" \
        "& 'Get-Content' 'README.md'" \
        'Write-Output "say `"hi`" now"' \
        'Write-Output "run `"gc README.md`" next"' \
        "[System.IO.StreamReader]::new('docs/index.md')" \
        "New-Object System.IO.StreamReader('README.md')" \
        'Get-Con`tent README.md' \
        'cat.exe README.md'; do
      guard 0 "$cmd" PowerShell
    done
    for cmd in \
        '/bin/cat README.md' \
        '/usr/bin/head -n 5 README.md' \
        "'/bin/cat' README.md"; do
      guard 0 "$cmd"
    done
  fi
  guard_run
  guard_report "$git_fail" "the guard hook misses a quoted or path-qualified reader, a backtick inside a word or a StreamReader of a credential store (B30)" "the guard hook blocks a quoted or path-qualified reader, a backtick-escaped word and a StreamReader of a credential store, and passes the same readers of ordinary files (B30)"

  # The common file readers (B36): grep, sed, awk, sort, base64, xxd and the rest of the list in the hook print a
  # credential store as cat does, in Bash and in a PowerShell payload; a reader or a name split by quotes (ca''t, c"a"t)
  # is read as the shell runs it; [IO.File]::OpenText, OpenRead and Open read one. A pattern is an argument as well
  # (B27), so grep "\.git-credentials" and git grep .git-credentials are blocked, and ordinary files pass. A commit message
  # that names a reader, with no credential store after it, passes.
  git_fail=""
  if [ -f .claude/hooks/guard-git.sh ]; then
    for cmd in \
        'grep x .git-credentials' \
        'awk 1 .git-credentials' \
        'sed -n p .git-credentials' \
        'base64 .git-credentials' \
        'xxd .git-credentials' \
        'egrep x .git-credentials' \
        'fgrep -i x .config/gh/hosts.yml' \
        'rg x .git-credentials' \
        'gawk "{print}" .config/gh/hosts.yml' \
        'sort .git-credentials' \
        'uniq .git-credentials' \
        'cut -d= -f2 .git-credentials' \
        'nl .git-credentials' \
        'tac .git-credentials' \
        'rev .git-credentials' \
        'od -c .git-credentials' \
        'hexdump -C .git-credentials' \
        'diff .git-credentials README.md' \
        'cmp .git-credentials README.md' \
        '/usr/bin/grep x .git-credentials' \
        'grep -rn "\.git-credentials" docs/' \
        'git grep .git-credentials' \
        "ca''t .git-credentials" \
        'c"a"t .git-credentials' \
        "'ca'\"t\" .git-credentials" \
        'g""rep x .git-credentials' \
        'ba"se"64 .git-credentials' \
        'cat .git-cre'"''"'dentials' \
        'c'"'"'a'"'"'t .git-credentials'; do
      guard 2 "$cmd"
    done
    for cmd in \
        "[System.IO.File]::OpenText('.git-credentials')" \
        '[IO.File]::OpenRead(".git-credentials")' \
        "[System.IO.File]::Open('.git-credentials', 'Open', 'Read')" \
        '[io.file]::opentext("~/.ssh/id_rsa")' \
        '[IO.File]::OpenRead("$HOME\.ssh\id_rsa")' \
        '& "Get-Content" .git-credentials' \
        'Select-String -Path .git-credentials -Pattern x'; do
      guard 2 "$cmd" PowerShell
    done
    for cmd in \
        'grep x README.md' \
        'sed -n p docs/notes.md' \
        'awk 1 project.godot' \
        'base64 export_presets.cfg' \
        'xxd README.md' \
        'ca""t README.md' \
        'c"a"t docs/notes.md' \
        'grep -n "DATABASE_URL" src/' \
        'sed -n 1,5p docs/index.md' \
        'awk 1 docs/index.md' \
        'sort README.md' \
        'cut -c1-3 README.md' \
        'diff README.md docs/index.md' \
        'git grep TODO' \
        'git diff README.md' \
        'git commit -m "fix: sort the docs and grep notes"' \
        'git commit -m "docs: sed, awk and diff notes" -- docs/index.md' \
        'rev-parse --show-toplevel'; do
      guard 0 "$cmd"
    done
    for cmd in \
        "[System.IO.File]::OpenText('docs/index.md')" \
        '[IO.File]::OpenRead("README.md")' \
        "[System.IO.File]::Open('docs/index.md', 'Open')" \
        "[IO.File]::OpenText('README.md')"; do
      guard 0 "$cmd" PowerShell
    done
  fi
  guard_run
  guard_report "$git_fail" "the guard hook misses a common file reader, a reader or a name split by quotes, or an IO.File Open method of a credential store, or blocks an ordinary read (B36)" "the guard hook blocks grep, sed, awk, sort, base64, xxd and the other common readers, a reader or name split by quotes, and [IO.File]::OpenText, OpenRead and Open of a credential store, and passes the same readers of ordinary files (B36)"

  # A backslash that escapes an ordinary character in a Bash command is removed by the shell (B44): c\at is cat, and .git-cre\dentials
  # is .git-credentials, so the reader and the name are read as the shell runs them. An escaped backslash (\\) is one backslash, and a
  # backslash before a space stays, as the shell keeps the name one word. Windows paths and ordinary files pass, and PowerShell's
  # escape is the backtick (B30), so a backslash in a PowerShell payload is a path separator, not an escape.
  git_fail=""
  if [ -f .claude/hooks/guard-git.sh ]; then
    for cmd in \
        'c\at .git-credentials' \
        'he\ad .git-credentials' \
        'cat .git-cre\dentials' \
        'cat .git\-credentials' \
        'cat .git-c\redentials' \
        'c\a\t .git-credentials' \
        'ca\t .git-cre\dentials' \
        'sed -n p .git-cre\dentials' \
        'C\AT .git-credentials' \
        'c\at "config/.git-cre\dentials"' \
        'cat ~/.s\sh/id_rsa' \
        'cat C:\Users\V\.git-credentials' \
        'cat ~/.\ssh/id_rsa'; do
      guard 2 "$cmd"
    done
    for cmd in \
        'c\\at .git-credentials' \
        'cat .git-cre\\dentials' \
        'c\at README.md' \
        'cat C:\Users\V\README.md' \
        'cat C:\Users\V\docs\index.md' \
        'cat C:\repo\README.md' \
        'git commit -m "docs: c\at notes"'; do
      guard 0 "$cmd"
    done
    guard 0 'c\at .git-credentials' PowerShell
    guard 0 "bash -c 'c\at README.md'" PowerShell
    guard 0 "powershell -c \"c\at .git-credentials\"" PowerShell
    guard 2 "bash -c 'c\at .git-credentials'" PowerShell
    guard 2 'bash -c "cat .git-cre\dentials"' PowerShell
    guard 2 'type C:\x\.git-credentials' PowerShell
  fi
  guard_run
  guard_report "$git_fail" "the guard hook misses a backslash that escapes a character in a Bash credential read, or blocks an ordinary read or a PowerShell backslash (B44)" "the guard hook blocks a Bash credential read whose reader or name has a backslash that escapes a character (c\\at, .git-cre\\dentials), and passes ordinary files, Windows paths and a PowerShell backslash (B44)"

  # The credential-read check (B52): an escaped space in a store path (GitHub\ CLI is the gh CLI's folder, and the backslash-space is
  # the space in it); an ANSI-C string ($'...') in a reader's or a file's name, which is read as the shell reads it (\xHH, \NNN and the
  # common escapes), with an escape the guard can't decode (\u, \0) blocked as unjudgeable; and a PowerShell command's $(...), read as
  # a command of its own, so a Bash command in it that reads through a backslash (c\at) is blocked. PowerShell's backslash is no
  # escape (its escape is the backtick), so its store path passes as written (B44).
  git_fail=""
  if [ -f .claude/hooks/guard-git.sh ]; then
    for cmd in \
        'cat ~/AppData/Roaming/GitHub\ CLI/hosts.yml' \
        'cat ~/AppData/Roaming/GitHub\ CLI' \
        'cat "~/AppData/Roaming/GitHub\ CLI/hosts.yml"' \
        'cat ~/AppData/Roaming/Git\Hub\ CLI/hosts.yml' \
        "\$'\\x63at' .git-credentials" \
        "\$'\\143at' .git-credentials" \
        "cat \$'.git-cre\\x64entials'" \
        "cat \$'\\x2egit-credentials'" \
        "cat \$'\\x2e\\x67it\\x2dcredentials'" \
        "cat \$'\\x2egit-'\$'credentials'" \
        "cat \$'.git\\x2dcredentials' docs/index.md" \
        "cat ~/\$'\\x2essh'/id_rsa" \
        "cat \$'\\u0063at' .git-credentials" \
        "cat \$'\\0' README.md" \
        "echo \$(bash -c \$'c\\x61t .git-credentials')" \
        "echo \$(bash -c 'c\\at .git-credentials')" \
        "git log \$(bash -c 'c\\at .git-credentials')"; do
      guard 2 "$cmd"
    done
    for cmd in \
        "echo \$(bash -c 'c\\at .git-credentials')" \
        "echo \"\$(bash -c 'c\\at .git-credentials')\"" \
        "Write-Output \$(bash -c \"c\\at ~/.ssh/id_rsa\")"; do
      guard 2 "$cmd" PowerShell
    done
    for cmd in \
        'cat README.md docs/index.md' \
        "printf '%s' \$'\\e[31mred\\e[0m'" \
        "tr -d \$'\\r' < docs/index.md" \
        "cat \$'README\\56md'" \
        "cat \$'\\101\\x42C.md'" \
        "cat \$'README.md'" \
        "echo \"\$(bash -c 'c\\at README.md')\"" \
        "echo \$(bash -c 'echo hi')"; do
      guard 0 "$cmd"
    done
    for cmd in \
        'cat ~/AppData/Roaming/GitHub\ CLI/hosts.yml' \
        'Write-Output "$(Get-Content README.md)"' \
        'Write-Output "$(Get-Content README.md)"' \
        "Write-Output \"\$(bash -c 'c\\at README.md')\""; do
      guard 0 "$cmd" PowerShell
    done
  fi
  guard_run
  guard_report "$git_fail" "the guard hook misses an escaped space in a store path, an ANSI-C string in a reader's or a file's name, or a PowerShell command's substitution that reads a credential store, or blocks an ordinary read (B52)" "the guard hook blocks a credential read through an escaped space in a store path, an ANSI-C string in a name, and a PowerShell command's substitution, and passes an ANSI-C string that names no credential and the substitutions that read none (B52)"

  # A command substitution in a git command's words (B32): what it prints can be a flag, and the text it runs is a command
  # the guard can't see. The repro (git push $(echo --force) and its backtick form) is blocked as the plain flag is, in Bash
  # and PowerShell, and so is a substitution as the command name, or one that runs a non-reading command. A double-quoted
  # value that starts with fixed text, a commit's or tag's -m value and a read (git, date, cat, echo, printf) pass, as the
  # procedures use them. The text of a substitution is judged as a command of its own.
  git_fail=""
  if [ -f .claude/hooks/guard-git.sh ]; then
    for cmd in \
        'git push $(echo --force)' \
        'git push `echo --force`' \
        'git push "$(echo --force)"' \
        'git log $(echo --output=/tmp/x)' \
        'git log "$(echo --output=/tmp/x)"' \
        'git log "--output=$(echo /tmp/x)"' \
        'git log "--since=$(rm -rf x)"' \
        'git log -1 "$(date +%F)"' \
        'git log "x$(git push --force)"' \
        'git push $(git push --force)' \
        'git status && echo $(git push --force)' \
        'echo "$(git push --force)"' \
        'git log > >(git push --force)' \
        '$(echo git) push --force' \
        'git log $(echo git) push' \
        'git commit -m x "$(cat x)"' \
        'git commit -m "$(echo $(rm -rf x))"' \
        $'git commit -c -m "$(cat <<\'EOF\'\n--file=/tmp/x\nEOF\n)"' \
        $'git commit -m -m "$(cat <<\'EOF\'\n--file=/tmp/x\nEOF\n)"' \
        $'git commit -m "$(cat <<EOF\n$(git push --force)\nEOF\n)"' \
        $'git commit -m "$(cat x; git push --force)"' \
        $'git log \\\n$(echo --output=/tmp/x)' \
        'git push "--force"$(echo x)'; do
      guard 2 "$cmd"
    done
    for cmd in \
        'git push $(echo --force)' \
        'git push `echo --force`' \
        'git push "$(echo --force)"' \
        'git push (echo --force)' \
        'git push @(echo --force)' \
        '$(echo git) push --force' \
        'git log -- $(echo --output=/tmp/x)' \
        'git log "$(git push --force)"'; do
      guard 2 "$cmd" PowerShell
    done
    for cmd in \
        $'git commit -m "$(cat <<\'EOF\'\nfix the --output handling, and -F /tmp/x\nEOF\n)"' \
        $'git commit -a -m "$(cat <<\'EOF\'\nmsg one\n\nBody with `ticks` and $(vars) text\nEOF\n)" -- docs/index.md' \
        $'git commit -m "$(cat <<\'EOF\'\nmsg `git push --force` in a quoted heredoc\nEOF\n)" -- x' \
        $'git commit -m "$(cat <<EOF\nplain body\nEOF\n)"' \
        'git commit -m "$(git log -1 --format=%s)"' \
        'git commit -m "$(echo --file=/tmp/x)"' \
        'git tag -a "v$(cat VERSION)" -m "release"' \
        'git checkout -q -b "ddd/bundle-$(date +%F)" origin/main' \
        'git ls-remote --heads origin "ddd/bundle-$(date +%F)*"' \
        "git log --since=\"\$(date -d '7 days ago' +%F)\" --oneline" \
        'git log --format=%h -n 1 -- "docs/$(echo index).md"' \
        'test -z "$(git status --porcelain)"' \
        'echo "$r $(git -C work/$r describe --tags)"' \
        'for f in $(git diff --name-only); do echo "$f"; done' \
        'K=$(git rev-parse HEAD); echo $K' \
        'cd "$(git rev-parse --show-toplevel)" && git status' \
        'git status; echo $(date)' \
        'git log -1 --format=%h \$(echo --output)' \
        'echo `date`'; do
      guard 0 "$cmd"
    done
    guard 0 'Write-Output "$(git status)"' PowerShell
    guard 0 $'git commit -m "$(cat <<\'EOF\'\nmsg\nEOF\n)" && git push origin main' PowerShell
  fi
  guard_run
  guard_report "$git_fail" "the guard hook reads a command substitution in a git command's words, or as its name, as harmless, or blocks a plain read (B32)" "the guard hook blocks a command substitution that can print a git flag or run a command the guard can't read, in git's words or as a command name, and passes the quoted values, messages and reads the procedures use (B32)"

  # A Bash comment holds no substitution and opens no quoted string (B43): a backtick, $( or quote in it is text, so the
  # command after the comment is read as Bash reads it. A substitution after a comment, a tab, ; or & is still read, and so is
  # one after a # inside a word (a#b) or after an escaped blank, since neither starts a comment. A ) in a comment doesn't close a
  # substitution, so its text runs to the next line and is blocked. A blank before a # inside ${...} is part of the expansion,
  # not a comment. An unquoted heredoc body's substitutions are read whole, as the shell expands them, so a comment in one is
  # read too; a quoted body is text.
  git_fail=""
  if [ -f .claude/hooks/guard-git.sh ]; then
    for cmd in \
        $'git push # x\n`echo --force`' \
        $'git push # x\ngit push `echo --force`' \
        $'git status # note\ngit push $(echo --force)' \
        $'# it\'s\ngit push `echo --force`' \
        $'git status a#b `echo --force`' \
        $'git status a\\ #`echo --force`' \
        $'git status ${x:- #a} $(echo --force)' \
        $'git push origin ":${y:- #}$(echo main)"' \
        $'git push `# x`' \
        $'git push `echo --force` # x' \
        $'git push $(echo --force) # `' \
        $'git status $(echo a # `)' \
        $'git log "--format=$(echo a # )\nprintf x)"' \
        $'git commit -q -F - <<EOF\n# note `\nmsg\nEOF' \
        $'git log <<EOF\n# $(git push --force)\nEOF' \
        $'git status <<EOF\n# `git push --force`\nEOF' \
        $'# note `\\\ngit push `echo --force`'; do
      guard 2 "$cmd"
    done
    for cmd in \
        $'# note `\ngit status' \
        $'# note `echo --force`\ngit status' \
        $'# note $(echo --force)\ngit status' \
        $'git status\t# note `\ngit log -1' \
        $'git status;# note `\ngit log -1' \
        $'# it\'s\ngit status' \
        $'git status # $(echo --force)' \
        $'git status # `echo --force`' \
        $'git status ${x:-y} # $(echo --force)' \
        $'# note `\\\ngit status' \
        $'git commit -q -F - <<\'EOF\'\n# note `echo --force`\nmsg\nEOF'; do
      guard 0 "$cmd"
    done
  fi
  guard_run
  guard_report "$git_fail" "the guard hook reads a backtick, \$( or quote in a Bash comment as a substitution or a string, or misses a substitution after one (B43)" "the guard hook reads a Bash comment as text, so a backtick, \$( or quote in it starts no substitution or string, and a substitution after a comment, an escaped blank or a # in a word is still read (B43)"

  # The word decoder (B51) reads a comment on its own line: a quote in it pairs with nothing after the line break, so the
  # quoted flag, refspec or credential command after it is seen, in Bash, in a heredoc body a shell runs and in PowerShell
  # (whose # starts a comment the same way). A quote in a comment that never closes is text, so the flags it names pass,
  # and a quoted command in a comment passes as it did; a # inside a quoted string, an escaped #, ${#x} or $# starts no
  # comment, so a flag after one is blocked.
  git_fail=""
  if [ -f .claude/hooks/guard-git.sh ]; then
    for cmd in \
        $'# it\'s\ngit push origin \':main\'' \
        $'# it\'s\ngit push "--force" \'x\'' \
        $'# say "hi\ngit push "--force" "x"' \
        $'# it\'s\ngit commit -q "-n" -m \'x\'' \
        $'# it\'s\ngit push origin "+main" \'x\'' \
        $'# say "hi\ngit push origin \':main\'' \
        $'# say "hi\ngit commit -q "-n" -m "x"' \
        $'git status\n# it\'s\ngit push "--force" \'x\'' \
        $'echo \'a\'  # it\'s\ngit push "--force" \'x\'' \
        $'# it\'s\n# don\'t\ngit push origin \':main\' \'x\'' \
        $'bash <<\'EOF\'\n# it\'s\ngit push origin \':main\'\nEOF' \
        $'bash <<\'EOF\'\n# it\'s\ngit push "--force" \'x\'\nEOF' \
        $'# it\'s\ngit credential fill \'x\'' \
        $'# note\\\ngit push --force' \
        $'echo a\\ #b ; git push --force' \
        $'echo "#" ; git push --force' \
        $'git status ${x:- #} ; git push --force' \
        $'echo "$(echo "a #") # b" ; git push --force'; do
      guard 2 "$cmd"
    done
    for cmd in \
        $'# it\'s\ngit status' \
        $'# it\'s --force\ngit status' \
        $'# it\'s "--force" -n :main\ngit status' \
        $'# it\'s \':main\'\ngit log -1' \
        $'# it\'s "git push --force"\ngit status' \
        $'# say "--force" and "-n" and ":main"\ngit status' \
        $'git status # it\'s --force\ngit log -1' \
        $'git status\n# it\'s\ngit log --oneline -3' \
        $'# it\'s -n\ngit push origin main' \
        $'git commit -q -F - <<\'EOF\'\n# it\'s git push origin \':main\'\nEOF' \
        $'bash <<\'EOF\'\n# it\'s --force\necho done\nEOF' \
        $'git commit -m "fix #12 it\'s" -m "x"' \
        $'git status "#" \'it\'' \
        $'echo ;#x'; do
      guard 0 "$cmd"
    done
    for cmd in \
        $'# it\'s\ngit push "--force" \'x\'' \
        $'# it\'s\ngit commit -q "-n" -m \'x\'' \
        $'echo "a""b # " ; git push --force' \
        'git push `#x --force'; do
      guard 2 "$cmd" PowerShell
    done
    guard 0 $'# it\'s --force\ngit status' PowerShell
    guard 0 $'# it\'s\ngit log -1' PowerShell
  fi
  guard_run
  guard_report "$git_fail" "the guard hook reads a quote in a comment as pairing with a quote after its line break, or blocks a comment that names a flag or quotes a command (B51)" "the guard hook reads a quote in a Bash or PowerShell comment as pairing with nothing after its line break, so a quoted flag, refspec or credential command after it is blocked, and a comment that names a flag or quotes a command passes (B51)"

  # A destructive git rule (B33) reads the words as the shell hands them over: a quoted flag, refspec or path is seen, a flag
  # ends at ; & | ) or a line break as it does at a space, and a heredoc body a shell runs is read too. The rules are a force
  # push, a +refspec, reset --hard, clean -f, checkout or switch -f, checkout or restore of ".", stash drop or clear, and
  # branch -D. A quoted message that names one passes, and so does a quoted word that isn't a flag.
  git_fail=""
  if [ -f .claude/hooks/guard-git.sh ]; then
    for cmd in \
      $'git push --force\necho done' \
      'git push --force;echo done' \
      'git push --force&&echo done' \
      'git push --force|cat' \
      '(git push --force)' \
      'git push "--force"' \
      "git push '--force'" \
      'git push "--force-with-lease=origin/main"' \
      'git push --fo"rce"' \
      'git push -f;echo done' \
      'git push origin "+main"' \
      "git push origin '+main'" \
      'git pu"sh" --force' \
      'git status && git push --force' \
      $'git status\ngit push "--force"' \
      'git checkout "."' \
      'git checkout -- "."' \
      'git restore "."' \
      'git checkout .;echo done' \
      'git checkout -f;echo done' \
      'git checkout "-f" main' \
      'git checkout -qf main' \
      'git switch "--discard-changes" main' \
      'git reset "--hard"' \
      'git reset --hard;echo done' \
      'git clean "-f"' \
      'git stash "drop"' \
      'git stash drop;echo done' \
      'git branch "-D" x' \
      'git branch -D x;echo done' \
      'git branch -vD x' \
      'git commit -n;echo done' \
      'git commit -m "-x;y" -F /tmp/msg.txt' \
      'git diff "/etc/passwd"' \
      $'bash <<\'EOF\'\ngit push --force\nEOF' \
      $'bash <<\'EOF\'\ngit push "--force"\nEOF' \
      $'bash <<\'EOF\'\ngit push origin "+main"\nEOF' \
      $'bash <<\'EOF\'\ngit checkout "."\nEOF' \
      $'bash <<\'EOF\'\ngit commit -n -m x\nEOF' \
      $'sh <<EOF\ngit reset --hard\nEOF'; do
      guard 2 "$cmd"
    done
    for cmd in \
      'git push origin main' \
      'git push origin "HEAD:refs/heads/main"' \
      'git push "origin" main' \
      'git push origin main;git status' \
      'git push -u origin "ddd/bundle-$(date +%F)"' \
      'git commit -m "stop git push --force;"' \
      'git commit -m "reset --hard" -m "checkout ."' \
      'git commit -m "stash drop"' \
      'git commit -m "-x" -F -' \
      'git checkout -b "feature/x"' \
      'git checkout "main"' \
      'git branch -d x' \
      'git branch -vv' \
      'git log --grep "push --force"' \
      'git log --oneline "--grep=push"' \
      'git stash show "drop"' \
      'git tag -a v1 -m "push --force note"' \
      'echo "git push --force"' \
      'git status && echo "reset --hard"' \
      $'git status\ngit log --oneline -3' \
      $'git commit -q -F - <<\'EOF\'\nStop "git push --force" in the hook, and "git reset --hard".\nEOF' \
      $'git commit -q -F - <<\'EOF\'\nfix the --output and --no-index handling, not -F /tmp/x\nEOF'; do
      guard 0 "$cmd"
    done
    for cmd in 'git push "--force"' 'git push origin "+main"' 'git checkout "."' 'git push --force;echo done' 'git reset "--hard"'; do
      guard 2 "$cmd" PowerShell
    done
    guard 0 'Write-Output "git push --force"' PowerShell
    guard 0 'git push origin "HEAD:main"' PowerShell
  fi
  guard_run
  guard_report "$git_fail" "the guard hook doesn't read a destructive git rule's flag, refspec or path as the shell does, or blocks a message that names one (B33)" "the guard hook blocks a force push, a +refspec, reset, clean, checkout, stash drop and branch -D that a quote, a line break, ; & | ) or a heredoc body hides, and passes the quoted messages (B33)"

  # A script a shell or an interpreter runs is a command of its own (B34): a quoted string given to bash -c, sh -c or
  # zsh -c (with options before -c), eval, powershell -Command, pwsh -c or cmd /c is read by the same rules, to four levels
  # of nesting, whatever the name is quoted or prefixed with. A comment, a heredoc body or a message in quotes that names
  # one is text, and a read or a benign script passes. A command whose quoting the guard can't close, and PowerShell's
  # -EncodedCommand, whose text is hidden, are blocked.
  git_fail=""
  if [ -f .claude/hooks/guard-git.sh ]; then
    for cmd in \
        "bash -c 'git push --force'" \
        'sh -c "git commit --no-verify -m x"' \
        "eval 'git log --output=x'" \
        'sh -c "git push $(echo --force)"' \
        "sh -c 'git commit -n -m x'" \
        "zsh -c 'git branch -D x'" \
        "bash -lc 'git reset --hard'" \
        "bash -o pipefail -c 'git push --force'" \
        'eval "git push" --force' \
        "bash -c \"git push '--force'\"" \
        "timeout 240 bash -c 'git push --force'" \
        "bash -c 'bash -c \"git push --force\"'" \
        'sh -c "git commit -m \"x\" -n"' \
        'powershell -NoProfile -Command "git push --force"' \
        'cmd /c "git push --force"' \
        '"bash" -c "git push --force"' \
        "ba''sh -c 'git push --force'" \
        "nice -n 5 bash -c 'git push --force'" \
        "sudo sh -c 'git push --force'" \
        "eval 'bash -c \"git push --force\"'" \
        "bash -c \"\$(echo git push --force)\"" \
        "bash -c 'git checkout .'" \
        'bash -c "git push origin +main"' \
        "/bin/bash -c 'git push --force'" \
        "bash -c \$'git push --force'" \
        "bash -c 'git commit -F /tmp/msg.txt'" \
        "bash -c 'sleep 300'" \
        'sh -c "git status' \
        'powershell -EncodedCommand ZwBpAHQAIABwAHUAcwBoAA==' \
        $'# don\'t\nbash -c \'git push --force\'' \
        $'cat <<\'EOF\'\nit\'s\nEOF\nbash -c \'git push --force\'' \
        $'bash -c \'echo hi\' ; sh -c "git status\nbash -c \'git push --force\'"'; do
      guard 2 "$cmd"
    done
    # Four wrappers nested (bash -c inside sh -c inside zsh -c inside bash -c) reach the git inside; a fifth is blocked.
    wrap_esc() { local s="$1"; s="${s//\\/\\\\}"; s="${s//\"/\\\"}"; printf '%s' "$s"; }
    nest="bash -c 'git push --force'"
    for _ in 1 2 3; do nest="sh -c \"$(wrap_esc "$nest")\""; done
    guard 2 "$nest"
    nest="bash -c 'echo hi'"
    for _ in 1 2 3; do nest="sh -c \"$(wrap_esc "$nest")\""; done
    guard 0 "$nest"
    nest="sh -c \"$(wrap_esc "$nest")\""
    guard 2 "$nest"
    for cmd in \
        "bash -c 'git status'" \
        'sh -c "echo hi"' \
        "bash -c 'git log --oneline -3'" \
        "sh -c \"git commit -m 'fix the --output handling'\"" \
        'echo "bash -c '"'"'git push --force'"'"'"' \
        'git commit -m "fix: sh -c '"'"'git push --force'"'"' now blocked"' \
        $'git commit -q -F - <<\'EOF\'\nthe sh -c \'git push --force\' guard\nEOF' \
        "timeout 240 bash -c 'until test -f x; do sleep 5; done'" \
        '(timeout 4m bash -c "while true; do sleep 1; done")' \
        'bash -c "echo $(date)"' \
        'powershell -NoProfile -Command "Write-Output '"'"'hi'"'"'"' \
        "bash -c 'cat README.md'" \
        'eval "echo hi"' \
        'git log --grep "bash -c git push --force"' \
        "bash -c 'echo hi' git status" \
        'echo sh -c' \
        'git commit -m "run cmd /c later"' \
        $'bash -c "git commit -F - <<\'EOF\'\nmsg\nEOF"' \
        $'git commit -m "$(cat <<\'EOF\'\nmsg with sh -c \'git push --force\'\nEOF\n)"' \
        'bash tools/check.sh'; do
      guard 0 "$cmd"
    done
    # PowerShell (B34): the same wrappers in the PowerShell tool's payload, and a backtick that joins a flag.
    for cmd in \
        "pwsh -c 'git reset --hard'" \
        'powershell -Command "git push --force"' \
        'bash -c "git push --force"' \
        'cmd /c "git push --force"' \
        'powershell -EncodedCommand ZwBpAHQAIABwAHUAcwBoAA==' \
        'powershell -c "git push --fo`rce"'; do
      guard 2 "$cmd" PowerShell
    done
    for cmd in \
        "pwsh -c 'git status'" \
        'powershell -NoProfile -Command "Write-Output '"'"'hi'"'"'"' \
        'cmd /c "echo hi"' \
        'powershell -File tools/x.ps1 "git push --force"' \
        'pwsh -c "Get-ChildItem | Select-Object Name"'; do
      guard 0 "$cmd" PowerShell
    done
  fi
  guard_run
  guard_report "$git_fail" "the guard hook doesn't read a script a shell or an interpreter runs as a command of its own, or blocks a message that names one (B34)" "the guard hook reads a script given to bash -c, sh -c, zsh -c, eval, powershell -Command, pwsh -c or cmd /c as a command, to four levels, and passes the messages, heredocs and reads that name one (B34)"

  # A wait loop in a script a shell or an interpreter runs (B42): the hang check reads each such script as it reads the command,
  # so an until, while true or while : loop with sleep is blocked under eval, bash -c, sh -c, powershell -Command and cmd /c.
  # A timeout of 280 seconds or less above the wrapper bounds the whole script, as it bounds a loop the command runs itself,
  # and a loop with no sleep, or in a message that names one, passes.
  git_fail=""
  if [ -f .claude/hooks/guard-git.sh ]; then
    for cmd in \
        "eval 'until false; do sleep 1; done'" \
        "eval 'while true; do sleep 1; done'" \
        "eval 'while :; do sleep 1; done'" \
        "sh -c 'until false; do sleep 1; done'" \
        "eval \"until false; do sleep 1; done\"" \
        "eval 'bash -c \"until false; do sleep 1; done\"'" \
        "eval 'eval \"while true; do sleep 1; done\"'" \
        "sh -c \"eval 'while : ; do sleep 1; done'\"" \
        "timeout 9999 eval 'until false; do sleep 1; done'" \
        "timeout 0 eval 'until false; do sleep 1; done'" \
        "timeout 5m eval 'until false; do sleep 1; done'" \
        'cmd /c "until false; do sleep 1; done"' \
        'cmd /c "while true; do sleep 1; done"' \
        'powershell -Command "while ($true) { Start-Sleep 1 }"' \
        'powershell -NoProfile -Command "while ($true) { sleep 1 }"'; do
      guard 2 "$cmd"
    done
    for cmd in \
        'while ($true) { Start-Sleep 1 }' \
        'While ($true) { Start-Sleep -Seconds 5 }' \
        'WHILE ($true) { start-sleep 2 }'; do
      guard 2 "$cmd" PowerShell
    done
    for cmd in \
        "timeout 60 eval 'until false; do sleep 1; done'" \
        "timeout 4m eval 'until false; do sleep 1; done'" \
        "timeout 240s eval 'until false; do sleep 1; done'" \
        'timeout 60 cmd /c "until false; do sleep 1; done"' \
        "timeout 60 bash -c \"eval 'until false; do sleep 1; done'\"" \
        "sh -c \"timeout 60 eval 'until false; do sleep 1; done'\"" \
        "eval 'timeout 60 bash -c \"until false; do sleep 1; done\"'" \
        "eval 'until false; do echo hi; done'" \
        "eval 'sleep 1'" \
        "eval 'git commit -m \"until false; do sleep 1; done\"'" \
        'cmd /c "echo until"' \
        'powershell -Command "Write-Output (Get-Date)"'; do
      guard 0 "$cmd"
    done
    for cmd in \
        'while ($true) { Get-Date }' \
        'timeout 60 powershell -Command "while ($true) { Start-Sleep 1 }"'; do
      guard 0 "$cmd" PowerShell
    done
  fi
  guard_run
  guard_report "$git_fail" "the guard hook doesn't block a wait loop in a script a shell or an interpreter runs, or blocks one a timeout bounds (B42)" "the guard hook blocks an until or while loop with sleep in a script given to eval, bash -c, sh -c, powershell -Command or cmd /c, and passes one under a timeout of 280 seconds or less (B42)"

  # The hang check's other forms (B49): a C-style for (( loop with sleep and no time limit; a PowerShell do { } while or until with a
  # sleep in its body; Start-Sleep and its alias sleep with -Seconds, -s or -Milliseconds over 280 seconds; cmd's timeout /t N over 280
  # seconds, or -1, which waits for a key press for ever (cmd's timeout is a wait, not a time limit); and a Bash substitution, which
  # runs before a timeout above it starts, so the timeout doesn't bound it. A substitution in single quotes, or escaped, is the
  # script's own, so a timeout above a script bounds it. A message that names one of these passes (the quoted text is blanked).
  git_fail=""
  if [ -f .claude/hooks/guard-git.sh ]; then
    for cmd in \
        'for ((;;)); do sleep 1; done' \
        'for (( ; ; )); do sleep 1; done' \
        'for ((i = 0; i < 3; i++)); do sleep 1; done' \
        'timeout 60 echo "$(until false; do sleep 1; done)"' \
        'timeout 60 echo $(until false; do sleep 1; done)' \
        'timeout 60 bash -c "echo $(until false; do sleep 1; done)"' \
        'timeout 60 echo "$(bash -c "until false; do sleep 1; done")"' \
        'echo "$(sleep 600)"' \
        'echo "$(cmd /c "timeout /t 600")"' \
        'powershell -Command "Start-Sleep -Seconds 600"' \
        'powershell -Command "Start-Sleep -Milliseconds 300001"' \
        'cmd /c "timeout /t 300"' \
        'cmd /c "timeout /t -1"' \
        'timeout 60 cmd /c "timeout /t 600"' \
        'timeout 60 echo $(cat <<'"'"'EOF'"'"'
x
EOF
) ; while true; do sleep 1; done'; do
      guard 2 "$cmd"
    done
    for cmd in \
        'do { Start-Sleep 1 } while ($true)' \
        'do { Start-Sleep 1 } until ($false)' \
        'DO { START-SLEEP -S 600 } WHILE ($true)' \
        'Start-Sleep -Seconds 600' \
        'Start-Sleep -s 600' \
        'Start-Sleep -Milliseconds 280001' \
        'sleep -Seconds 300' \
        'timeout 60 Write-Output $(while ($true) { Start-Sleep 1 })' \
        'powershell -Command "do { Start-Sleep 1 } while ($true)"'; do
      guard 2 "$cmd" PowerShell
    done
    for cmd in \
        "timeout 60 bash -c 'echo \$(until false; do sleep 1; done)'" \
        'timeout 240 bash -c "echo \$(until test -f x; do sleep 5; done)"' \
        "timeout 240 bash -c 'for ((i = 0; i < 3; i++)); do sleep 1; done'" \
        'echo "$(date +%s)"' \
        'echo $(sleep 280)' \
        'bash -c "echo $(date)"' \
        'timeout 60 cmd /c "timeout /t 60"' \
        'cmd /c "timeout /t 280"' \
        "echo '\$(until false; do sleep 1; done)'" \
        'git commit -m "wait: Start-Sleep 600 and for ((;;)) and do { x } while (y)"' \
        'git log --format="%h $(date +%F)" -3' \
        'echo "$(git log --oneline -3)"' \
        'for i in 1 2 3; do echo $i; done' \
        'for ((i = 0; i < 3; i++)); do echo $i; done'; do
      guard 0 "$cmd"
    done
    for cmd in \
        'timeout 60 powershell -Command "do { Start-Sleep 1 } while ($true)"' \
        'timeout 240 powershell -Command "Start-Sleep -Seconds 240"' \
        'Start-Sleep -Seconds 280' \
        'Start-Sleep -Milliseconds 280000' \
        'Start-Sleep 5' \
        'do { Get-Date } while ($false)' \
        "Write-Output 'do { Start-Sleep 1 } while (\$true)'"; do
      guard 0 "$cmd" PowerShell
    done
  fi
  guard_run
  guard_report "$git_fail" "the guard hook doesn't block a for (( loop, a do ... while, Start-Sleep or timeout /t over 280 seconds, or a substitution before a timeout, or blocks a message or a bounded script that names one (B49)" "the guard hook blocks a for (( loop with sleep, a do ... while with sleep, Start-Sleep and timeout /t over 280 seconds, and a substitution that runs before a timeout, and passes a bounded script and a message that names them (B49)"

  # The hang check reads the command without the bodies no shell runs (B50): a commit's, tag's or gh message, and a cat or tee body
  # nothing runs (the classification's reading, B40 and B48). So a message can name a loop, a pause or a timed wait, as plain text,
  # in a C-style or a PowerShell loop, with a pause or a wait over five minutes. A body a shell, an interpreter or a runner executes
  # is still read, and so is the empty-heredoc probe and a command after a message. An unquoted message's substitution is run, so it
  # is read; a quoted one is text, and so are its backticks.
  git_fail=""
  if [ -f .claude/hooks/guard-git.sh ]; then
    for cmd in \
        $'git commit -q -F - -- a <<\'EOF\'\nPowerShell\'s While loop with Start-Sleep is now seen.\nEOF' \
        $'gh pr edit 5 --body-file - <<\'EOF\'\nPowerShell\'s While loop with Start-Sleep is now seen.\nEOF' \
        $'git commit -q -F - <<\'EOF\'\nfix: for ((i = 0; i < 3; i++)); do sleep 600; done\nEOF' \
        $'git commit -q -F - <<\'EOF\'\nwait: Start-Sleep -Seconds 600 before retry\nEOF' \
        $'gh pr create --body-file - <<\'EOF\'\nUse cmd\'s timeout /t 600 to wait\nEOF' \
        $'gh pr create --body-file - <<\'EOF\'\ndo { Start-Sleep 600 } while ($true)\nEOF' \
        $'gh pr create --body-file - <<\'EOF\'\nuse `sleep 600` and `timeout /t 600` as examples\nEOF' \
        $'gh pr create --body-file - <<\'EOF\'\n$(until false; do sleep 1; done)\nEOF' \
        $'git commit -q -F - <<EOF\nwhile you wait, Start-Sleep 600 $(date +%F)\nEOF' \
        $'git tag -a v1 -F - <<\'EOF\'\nwhile true; do sleep 600; done\nEOF' \
        $'gh issue comment 5 -F - <<\'EOF\'\nfor ((;;)); do sleep 1; done\nEOF' \
        $'gh release create v1 --notes-file - <<\'EOF\'\ndo { Start-Sleep 600 } until ($false)\nEOF' \
        $'git commit -q -F - <<\'EOF\'\nfix: sleep 600\nEOF\ngit status' \
        $'cat > notes.md <<\'EOF\'\nuntil false; do sleep 600; done\nEOF' \
        $'cat > notes.md <<EOF\nuntil false; do sleep 600; done\nEOF' \
        $'tee notes.md <<\'EOF\'\nStart-Sleep -Seconds 600\nEOF'; do
      guard 0 "$cmd"
    done
    guard 0 'git commit -q -m "wait: Start-Sleep -Seconds 600"' PowerShell
    for cmd in \
        $'python3 - <<\'EOF\'\nEOF' \
        $'bash <<\'EOF\'\nuntil false; do sleep 600; done\nEOF' \
        $'cat > x.sh <<\'EOF\'\nwhile true; do sleep 1; done\nEOF\nbash x.sh' \
        $'cat > x.sh <<\'EOF\'\nStart-Sleep -Seconds 600\nEOF\nsh x.sh' \
        $'cat > x.sh <<\'EOF\'\nuntil false; do sleep 1; done\nEOF\n. ./x.sh' \
        $'echo start; cat > x.sh <<\'EOF\'\nuntil false; do sleep 1; done\nEOF\nbash x.sh' \
        $'git commit -q -F - <<\'EOF\'\nmsg\nEOF\nwhile true; do sleep 1; done' \
        $'gh pr create --body-file - <<\'EOF\'\nmsg\nEOF\nsleep 600' \
        $'git commit -q -F - <<EOF\n$(until false; do sleep 1; done)\nEOF' \
        $'gh pr create --body-file - <<EOF\n$(sleep 600)\nEOF' \
        $'git commit -q -F - <<EOF\n`until false; do sleep 1; done`\nEOF' \
        $'cat > notes.md <<\'EOF\'\nmsg\nEOF\nbash -c "until false; do sleep 600; done"'; do
      guard 2 "$cmd"
    done
  fi
  guard_run
  guard_report "$git_fail" "the guard hook blocks a message or an unrun cat body that names a loop, a pause or a timed wait, or passes a body a shell, an interpreter or a runner executes (B50)" "the guard hook passes a commit's, tag's or gh message, and a cat or tee body nothing runs, that names a loop, a pause or a timed wait, and blocks a body a shell, an interpreter or a runner executes (B50)"

  # A variable in a git command's words (B37): the guard can't read what it holds. A variable that the command assigns once,
  # to a plain value, is read as that value, so FLAG=--force; git push $FLAG is the force push it is. Any other unquoted
  # variable in the words of a git subcommand the rules read is blocked, and so is a quoted one that a flag or a path could
  # be, a fixed text that starts a flag (--$X), a variable as the subcommand, and a variable as a command's name followed by
  # -c or -Command. The everyday forms pass: a quoted variable as the value of -m, -e, -b or -C, after --, after fixed text
  # that doesn't start a flag, as a push's branch after its remote, and in a subcommand the rules don't read (git status).
  git_fail=""
  if [ -f .claude/hooks/guard-git.sh ]; then
    for cmd in \
        'FLAG=--force; git push $FLAG' \
        'FLAG=-f; git push ${FLAG} origin' \
        'export ST=-f && git push $ST origin' \
        'FLAG=--force; git push "$FLAG"' \
        'FLAG=ok; FLAG=--force; git push $FLAG' \
        'FLAG=ok; read FLAG; git push $FLAG' \
        'NV=--no-verify; git commit $NV -m x' \
        'git commit $NV -m x' \
        "git commit \"\$NV\" -m x" \
        'git push $FLAG' \
        'git push "$FLAG"' \
        'git push origin $BR' \
        'git push --$X' \
        'git push "--$X"' \
        'git push -$F origin' \
        'git log $X' \
        'git log --output="$X"' \
        'git diff "$f"' \
        'git -C $d log' \
        'git $CMD --force' \
        'git commit -nm"$x" -- a' \
        'git commit -m$msg' \
        'git checkout -b $name' \
        'git reset --hard $REF' \
        'git branch -D "$b"' \
        'git grep "$p"' \
        $'bash <<\'EOF\'\ngit push $FLAG\nEOF' \
        "\$X -c 'git push --force'" \
        '"$SHELL" -c "git push --force"' \
        'sudo "$X" -c "git push --force"' \
        'env FOO=1 $X -c x' \
        'timeout 240 "$X" -c x' \
        'echo ok && $X -c x' \
        '"$EDITOR" -c x'; do
      guard 2 "$cmd"
    done
    for cmd in 'git commit $NV -m x' 'git push "$FLAG"' 'git push -u origin $BR' '$X -c "git push --force"' \
        '& $X -c "git push --force"'; do
      guard 2 "$cmd" PowerShell
    done
    for cmd in \
        'for r in A B C; do git -C work/$r status --short; done' \
        'git -C "work/$r" log --oneline -1' \
        'git -C "$repo" fetch' \
        'git -C $d status' \
        'git status $X' \
        'git add $FILE' \
        'git log --since="$since"' \
        'git commit -m "$msg" -- a' \
        'git commit -m"$msg" -- a' \
        'git commit -am "$msg"' \
        'git commit -C "$c"' \
        'git push -u origin "$branch"' \
        'git push origin "$a" "$b"' \
        'git checkout -b "ddd/bundle-$day"' \
        'git checkout -b "ddd/bundle-$day" origin/main' \
        'git switch -c "$b"' \
        'git grep -e "$p"' \
        'git tag -a "v$VER" -m "release"' \
        'git log --format="%h $X"' \
        'git log -- $X' \
        'git commit -m "$msg" -- $X' \
        'git log > "$out"' \
        'git log >"$out" --oneline' \
        'FLAG=ok; git push $FLAG' \
        'FLAG=--force; echo $FLAG' \
        'MSG=--force; git commit -m "$MSG"' \
        'a=1; git push $a' \
        'echo $X -c x' \
        'echo -n $X -c x' \
        'echo "$X -c y"' \
        '"$EDITOR" notes.txt' \
        'git commit -m "& $X -c y" -- a' \
        $'git commit -q -F - <<\'EOF\'\nfix the $X handling\nEOF'; do
      guard 0 "$cmd"
    done
    guard 0 'git push -u origin "$branch"' PowerShell
    guard 0 'git commit -m "$msg" -- a' PowerShell
  fi
  guard_run
  guard_report "$git_fail" "the guard hook reads a variable in a git command's words as a value it can't see, or blocks a plain form (B37)" "the guard hook reads a variable a git command assigns once as its value, blocks an unquoted or flag-capable variable in a git command's words, a variable as a subcommand or as a shell's name followed by -c, and passes the everyday forms (B37)"

  # A variable as a command's name, and a variable a shell's script holds (B45): the name a command assigns is the name it runs
  # (G=git; $G push --force is git), and an unresolved name that the command sets another way, or that a git subcommand or a
  # destructive flag follows, is blocked. A variable a shell's script (bash -c, eval, -Command) holds is blocked too. The
  # everyday forms pass: "$PY" -I script.py, a loop that runs "$PY" "$f", a variable as an argument, and a single-quoted
  # script's own variable (its shell reads it, and it can't name a command here). The Godot path cases are with the hangs above.
  git_fail=""
  if [ -f .claude/hooks/guard-git.sh ]; then
    for cmd in \
        'G=git; $G push --force' \
        '$G push --force' \
        '"$G" push --force' \
        'G=git; ${G} push --force' \
        'G=git; "$G" push --force' \
        '$G --force' \
        'if true; then $G push --force; fi' \
        'for f in x; do $G push --force; done' \
        '{ $G push --force; }' \
        'xargs $G push --force' \
        'find . -exec $G push --force \;' \
        'if true; then "$X" -c x; fi' \
        'CMD="git push --force"; $CMD' \
        'read CMD <<< "git push --force"; $CMD' \
        'FOO=$(echo git); $FOO push --force' \
        'bash -c "$CMD"' \
        'eval "$CMD"' \
        'eval $CMD' \
        "bash -c '\$CMD'" \
        'CMD="git push --force" bash -c '"'"'$CMD'"'"'' \
        'sh -c "echo $HOME"' \
        $'G=git; bash <<\'EOF\'\n$G push --force\nEOF' \
        $'bash <<\'EOF\'\n$G push --force\nEOF' \
        $'CMD="git push --force" bash <<\'EOF\'\n$CMD\nEOF'; do
      guard 2 "$cmd"
    done
    for cmd in "\$G = 'git'; & \$G push --force" '& $G push --force'; do
      guard 2 "$cmd" PowerShell
    done
    guard 2 'powershell -Command "$P"' PowerShell
    for cmd in \
        'G=git; $G status' \
        'G=ls; $G push --force' \
        'echo $G push --force' \
        '"$PY" -I script.py' \
        'PY=python3; "$PY" -I script.py' \
        'FOO="a b" "$PY" -I x.py' \
        'for f in tools/*.py; do "$PY" "$f"; done' \
        'for f in a b; do echo "$f"; done' \
        'if true; then "$PY" -I x.py; fi' \
        'find . -name x -exec "$PY" -I y {} \;' \
        'xargs -I{} echo {}' \
        '"$PY" tools/usage.py status' \
        'bash "$script"' \
        'bash tools/check.sh "$X"' \
        'cd "$dir" && git status' \
        'bash -c "echo \$HOME"' \
        "bash -c 'echo \$HOME'" \
        $'git commit -q -F - <<\'EOF\'\n$G push --force\nEOF'; do
      guard 0 "$cmd"
    done
    guard 0 "powershell -Command 'Get-ChildItem | % { \$_.Name }'" PowerShell
  fi
  guard_run
  guard_report "$git_fail" "the guard hook doesn't read a variable as a command's name, or a script that a variable holds, or blocks an everyday form (B45)" "the guard hook reads a variable as a command's name as the value it assigns, blocks an unresolved one that the command sets another way or a git subcommand follows, blocks a shell's script, eval or -Command that a variable holds, and passes the everyday forms (B45)"

  # An assignment is not a command, so it isn't read as a variable command name (B55): a PowerShell $x = 1, $x += 1 or $env:X = 'y',
  # and a PowerShell constant or automatic value that no call operator runs ($true, $null, $args), pass in a PowerShell payload and in
  # a PowerShell script a shell runs. A Bash NAME+=value is an assignment prefix, as NAME=value is. A call operator still runs
  # what its name holds, and a git subcommand after any name is still read: & $x, & $args[0], $args push --force and $G push
  # --force block, and so does out+=x $G push --force.
  git_fail=""
  if [ -f .claude/hooks/guard-git.sh ]; then
    for cmd in \
        '$x = 1' \
        '$files = Get-ChildItem docs' \
        '$x=1' \
        '$x += 1' \
        '$x ??= 1' \
        "\$env:X = 'y'" \
        '$x[0] = 1' \
        '$null = Get-Date' \
        '$true' \
        '$false' \
        '$null' \
        'while ($true) { Get-Date }' \
        '$args' \
        '$_.Name' \
        '$input | Out-Null'; do
      guard 0 "$cmd" PowerShell
    done
    for cmd in \
        "\$x = 1; & \$x" \
        "\$x = 'git'; & \$x push --force" \
        '$args push --force' \
        '& $args[0] push --force' \
        '$input | ForEach-Object { & $_ push --force }' \
        '& $env:COMSPEC push --force'; do
      guard 2 "$cmd" PowerShell
    done
    for cmd in \
        "powershell -Command 'while (\$true) { Get-Date }'" \
        "powershell -Command '\$x = 1'" \
        'c="${x:0:1}"; out+="$c"; echo hi' \
        'out+=x; echo hi'; do
      guard 0 "$cmd"
    done
    for cmd in \
        'out+=x $G push --force' \
        'out+=x; $G push --force' \
        'c+=y; "$c" push --force' \
        "powershell -Command '\$args push --force'" \
        "powershell -Command '\$G = \"git\"; & \$G status'"; do
      guard 2 "$cmd"
    done
  fi
  guard_run
  guard_report "$git_fail" "the guard hook reads an assignment or a constant as a variable command name, or passes a call operator or a NAME+=value prefix that runs a git command (B55)" "the guard hook passes a PowerShell assignment, a constant and an automatic value that runs nothing, and a Bash NAME+=value assignment, and blocks a call operator or a prefixed variable that runs git (B55)"

  # PowerShell's Invoke-Expression and iex (B60) run their one string argument as a script, as eval does. A literal argument is read as
  # a script of its own, and a variable the command assigns once to a plain literal before the call is read as its value. A pipeline into
  # the call, no argument, an argument that isn't one string (a concatenation, a second argument, a double-quoted $( the caller expands),
  # and a variable that can't be resolved (one set another way, in a branch, or after the call) are blocked. The benign forms pass.
  git_fail=""
  if [ -f .claude/hooks/guard-git.sh ]; then
    for cmd in \
        "iex 'git push --force'" \
        "Invoke-Expression 'git push --force'" \
        "Invoke-Expression -Command 'git push --force'" \
        "iex -Command:'git push --force'" \
        "IEX \"git push --force\"" \
        "iex 'git push --force' -Verbose" \
        "iex -Verbose 'git push --force'" \
        "iex '-Verbose git push --force'" \
        "Microsoft.PowerShell.Utility\\Invoke-Expression 'git push --force'" \
        "& iex 'git push --force'" \
        "ForEach-Object { iex 'git push --force' }" \
        "ForEach-Object {iex 'git push --force'}" \
        "\$x = 'git push --force'; iex \$x" \
        "\$x='git push --force'; iex \$x" \
        "\$x = 'git push --force'; Invoke-Expression \$x" \
        "\$x = 'git push --force'; iex \"\$x\"" \
        "\$x = \"git push --force\"; iex \$x" \
        "\$x = 'git push --force'; iex \${x}" \
        "\$x = 'git push --force'; iex \$x -Verbose" \
        "\$x = 'git push --force'; iex \$x | Out-Null" \
        "\$x = 'git'; iex \"\$x push --force\"" \
        "iex \$x" \
        "iex \"\$x\"" \
        "iex" \
        "iex \$x; \$x = 'git push --force'" \
        "\$x = 'git push --force' | Out-Null; iex \$x" \
        "\$x = 'ls'; iex \"\$x\" \"--force\"" \
        "\$x = 'ls'; iex \"\$x\"-f ''" \
        "\$x = 'ls'; iex \$x \$y" \
        "\$x = 'ls'; Set-Variable x 'git push --force'; iex \$x" \
        "\$x = 'ls'; . ./evil.ps1; iex \$x" \
        "\$x = 'ls'; Import-Module ./m.psm1; iex \$x" \
        "if (\$true) { \$x = 'ls' }; iex \$x" \
        "\$x = 'git push --force'; iex \$x[0]" \
        "\$x = 'ls'; \$x[0] = 'git push --force'; iex \$x" \
        "\$x = 'ls'; \$x += 'git push --force'; iex \$x" \
        "\$y = '\$x = ''git push --force'''; iex \$y; iex \$x" \
        "\$x = 'ls'; \$y = '\$x = ''git push --force'''; iex \$y; iex \$x" \
        "\$x = 'git push --force'; \$y = \$x; iex \$y" \
        "iex \"\$(Get-Content x.txt)\"" \
        "iex @args" \
        "\$x = 'Get-Date'; iex @x" \
        "iex ('git push' + ' --force')" \
        "iex 'git pu' + 'sh --force'" \
        "iex \"git push\" + \" --force\"" \
        "'git push --force' | iex" \
        "Get-Content x.ps1 | iex"; do
      guard 2 "$cmd" PowerShell
    done
    guard 2 "powershell -Command \"iex 'git push --force'\"" PowerShell
    for cmd in \
        "\$x = 'Get-Date'; iex \$x" \
        "\$x = 'Get-Date'; iex \"\$x\"" \
        "\$x = 'git status'; iex \$x" \
        "\$x = 'Get-Date'; \$y = 'git status'; iex \$x; iex \$y" \
        "\$x = 'git push --force'" \
        "\$x = 'git push --force'; iex 'Get-Date'" \
        "iex 'Get-Date'" \
        "iex 'Get-Date' -Verbose" \
        "Invoke-Expression -Command 'Get-Date' -Verbose" \
        "iex 'Write-Output \$x'" \
        "iex '\$x = 1'" \
        "iex \$true" \
        "iex 'Get-Date' | Out-Null" \
        "ForEach-Object { iex 'Get-Date' }" \
        "Get-Help Invoke-Expression" \
        "Get-Command iex" \
        "Write-Output 'iex git push --force'"; do
      guard 0 "$cmd" PowerShell
    done
  fi
  guard_run
  guard_report "$git_fail" "the guard hook doesn't read an Invoke-Expression or iex script as a command, or passes one it can't read (B60)" "the guard hook reads the string argument of Invoke-Expression and iex as a script, resolves a variable the command assigns once to a plain literal, blocks a pipeline into it, an argument that isn't one string and an unresolved variable, and passes the benign forms (B60)"

  # A git command name in another case (B46): PowerShell finds a command case-insensitively, and Windows finds GIT too, so GIT and
  # Git are git in every git rule. Only the name is matched so: git's subcommands and flags stay case-sensitive, as git reads them.
  # The git rules, the credential prints, a substitution in the words and a shell body that runs GIT block as their lowercase
  # forms do, and the everyday forms and a quoted or heredoc message that names git in another case pass.
  git_fail=""
  if [ -f .claude/hooks/guard-git.sh ]; then
    for cmd in \
        'GIT push --force origin main' \
        'Git commit --no-verify -m x' \
        'GIT reset --hard HEAD~1' \
        'GIT log --output=/tmp/probe.txt' \
        'Git diff --no-index a b' \
        'GIT commit -F /tmp/msg.txt' \
        'GIT log --ext-diff' \
        'GIT push origin :main' \
        'GIT branch -D x' \
        'GIT credential fill' \
        'Git credential get' \
        'GIT -c core.pager=calc log' \
        'Git push "$(echo --force)" origin main' \
        $'bash <<\'EOF\'\nGIT push --force\nEOF'; do
      guard 2 "$cmd" PowerShell
    done
    for cmd in 'GIT push --force origin main' 'Git commit --no-verify -m x'; do
      guard 2 "$cmd"
    done
    for cmd in \
        'GIT status' \
        'Git log --oneline -5' \
        'GIT diff HEAD' \
        'GIT grep -n foo' \
        'GIT tag -a v1 -m "see --force and -F"' \
        'echo "Git push --force is blocked"' \
        'echo "Git credential fill is blocked"' \
        $'Git commit -q -F - <<\'EOF\'\nfix the --output and --no-index handling, not -F /tmp/x\nEOF'; do
      guard 0 "$cmd" PowerShell
    done
    guard 0 'GIT status'
  fi
  guard_run
  guard_report "$git_fail" "the guard hook passes a git command name in another case, or blocks a message that names git in another case (B46)" "the guard hook blocks a git command name in any case (GIT, Git) as it blocks git, and passes the everyday forms and the messages that name git in another case (B46)"

  # Git's configuration keys and program flags (B38). A -c key, or --config-env, that names a program git runs (an alias that
  # starts with !, the pager, the editor, the ssh command, a diff or credential helper, an include) is blocked, and so is a key a
  # variable holds; the keys that run nothing pass (core.quotepath, color.*, advice.*, log.*, user.name, pager.<cmd>=false). The
  # flags that name a program for a remote (--upload-pack, --receive-pack, --exec, and clone's -u), abbreviations included, are
  # blocked on fetch, pull, push, clone, ls-remote and archive, and a plain fetch, push -u and clone -b pass. A variable that names
  # a program git runs (GIT_CONFIG_*, GIT_SSH_COMMAND, GIT_PAGER, GIT_EDITOR, EDITOR) set on a git command is blocked too.
  git_fail=""
  if [ -f .claude/hooks/guard-git.sh ]; then
    for cmd in \
        'git -c alias.x="!echo hi" x' \
        "git -c 'alias.x=!echo hi' x" \
        'git -c "alias.x=!echo hi" x' \
        'git -c core.pager="sh -c x" log' \
        'git -c core.sshCommand=x fetch' \
        'git -c diff.external=x diff' \
        'git -c "$k=v" log' \
        'git -c Alias.X=y x' \
        'git -c core.quotepath=false -c alias.x=y x' \
        'git -c color.ui=always -c core.pager=x log' \
        'git -c sequence.editor=x rebase -i HEAD~2' \
        "git -c credential.helper='!x' fetch origin" \
        'git -c protocol.ext.allow=always fetch origin' \
        'git -c include.path=/tmp/x log' \
        'git -c "core.$(echo pager)=x" log' \
        'git -c pager.log=less log' \
        'git --config-env=core.pager=PAGER_VAR log' \
        'git --git-dir .git -c alias.x=y x' \
        "git -c \$'alias.x=!echo hi' x" \
        "git -c 'alias.x=y' x" \
        'git -c "alias.x" x' \
        'git -c "a""lias.x=!echo" x' \
        'git -c "core.pager"=sh x' \
        'k=core.pager; git -c "$k=sh" log' \
        $'git \\\n-c core.pager=x log' \
        'git clone -c core.sshCommand=x https://example.com/r.git d' \
        'git clone --config=alias.x=y https://example.com/r.git d' \
        'git clone --config alias.x=y https://example.com/r.git d' \
        'git clone -c alias.x=y https://example.com/r.git d' \
        'git clone -u "sh -c x" https://example.com/r.git d' \
        'git clone --upload-pack="sh -c x" https://example.com/r.git d' \
        'git clone -qu "sh -c x" https://example.com/r.git d' \
        'git fetch --upload-pack x origin' \
        'git fetch --upl=x origin' \
        'git fetch --upload-pack="$(echo x)" origin' \
        'git fetch "--$(echo upload-pack)=x" origin' \
        'git pull --upload-pack=x' \
        'git push --receive-pack=x origin main' \
        'git push --receive-pack x origin main' \
        'git push --exec=x origin main' \
        'git push origin main --receive=x' \
        'git ls-remote --upload-pack=x origin' \
        'git archive --remote=origin --exec=x HEAD' \
        'GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=core.pager GIT_CONFIG_VALUE_0=x git log' \
        'GIT_SSH_COMMAND=x git fetch' \
        'GIT_PAGER=x git log' \
        'GIT_EXTERNAL_DIFF=x git log -p' \
        'env GIT_EDITOR=x git commit' \
        'export GIT_PAGER=x; git log' \
        'EDITOR=x git commit -a'; do
      guard 2 "$cmd"
    done
    for cmd in 'git -c core.pager=x log' 'git -c "$k=v" log' 'git fetch --upload-pack=x' 'git -c alias.x=!echo x' \
        '$env:GIT_PAGER="x"; git log'; do
      guard 2 "$cmd" PowerShell
    done
    for cmd in \
        'git -c core.quotePath=false status --porcelain --untracked-files=all' \
        'git -c core.quotepath=off log --oneline -3' \
        'git -c color.ui=never log --oneline' \
        'git -c user.name=selftest -c user.email=selftest@localhost commit -m x' \
        "git -c 'user.name=A B' commit -m x" \
        'git -c advice.detachedHead=false checkout HEAD~1' \
        'git -c log.showSignature=false log -1' \
        'git -c pager.log=false log --oneline' \
        'git -c "color.ui=always" diff --stat' \
        'k=color.ui; git -c "$k=always" log --oneline' \
        'git -C work/Godot-Director fetch' \
        'git -c core.quotepath=false -C work/Godot-Director status' \
        'git clone -b main https://example.com/r.git d' \
        'git clone -q --depth 1 https://example.com/r.git d' \
        'git clone -c core.quotepath=false https://example.com/r.git d' \
        'git fetch origin' \
        'git fetch --unshallow origin' \
        'git push -u origin "$branch"' \
        'git push origin main' \
        'git push --recurse-submodules=check origin main' \
        'git ls-remote origin' \
        'git archive --format=tar HEAD' \
        'git pull --rebase origin main' \
        'git log -c' \
        'git commit -c HEAD' \
        'git commit -m "--upload-pack=x fix"' \
        'git commit -m "alias.x=!echo hi"' \
        'git tag -a v1 -m "-c alias.x=y"' \
        'git commit -m "set EDITOR=vim and GIT_PAGER=x"' \
        'GIT_AUTHOR_NAME=x git commit -m y' \
        'FOO=1 git status' \
        'EDITORCONFIG=x git status' \
        $'git commit -q -F - <<\'EOF\'\nGIT_PAGER=x and EDITOR=vim in a message\nEOF' \
        $'git \\\n-c core.quotepath=false status'; do
      guard 0 "$cmd"
    done
    guard 0 'git -c user.email=a@b.c commit -m x' PowerShell
    guard 0 'git -c color.ui=always status' PowerShell
    guard 0 'git push -u origin main' PowerShell
  fi
  guard_run
  guard_report "$git_fail" "the guard hook passes a git -c key or a program flag that runs a command, or a variable that names one, or blocks a plain form (B38)" "the guard hook blocks a git -c key that names a program (an alias, the pager, the ssh command, a diff or credential helper), a key a variable holds, a program flag for a remote (--upload-pack, --receive-pack, --exec, clone's -u), and a GIT_CONFIG_*, GIT_PAGER or EDITOR variable on a git command; the keys that run nothing and the plain forms pass (B38)"

  # A quoted git name, a heredoc body a shell runs, the long forms and a credential subcommand in quotes (B39). The git name is
  # read as the shell reads it, quotes removed, so "git", 'git' and g"it" are git. A heredoc body a shell runs (any body but a
  # commit's or tag's message) is read by the file-writing flag rules, and a backtick ends a flag in it. git branch with --delete
  # and --force (-d -f, -df, --del --forc), git push --mirror, --delete and -d (abbreviations too) and a :ref refspec are blocked,
  # as their plain forms are, and the credential-print rules read the decoded words. A message that names them, and a read that
  # names none, pass: a commit's or tag's message is text no shell runs.
  git_fail=""
  if [ -f .claude/hooks/guard-git.sh ]; then
    for cmd in \
        '"git" push --force' \
        "'git' push --force" \
        'g"it" push --force' \
        '"git" log --output=/tmp/x' \
        $'bash <<\'EOF\'\ngit log --output=/tmp/x\nEOF' \
        $'sh <<EOF\ngit diff --no-index a b\nEOF' \
        $'bash <<\'EOF\'\ngit commit -F /tmp/msg.txt\nEOF' \
        $'cat <<\'EOF\' | bash\ngit log --output=/tmp/x\nEOF' \
        $'bash <<\'EOF\'\ngit branch --delete --force x\nEOF' \
        $'bash <<\'EOF\'\ngit push --mirror\nEOF' \
        $'bash <<\'EOF\'\ngit credential "fill"\nEOF' \
        $'bash <<\'EOF\'\ngit push `echo --force`\nEOF' \
        $'bash <<\'EOF\'\ngit push --force`echo x`\nEOF' \
        $'ssh host <<\'EOF\'\ngit push `echo --force`\nEOF' \
        $'git status && bash <<\'EOF\'\ngit push `echo --force`\nEOF' \
        $'"bash" <<\'EOF\'\ngit push --mirror\nEOF' \
        $'git commit -m "$(source /dev/stdin <<\'EOF\'\ngit push `echo --force`\nEOF\n)"' \
        'sh -c "git push --mirror"' \
        'git branch --delete --force x' \
        'git branch --delete -f x' \
        'git branch -d -f x' \
        'git branch -df x' \
        'git branch -fd x' \
        'git branch --del --forc x' \
        'git push --mirror' \
        'git push --mirror origin' \
        'git push --mi origin' \
        'git push --delete origin x' \
        'git push --de origin x' \
        'git push -d origin x' \
        'git push -fd origin x' \
        'git push origin :x' \
        'git push origin ":x"' \
        'git push origin :refs/heads/x' \
        'git credential "fill"' \
        "git credential 'get'" \
        'git credential fi"ll"' \
        'gh "auth" "token"' \
        'g"h" auth token'; do
      guard 2 "$cmd"
    done
    for cmd in \
        'git branch -d x' \
        'git branch -vv' \
        'git branch -m old new' \
        'git branch --list "*f*"' \
        'git push origin main:main' \
        'git push origin HEAD:refs/heads/x' \
        'git push --dry-run origin main' \
        'git push --set-upstream origin x' \
        'echo "git push --mirror"' \
        'echo "git credential fill"' \
        'git log --grep "push --mirror"' \
        'git status && echo "git credential fill"' \
        $'git commit -q -F - <<\'EOF\'\nfix: git push --mirror and git branch -d x\nEOF' \
        $'git commit -q -F - <<\'EOF\'\nfix: git log --output=x in the docs\nEOF' \
        $'git commit -q -F - <<\'EOF\'\nmsg with `git push --force` in it\nEOF' \
        $'git tag -a v1 -F - <<\'EOF\'\nfix: git push --delete origin x\nEOF' \
        $'git commit -q -F - <<\'EOF\'\nfix the --mirror and --delete flags, not -d\nEOF' \
        $'bash <<\'EOF\'\necho hi\nEOF' \
        $'bash <<\'EOF\'\ngit status\nEOF' \
        $'bash <<\'EOF\'\ngit branch -d x\nEOF' \
        $'git status && bash <<\'EOF\'\necho x\nEOF'; do
      guard 0 "$cmd"
    done
    for cmd in '"git" push --force' 'git branch --delete --force x' 'git push --mirror' 'git push origin :x' \
        'git credential "fill"' 'gh "auth" "token"'; do
      guard 2 "$cmd" PowerShell
    done
    for cmd in 'git branch -d x' 'git push origin main'; do
      guard 0 "$cmd" PowerShell
    done
  fi
  guard_run
  guard_report "$git_fail" "the guard hook doesn't read a quoted git name, a heredoc body a shell runs, a long-form branch or push flag, a push refspec that deletes, or a quoted credential subcommand as the shell does, or blocks a message that names a plain form (B39)" "the guard hook blocks a quoted git name, a heredoc body a shell runs with a file-writing flag, a backtick flag or a destructive command, git branch --delete --force, git push --mirror, --delete or a :ref refspec, and a quoted credential subcommand, and passes the messages and reads that name them (B39)"

  # A heredoc body no shell runs is text (B40): a commit's or tag's message, and a cat or tee body that the command doesn't run (no
  # shell, interpreter, ssh, chmod, make, a ./ path, a dot-source or the .git folder). The destructive rules and the file-writing flag
  # rules skip such a body, so a message or a written file that names a destructive git command passes, and its substitutions are
  # still read. A body written to a file and run in the same command (cat > x.sh, then bash x.sh, ./x.sh or . x.sh) is a script a
  # shell runs, and is read as before. The guard reads command text, so a file written by an earlier command isn't judged.
  git_fail=""
  if [ -f .claude/hooks/guard-git.sh ]; then
    for cmd in \
        $'git commit -q -F - <<\'EOF\'\nfix: git push --force; done\nEOF' \
        $'git tag -a v1 -F - <<\'EOF\'\nfix: git push --delete origin x\nEOF' \
        $'git commit -q -F - <<\'EOF\'\nmsg with `git push --force` in it\nEOF' \
        $'git commit -m "$(cat <<\'EOF\'\nfix: git reset --hard\nEOF\n)"' \
        $'git commit -q -F - <<\'EOF\'\nfix: git log --output=x in the docs\nEOF\nbash x.sh' \
        $'cat > notes.md <<\'EOF\'\nsee git log --output=x\nEOF' \
        $'cat > notes.md <<\'EOF\'\na backticked `git push --force` here\nEOF' \
        $'tee notes.md <<\'EOF\'\ngit push --mirror\nEOF' \
        $'cat <<\'EOF\' > notes.md\ngit reset --hard\nEOF' \
        $'cat >> notes.md <<\'EOF\'\ngit branch -D x\nEOF' \
        $'cat > notes.md <<\'EOF\'\ngit push --force\nEOF\ngit add notes.md && git status' \
        $'cat > ./notes.md <<\'EOF\'\ngit diff --ext-diff\nEOF' \
        $'cat > notes.md <<\'EOF\'\nbash -c \'git push --force\'\nEOF' \
        $'cat > notes.md <<EOF\nplain text, no git here\nEOF' \
        $'cat > notes.md <<\'EOF\'\ngit push --force\nEOF\necho "run bash later"' \
        $'cat > notes.md <<\'EOF\'\ngit push --force\nEOF\ngit commit -q -F - <<\'EOF2\'\nfix: git push --force\nEOF2'; do
      guard 0 "$cmd"
    done
    for cmd in \
        $'cat > x.sh <<EOF\ngit push --force\nEOF\nbash x.sh' \
        $'cat > x.sh <<\'EOF\'\ngit push --force\nEOF\nbash x.sh' \
        $'cat > x.sh <<\'EOF\'\ngit push --force\nEOF\nchmod +x x.sh && ./x.sh' \
        $'cat > x.sh <<\'EOF\'\ngit reset --hard\nEOF && sh x.sh' \
        $'cat > x.sh <<\'EOF\'\ngit log --output=/tmp/x\nEOF\nbash x.sh' \
        $'cat > x.sh <<\'EOF\'\ngit push --force\nEOF\nsource x.sh' \
        $'tee x.sh <<\'EOF\'\ngit push --force\nEOF\n. ./x.sh' \
        $'cat > x.sh <<\'EOF\'\ngit push --force\nEOF\n"bash" x.sh' \
        $'cat > x.sh <<\'EOF\'\ngit push --force\nEOF\npython3 x.sh' \
        $'cat > x.sh <<\'EOF\'\ngit push --force\nEOF\nenv bash x.sh' \
        $'cat > Makefile <<\'EOF\'\npush:\n\tgit push --force\nEOF\nmake push' \
        $'cat > .git/hooks/pre-commit <<\'EOF\'\ngit push --force\nEOF\ngit commit -q -m x' \
        $'cat > notes.md <<EOF\n$(git push --force)\nEOF' \
        $'cat > notes.md <<EOF\n`git push --force`\nEOF' \
        $'git commit -q -F - <<EOF\nfix `git push --force`\nEOF' \
        $'cat <<\'EOF\' | bash\ngit push --force\nEOF' \
        $'bash <<\'EOF\'\ngit push --force\nEOF'; do
      guard 2 "$cmd"
    done
    guard 2 $'cat > x.ps1 <<\'EOF\'\ngit push --force\nEOF\n& ./x.ps1' PowerShell
  fi
  guard_run
  guard_report "$git_fail" "the guard hook reads a commit's or tag's message, or a cat or tee body that nothing in the command runs, as a script (B40), or passes a body a shell runs" "the guard hook passes a commit's or tag's message and a cat or tee body that the command doesn't run, and blocks a body written to a file and run in the same command (B40)"

  # A gh message with a quoted delimiter (B48): gh pr create and edit, issue create, edit and comment, and release create and edit
  # take the body from stdin (--body-file -, -F -, --notes-file -) or from a $(cat <<'EOF') given to --body, -b, --notes or -n. That
  # body is text no shell runs, as a commit's message is (B40), so the destructive rules skip it, and the variable rules (B37)
  # skip it and a cat body nothing runs. A body a shell runs, an unquoted body with a substitution, a git command that goes on past
  # the body, or a body piped to a shell is still read.
  git_fail=""
  if [ -f .claude/hooks/guard-git.sh ]; then
    for cmd in \
        $'gh pr edit 5 --body-file - <<\'EOF\'\nfix: git push --force; done\nEOF' \
        $'gh pr create --body "$(cat <<\'EOF\'\nfix: git push --force\nEOF\n)"' \
        $'gh pr create --title t --body-file - <<\'EOF\'\nDo not run git push --force\nEOF' \
        $'gh issue comment 5 -F - <<\'EOF\'\ngit reset --hard\nEOF' \
        $'gh issue create -b "$(cat <<\'EOF\'\ngit branch -D x\nEOF\n)"' \
        $'gh release create v1 --notes-file - <<\'EOF\'\ngit push --mirror\nEOF' \
        $'gh release edit v1 -n "$(cat <<\'EOF\'\ngit push --delete origin x\nEOF\n)"' \
        $'gh pr create --body-file=- <<\'EOF\'\ngit push --force\nEOF' \
        $'GH pr create -F- <<\'EOF\'\ngit push --force\nEOF' \
        $'gh pr create --body="$(cat <<\'EOF\'\ngit push --force\nEOF\n)"' \
        $'gh pr edit 5 --body-file - <<\'EOF\'\ngit push --force\nEOF' \
        $'gh pr create --body-file - <<\'EOF\'\nbash -c \'git push --force\'\nEOF' \
        $'gh pr create --body-file - <<\'EOF\'\necho cmd /c "git push --force"\nEOF' \
        $'gh pr edit 5 --body-file - <<\'EOF\'\nfix: git push $X handling\nEOF' \
        $'git commit -q -F - <<\'EOF\'\nfix: git push $X handling\nEOF' \
        $'git tag -a v1 -F - <<\'EOF\'\nfix: git push $X handling\nEOF' \
        $'cat > notes.md <<\'EOF\'\nfix: git push $X handling\nEOF'; do
      guard 0 "$cmd"
    done
    for cmd in \
        $'gh pr edit 5 --body-file - <<\'EOF\' && git push --force\nmsg\nEOF' \
        $'gh pr create --body-file - <<\'EOF\'\nmsg\nEOF\ngit push --force' \
        $'gh pr create --body-file - <<\'EOF\' | bash\ngit push --force\nEOF' \
        $'gh pr create --body-file - <<EOF\nfix: git push --force\nEOF' \
        $'gh pr create --body "$(cat <<EOF\n$(git push --force)\nEOF\n)"' \
        $'gh pr create --body "$(cat <<\'EOF\'\nmsg\nEOF\n)" --title "$(git push --force)"' \
        $'bash <<\'EOF\'\ngit push $X\nEOF' \
        $'cat > x.sh <<\'EOF\'\ngit push $X\nEOF\nbash x.sh'; do
      guard 2 "$cmd"
    done
    # A shell or PowerShell name right after a word that only prints its words (echo, printf, Write-Output, Write-Host, write) is
    # text (B48). Anywhere else it may run a script, so a launcher's argument stays read: ssh, find -exec, docker exec, Start-Process.
    for cmd in \
        "echo PowerShell 'git push --force'" \
        "echo pwsh 'git push --force'" \
        "echo bash -c 'git push --force'" \
        'echo sh -c "git push --force"' \
        $'printf sh -c \'git push --force\'' \
        $'echo eval \'git push --force\'' \
        'echo PowerShell -Command "git push --force"'; do
      guard 0 "$cmd"
    done
    for cmd in \
        'ssh host pwsh -c "git push --force"' \
        'find . -exec pwsh -c "git push --force" \;' \
        'docker exec ctr pwsh -c "git push --force"' \
        'ssh host sh -c "git push --force"' \
        'find . -exec sh -c "git push --force" \;' \
        $'docker exec ctr bash -c \'git push --force\''; do
      guard 2 "$cmd"
    done
    for cmd in \
        'Write-Output PowerShell -Command "git push --force"' \
        "Write-Output powershell 'git push --force'" \
        "echo pwsh 'git push --force'" \
        "Write-Host Pwsh.exe 'git push --force'"; do
      guard 0 "$cmd" PowerShell
    done
    for cmd in \
        "Start-Process powershell -ArgumentList 'git push --force'" \
        'ssh host pwsh -c "git push --force"' \
        'timeout 60 powershell -c "git push --force"'; do
      guard 2 "$cmd" PowerShell
    done
  fi
  guard_run
  guard_report "$git_fail" "the guard hook reads a gh message's body, or a variable in a message or a cat body nothing runs, as a command, passes a body a shell runs, or reads a word after echo, printf, Write-Output, Write-Host or write, or a launcher's argument, wrongly (B48)" "the guard hook passes a gh pr, issue or release message with a quoted delimiter, and a variable in a message or in a cat body nothing runs, and blocks a git command after a message, an unquoted message, a message piped to a shell, and a variable in a body a shell runs; a shell or PowerShell name after echo, printf, Write-Output, Write-Host or write is text, and one that a launcher passes a script to is read (B48)"
  # The PowerShell tool (B24) has its own name. The guard runs for it only when a PreToolUse matcher that runs guard-git.sh
  # names it (settings.json has one entry each for Bash, Monitor and PowerShell), and a Bash(...) deny or ask rule stops the
  # same command in PowerShell only through its PowerShell(...) twin, in the same list. The allow list names no PowerShell
  # command, so nothing PowerShell runs is allowed without a prompt. Read(...) rules are the Read tool's; PowerShell's own
  # file reads are the guard's (the credential-store cases above).
  ps_fail=""
  guard_matchers=$(awk -F'"' '/"matcher"/ { m = $4 } /guard-git\.sh/ { print m }' .claude/settings.json)
  for tool in Bash Monitor PowerShell; do
    hit=0
    while IFS= read -r m; do
      case "|$m|" in *"|$tool|"*) hit=1 ;; esac
    done <<< "$guard_matchers"
    [ "$hit" -eq 1 ] || ps_fail="$ps_fail"$'\n'"  no PreToolUse matcher that runs guard-git.sh names $tool (matchers: ${guard_matchers//$'\n'/, })"
  done
  for list in deny ask; do
    arr=$(sed -n "/\"$list\": *\[/,/\]/p" .claude/settings.json)
    while IFS= read -r rule; do
      [ -n "$rule" ] || continue
      twin="PowerShell(${rule#Bash(}"
      printf '%s\n' "$arr" | grep -qF "\"$twin\"" \
        || ps_fail="$ps_fail"$'\n'"  settings.json's $list rules have $rule but no $twin"
    done <<< "$(printf '%s\n' "$arr" | grep -oE '"Bash\([^"]*\)"' | tr -d '"')"
  done
  printf '%s\n' "$perm_allow" | grep -q 'PowerShell(' \
    && ps_fail="$ps_fail"$'\n'"  settings.json's allow list names a PowerShell command, so PowerShell would run it without a prompt"
  guard_report "$ps_fail" "the PowerShell tool isn't wired to the guard and the deny and ask rules (B24)" "a matcher that runs the guard hook names Bash, Monitor and PowerShell, every Bash deny and ask rule has a PowerShell twin, and the allow list names no PowerShell command"
fi

}

l_guard2() {
lane_game base
guard_dir="$work/guard-cases"; mkdir -p "$guard_dir"; git_fail=""
# --- protected-space guard (Claude Code PreToolUse hook) ----------------------------------------
# Claude Code sends the path as given: relative, absolute POSIX, or Windows (JSON-escaped). The
# project root is $CLAUDE_PROJECT_DIR (the Windows cases pass a made-up root; the hook only reads text).
echo "protected-space guard"
guard_write 2 "relative director/x" 'director/x'
guard_write 2 "./director/x" './director/x'
guard_write 2 "x/../director/y" 'x/../director/y'
guard_write 2 "absolute POSIX <root>/director/x" "$game/director/x"
guard_write 2 "Windows C:\\...\\director\\x (escaped backslashes)" 'C:\\git\\Proj\\director\\x' 'C:\git\Proj'
guard_write 2 "Windows C:/.../director/x" 'C:/git/Proj/director/x' 'C:\git\Proj'
guard_write 2 "Git Bash /c/.../director/x" '/c/git/Proj/director/x' 'C:\git\Proj'
guard_write 2 "Windows path, project root given in Git Bash form" 'C:\\git\\Proj\\director\\x' '/c/git/Proj'
guard_write 0 "relative docs/director-notes.md" 'docs/director-notes.md'
guard_write 0 "absolute <root>/docs/director-notes.md" "$game/docs/director-notes.md"
guard_write 0 "relative src/director/x.gd (nested folder)" 'src/director/x.gd'
guard_write 0 "absolute <root>/src/director/x.gd (nested folder)" "$game/src/director/x.gd"
guard_write 0 "outside the project root" '/nonexistent/elsewhere/director/x'
guard_write 0 "Windows path outside the project root" 'D:\\other\\director\\x' 'C:\git\Proj'
guard_write 0 "Windows sibling folder with the root's name as a prefix" 'C:\\git\\Proj-old\\director\\x' 'C:\git\Proj'
guard_write 0 "../director/x (outside the project root)" '../director/x'
out="$(printf '%s' '{"tool_name":"Edit","tool_input":{"file_path":"director/x"}}' | env -u CLAUDE_PROJECT_DIR bash .claude/hooks/guard-protected.sh 2>&1)"
got=$?
if [ "$got" -eq 2 ]; then ok "blocks a relative path against the current directory when CLAUDE_PROJECT_DIR is unset"; else bad "guard-protected without CLAUDE_PROJECT_DIR exit $got, expected 2" "$out"; fi

# --- user stories -------------------------------------------------------------------------------
echo "user stories"
# tools/stories.sh --due reads the project rule first: with the stories off, or the rule unanswered (the
# seed's examples sit in a comment), they are never due. With them on, it counts built items from the
# commit on the stories file's Last validated line (by its date when that commit isn't in the history),
# and is due when the stories were never validated. The template stands in for a game's file.
guard 0 'bash tools/stories.sh --due'
guard_run
guard_report "$git_fail" "the guard hook blocks bash tools/stories.sh --due" "the guard hook allows bash tools/stories.sh --due"
out="$(bash tools/stories.sh --due 2>&1)"; status=$?
expect_status "stories --due exits 0 in Market Day, which uses them" 0 "$status" "$out"
expect_output "and counts by the date of its Last validated line, whose commit isn't in this history" \
  "^stories: not due: built items since the last validation \(2026-09-28, by its date: its commit isn't in this history\): 0, \[stories\] every = 10; 5 stories, 0 unconfirmed$" "$out"
_st="$work/stories"; new_repo "$_st"; mkdir -p "$_st/tools" "$_st/design"
cp "$src/framework/tools/stories.sh" "$_st/tools/"; cp "$src/project/AGENTS.md" "$_st/AGENTS.md"
cp "$stories_tpl" "$_st/design/user-stories.md"
out="$(cd "$_st" && bash tools/stories.sh --due 2>&1)"; status=$?
expect_status "stories --due exits 0 while the game hasn't answered" 0 "$status" "$out"
expect_output "and says they are off, reading past the seed's commented example rule" \
  "^stories: not due: user stories are off \(AGENTS\.md › Project rules has no User stories line\)$" "$out"
_st_rule() { # <the User stories value>: AGENTS.md with only that rule
  printf '# Game\n\n## Project rules\n- No git remote: never push.\n- User stories: %s\n' "$1" > "$_st/AGENTS.md"
}
_st_rule off
out="$(cd "$_st" && bash tools/stories.sh --due 2>&1)"
expect_output "stories --due: off is never due, even with a stories file never validated" \
  "^stories: not due: user stories are off \(AGENTS\.md › Project rules: User stories: off\)$" "$out"
_st_rule sometimes
out="$(cd "$_st" && bash tools/stories.sh --due 2>&1)"
expect_output "stories --due reads a value that isn't on or off as off, and names it" "^stories: not due: user stories are off \(.*User stories: sometimes, which isn't on or off\)$" "$out"
printf '# Game\r\n\r\n## Project rules\r\n- User stories: on\r\n' > "$_st/AGENTS.md"
rm -f "$_st/design/user-stories.md"
out="$(cd "$_st" && bash tools/stories.sh --due 2>&1)"
expect_output "stories --due: on (in a CRLF AGENTS.md), not due without a stories file" \
  "^stories: not due: no stories yet \(no design/user-stories\.md\), \[stories\] every = 10$" "$out"
printf -- '# Game\n\n<!-- a comment\n- User stories: off\n-->\n- **User stories:** on <!-- decided 2026-11-02 -->\n' > "$_st/AGENTS.md"
out="$(cd "$_st" && bash tools/stories.sh --due 2>&1)"
expect_output "stories --due reads a bold key with a comment after the value, past a commented-out rule, as on" \
  "^stories: not due: no stories yet \(no design/user-stories\.md\)" "$out"
_st_rule on
printf '# User stories: x\n\n**Next ID:** US-1 · **Last validated:** never\n\n## Roles\n' > "$_st/design/user-stories.md"
out="$(cd "$_st" && bash tools/stories.sh --due 2>&1)"
expect_output "stories --due: not due while the file has no stories" "^stories: not due: no stories yet in design/user-stories\.md" "$out"
cp "$stories_tpl" "$_st/design/user-stories.md"
_st_total="$(grep -c '^| US-' "$stories_tpl")"; _st_unc="$(grep -c '| unconfirmed |$' "$stories_tpl")"
out="$(cd "$_st" && bash tools/stories.sh --due 2>&1)"
expect_output "stories --due: due when never validated, counting the stories and the unconfirmed ones" \
  "^stories: due: never validated \(Last validated: never\), $_st_total stories, $_st_unc unconfirmed, \[stories\] every = 10$" "$out"
(cd "$_st" && for i in 1 2 3; do git_q commit -q --allow-empty -m "feat: item (T$i)"; done && git_q commit -q --allow-empty -m "docs: note (R1)")
printf '[stories]\n; how often\nevery=3 ; items\n' > "$_st/tools/check.cfg"
_st_validated() { # <the Last validated value>
  sed "s/\*\*Last validated:\*\* never/**Last validated:** $1/" "$stories_tpl" > "$_st/design/user-stories.md"
}
_st_validated "2026-01-01 at \`$(cd "$_st" && git rev-parse --short HEAD~2)\`"
out="$(cd "$_st" && bash tools/stories.sh --due 2>&1)"
expect_output "stories --due counts from the Last validated commit, research items left out" \
  "^stories: not due: built items since the last validation \(2026-01-01, commit [0-9a-f]+\): 1, \[stories\] every = 3; $_st_total stories, $_st_unc unconfirmed$" "$out"
(cd "$_st" && git_q commit -q --allow-empty -m "feat: squashed item (T4) (#12)" && git_q commit -q --allow-empty -m "fix: squashed bug (B2) (#13)")
out="$(cd "$_st" && bash tools/stories.sh --due 2>&1)"
expect_output "stories --due counts squash-merge subjects and is due at [stories] every=3" "^stories: due: built items since the last validation \(2026-01-01, commit [0-9a-f]+\): 3, \[stories\] every = 3" "$out"
(cd "$_st" && git_q commit -q --allow-empty -m "fix: B5 is mentioned (B5) but not at the end")
out="$(cd "$_st" && bash tools/stories.sh --due 2>&1)"
expect_output "stories --due ignores an item ID that doesn't end the subject" ": 3, \[stories\] every = 3" "$out"
_st_validated "2000-01-01 at \`0000000\`"
out="$(cd "$_st" && bash tools/stories.sh --due 2>&1)"
expect_output "stories --due counts by the date when the commit isn't in this history" \
  "^stories: due: built items since the last validation \(2000-01-01, by its date: its commit isn't in this history\): 5, \[stories\] every = 3" "$out"
_st_validated "2000-01-01"
out="$(cd "$_st" && bash tools/stories.sh --due 2>&1)"
expect_output "stories --due counts by the date when the line names no commit" \
  "^stories: due: built items since the last validation \(2000-01-01, by its date: the line names no commit\): 5, \[stories\] every = 3" "$out"
grep -v '^\*\*Next ID:\*\*' "$stories_tpl" > "$_st/design/user-stories.md"
out="$(cd "$_st" && bash tools/stories.sh --due 2>&1)"
expect_output "stories --due is due, and says why, when the file has no Last validated line" \
  "^stories: due: never validated \(design/user-stories\.md has no Last validated line\), $_st_total stories" "$out"
printf '[stories]\nevery="often"\n' > "$_st/tools/check.cfg"
out="$(cd "$_st" && bash tools/stories.sh --due 2>&1)"
expect_output "stories --due notes a setting that isn't a whole number and uses 10" "^stories: note: \[stories\] every = often isn't a whole number of 1 or more; using 10" "$out"
out="$(cd "$_st" && bash tools/stories.sh 2>&1)"; status=$?
expect_status "stories.sh without --due exits 3" 3 "$status" "$out"
# Outside a git repository (git isn't allowed to look above $work for one) it can't count, and says so;
# with the stories off it needs no repository.
_st_nogit="$work/stories-nogit"; mkdir -p "$_st_nogit/tools" "$_st_nogit/design"
cp "$src/framework/tools/stories.sh" "$_st_nogit/tools/"; cp "$stories_tpl" "$_st_nogit/design/user-stories.md"; cp "$_st/AGENTS.md" "$_st_nogit/"
out="$(cd "$_st_nogit" && GIT_CEILING_DIRECTORIES="$work" bash tools/stories.sh --due 2>&1)"; status=$?
expect_status "stories --due exits 3 outside a git repository" 3 "$status" "$out"
expect_output "and says it couldn't count" "^stories: couldn't count: not a git repository$" "$out"
printf -- '- User stories: off\n' > "$_st_nogit/AGENTS.md"
out="$(cd "$_st_nogit" && GIT_CEILING_DIRECTORIES="$work" bash tools/stories.sh --due 2>&1)"; status=$?
expect_status "with the stories off it exits 0 there, needing no repository" 0 "$status" "$out"

}

l_setup() {
lane_game base
# --- per-clone setup ----------------------------------------------------------------------------
echo "setup-clone"
out="$(GODOT_BIN=/nonexistent/godot bash tools/check.sh 2>&1)"; expect_status "the check exits 3 without Godot" 3 $? "$out"
# A Godot older than the minimum, 4.5: a stand-in that only prints its version.
printf '#!/usr/bin/env bash\necho 4.4.1.stable.official.49a5bc7b6\n' > "$work/godot-4.4" && chmod +x "$work/godot-4.4"
out="$(GODOT_BIN="$work/godot-4.4" bash tools/check.sh 2>&1)"; expect_status "the check exits 3 with Godot 4.4" 3 $? "$out"
expect_output "and says it needs Godot 4.5 or newer" "needs Godot 4\.5 or newer" "$out"
out="$(GODOT_BIN="$work/godot-4.4" bash tools/ui_capture.sh --list 2>&1)"; expect_status "capture exits 3 with Godot 4.4" 3 $? "$out"
out="$(GODOT_BIN="$work/godot-4.4" bash tools/autoplay.sh smoke --no-images 2>&1)"; expect_status "autoplay exits 3 with Godot 4.4" 3 $? "$out"
out="$(bash tools/setup-clone.sh --skip-hook "$work/godot-4.4" 2>&1)"; expect_status "setup-clone refuses Godot 4.4" 3 $? "$out"
expect_output "and says it needs 4.5 or newer" "need 4\.5 or newer" "$out"
out="$(bash tools/setup-clone.sh "$godot" 2>&1)"; expect_status "setup-clone succeeds" 0 $? "$out"
grep -qs "Godot Director" "$(git rev-parse --git-path hooks)/pre-commit" && ok "installs the pre-commit hook" || bad "installs the pre-commit hook" "$out"
[ -z "$(git config --get core.hooksPath)" ] && ok "leaves core.hooksPath alone (Git LFS keeps working)" || bad "leaves core.hooksPath alone"
# A path saved by PowerShell: UTF-8 BOM, trailing spaces, CRLF.
printf '\357\273\277%s  \r\n' "$godot" > tools/godot_bin.local
}

l_check_import_a() {
lane_game ready
# --- the check ----------------------------------------------------------------------------------
echo "check"
out="$(bash tools/check.sh 2>&1)"; status=$?
expect_status "passes on a fresh clone of the example (Godot path with BOM and spaces)" 0 "$status" "$out"
expect_output "runs the example's tests" "12 tests passed" "$out"
expect_output "scans the screen scripts" "1 screen script scanned" "$out"
expect_no_output "reports no missing hook" "no Godot Director pre-commit hook" "$out"
out="$(bash tools/check.sh --if-changed 2>&1)"; expect_output "--if-changed reuses the last pass" "nothing changed since the last passing run" "$out"
# The import pass: a second run skips it, --import forces it, a fresh import cache runs it, and a new
# asset runs it again (then the next run skips it once more).
out="$(bash tools/check.sh 2>&1)"; status=$?
expect_status "a second check passes" 0 "$status" "$out"
expect_output "and skips the import pass when no imported file changed" "check: import pass skipped \(no imported file changed\)" "$out"
out="$(bash tools/check.sh --import 2>&1)"; status=$?
expect_status "--import runs the import pass and passes" 0 "$status" "$out"
expect_no_output "and doesn't skip it" "import pass skipped" "$out"
}

l_check_import_b() {
lane_game warm
rm -rf .godot/imported
out="$(bash tools/check.sh 2>&1)"; status=$?
expect_status "a check without an import cache passes" 0 "$status" "$out"
expect_no_output "and doesn't skip the import pass" "import pass skipped" "$out"
mkdir -p assets && printf '%s\n' '<svg xmlns="http://www.w3.org/2000/svg" width="8" height="8"><rect width="8" height="8" fill="#c33"/></svg>' > assets/selftest_marker.svg
out="$(bash tools/check.sh 2>&1)"; status=$?
expect_status "a new asset passes the check" 0 "$status" "$out"
expect_no_output "a new asset makes the check run the import pass" "import pass skipped" "$out"
out="$(bash tools/check.sh 2>&1)"; expect_output "and the check after that skips it again" "import pass skipped" "$out"
rm -rf assets
# A new script with a class_name that another script uses runs the import pass (the class cache must
# learn it, or the user's script fails with "Identifier not found"); a body-only edit still skips.
printf 'class_name SelftestHelper\nextends RefCounted\n\nstatic func answer() -> int:\n\treturn 42\n' > scripts/selftest_helper.gd
printf 'extends RefCounted\n\nfunc value() -> int:\n\treturn SelftestHelper.answer()\n' > scripts/selftest_user.gd
out="$(bash tools/check.sh 2>&1)"; status=$?
expect_status "a new class_name used by another script passes the check" 0 "$status" "$out"
expect_no_output "and the check runs the import pass for it" "import pass skipped" "$out"
printf '\n# a body-only edit\n' >> scripts/selftest_helper.gd
out="$(bash tools/check.sh 2>&1)"; status=$?
expect_status "a body-only edit passes the check" 0 "$status" "$out"
expect_output "and the check skips the import pass for it" "import pass skipped" "$out"
rm -f scripts/selftest_helper.gd scripts/selftest_helper.gd.uid scripts/selftest_user.gd scripts/selftest_user.gd.uid

}

l_check_faults_a() {
lane_game warm
fault() { # fault <what> <file> <text to append> <regex the output must contain>
  cp "$2" "$work/saved"
  printf '%s\n' "$3" >> "$2"
  out="$(bash tools/check.sh 2>&1)"; status=$?
  expect_status "fails on $1" 1 "$status" "$out"
  expect_output "names the cause of $1" "$4" "$out"
  cp "$work/saved" "$2"
}
fault "a parse error" scripts/systems/market.gd 'func broken( -> void:' 'market\.gd'
fault "an untyped declaration" scripts/systems/market.gd "$(printf '\nfunc untyped(value):\n\treturn value')" 'market\.gd'
fault "randomness in a screen" scripts/ui/shop_screen.gd "$(printf '\nfunc _roll() -> int:\n\treturn randi()')" 'screen script does .randi'
fault "a screen assigning to an autoload" scripts/ui/shop_screen.gd "$(printf '\nfunc _cheat() -> void:\n\tRunState.gold = 999')" 'RunState\.gold'
}

l_check_faults_b() {
lane_game warm
fault() { # fault <what> <file> <text to append> <regex the output must contain>
  cp "$2" "$work/saved"
  printf '%s\n' "$3" >> "$2"
  out="$(bash tools/check.sh 2>&1)"; status=$?
  expect_status "fails on $1" 1 "$status" "$out"
  expect_output "names the cause of $1" "$4" "$out"
  cp "$work/saved" "$2"
}
fault "a failing test" tests/test_market.gd "$(printf '\nfunc test_selftest_failure() -> void:\n\texpect_eq(1, 2)')" 'expected 2, got 1'
fault "an async test" tests/test_market.gd "$(printf '\nfunc test_selftest_async() -> void:\n\tawait Engine.get_main_loop().process_frame\n\texpect(true)')" 'must be synchronous'
fault "a runtime error in a test" tests/test_market.gd "$(printf '\nfunc test_selftest_crash() -> void:\n\tvar node: Node = null\n\tnode.get_name()')" 'SCRIPT ERROR'
# A view the game only loads when it opens (nothing references it) with a compile error: the check
# loads every script and scene, so it fails anyway.
printf 'extends Control\n\nfunc _on_open() -> void:\n\tvar count: int = "three"\n\tprint(count)\n' > scripts/ui/lazy_view.gd
printf '[gd_scene load_steps=2 format=3]\n\n[ext_resource type="Script" path="res://scripts/ui/lazy_view.gd" id="1"]\n\n[node name="LazyView" type="Control"]\nscript = ExtResource("1")\n' > scenes/lazy_view.tscn
out="$(bash tools/check.sh 2>&1)"; expect_status "fails on a compile error in a view that only loads when it opens" 1 $? "$out"
expect_output "names the view's line" 'lazy_view\.gd:4' "$out"
rm -f scripts/ui/lazy_view.gd scripts/ui/lazy_view.gd.uid scenes/lazy_view.tscn
cp data/market_config.tres "$work/saved"
sed 's|scripts/resources/market_config\.gd|scripts/resources/renamed.gd|' "$work/saved" > data/market_config.tres
out="$(bash tools/check.sh 2>&1)"; expect_status "fails on a resource whose script was renamed" 1 $? "$out"
cp "$work/saved" data/market_config.tres

}

l_check_misc_a() {
lane_game warm
# Known screen violations pass with a note; other frameworks' tests are skipped.
cp scripts/ui/shop_screen.gd "$work/saved-screen"; cp tools/check.cfg "$work/saved-cfg"
printf '\nfunc _roll() -> int:\n\treturn randi()\n' >> scripts/ui/shop_screen.gd
sed 's|^known=\[\]|known=["scripts/ui/shop_screen.gd"]|' "$work/saved-cfg" > tools/check.cfg
grep -q '^known=\[' tools/check.cfg || printf '\n[screens]\nknown=["scripts/ui/shop_screen.gd"]\n' >> tools/check.cfg
mkdir -p addons/gut && printf 'extends RefCounted\n' > addons/gut/test.gd
printf 'extends "res://addons/gut/test.gd"\n\nfunc test_gut_style() -> void:\n\tpass\n' > tests/test_gut_style.gd
out="$(bash tools/check.sh 2>&1)"; status=$?
expect_status "passes with a known screen violation and a GUT-style test" 0 "$status" "$out"
expect_output "notes the known violation" "known: listed in tools/check.cfg" "$out"
expect_output "leaves GUT-style tests to check.local.sh" "another test framework" "$out"
cp "$work/saved-screen" scripts/ui/shop_screen.gd; cp "$work/saved-cfg" tools/check.cfg
rm -rf addons tests/test_gut_style.gd tests/test_gut_style.gd.uid

# A screen that only names an autoload's inner type isn't writing to the autoload.
cp scripts/autoload/run_state.gd "$work/saved-state"; cp scripts/ui/shop_screen.gd "$work/saved-screen"
printf '\nenum Phase { OPEN, CLOSED }\n' >> scripts/autoload/run_state.gd
printf '\nvar _phase: RunState.Phase = RunState.Phase.OPEN\n' >> scripts/ui/shop_screen.gd
out="$(bash tools/check.sh 2>&1)"; expect_status "doesn't mistake a type annotation for a write to an autoload" 0 $? "$out"
cp "$work/saved-state" scripts/autoload/run_state.gd; cp "$work/saved-screen" scripts/ui/shop_screen.gd

# Autoloads guard player data with the check's meta, and tests mark the errors they expect; the
# 2.x names stay accepted until 4.0.
printf 'extends "res://tools/test_case.gd"\n\nfunc test_check_meta() -> void:\n\texpect(Engine.has_meta("godot_director_check"))\n\texpect(Engine.has_meta("claude4godot_check"))\n\nfunc test_ignore_markers() -> void:\n\tprint("GDIR-IGNORE:selftest expected error one")\n\tpush_error("selftest expected error one")\n\tprint("C4G-IGNORE:selftest expected error two")\n\tpush_error("selftest expected error two")\n' > tests/test_selftest_meta.gd
out="$(bash tools/check.sh 2>&1)"; status=$?
expect_status "accepts expected errors marked GDIR-IGNORE, or C4G-IGNORE as in 2.x" 0 "$status" "$out"
expect_output "sets the check meta under the new and the deprecated 2.x name" "14 tests passed" "$out"
rm -f tests/test_selftest_meta.gd tests/test_selftest_meta.gd.uid

}

l_check_misc_b() {
lane_game warm
out="$(bash tools/check.sh 2>&1)"; expect_status "passes again after the faults are removed" 0 $? "$out"

# --only: one test file, the supported way to run it (the guard refuses a direct Godot run past
# 280 s, and builders wrote runner scripts). It never records a result for --if-changed.
echo "one test file (--only)"
last_pass_before="$(cat .godot/godot-director/last-pass 2>/dev/null)"
out="$(bash tools/check.sh --only tests/test_market.gd 2>&1)"; expect_status "--only runs one test file" 0 $? "$out"
expect_output "and says it ran only that file" "check: PASS \(tests/test_market\.gd: [0-9]+ tests? passed; only these files" "$out"
expect_no_output "with no load pass, screen rules or slowest files" "screen script|slowest test files|running tools/check.local.sh" "$out"
out="$(cd tests && bash ../tools/check.sh --only test_play_log.gd --only res://tests/test_dev_menu.gd 2>&1)"
expect_status "--only takes several files, from the caller's folder or res://" 0 $? "$out"
expect_output "and names them" "check: PASS \(tests/test_play_log\.gd tests/test_dev_menu\.gd: " "$out"
[ "$(cat .godot/godot-director/last-pass 2>/dev/null)" = "$last_pass_before" ] \
  && ok "--only leaves the result --if-changed repeats as it was" || bad "--only changed last-pass" "$(cat .godot/godot-director/last-pass 2>/dev/null)"
cp tests/test_market.gd "$work/saved-only"
printf '\nfunc test_selftest_only_failure() -> void:\n\texpect_eq(1, 2)\n' >> tests/test_market.gd
out="$(bash tools/check.sh --only tests/test_market.gd 2>&1)"; expect_status "--only fails on a failing test" 1 $? "$out"
expect_output "and names it" "test_market\.gd::test_selftest_only_failure: expected 2, got 1" "$out"
printf '\nfunc test_selftest_only_broken() -> void:\n\tvar n: int = "x"\n' >> tests/test_market.gd
out="$(bash tools/check.sh --only tests/test_market.gd 2>&1)"; expect_status "--only fails on a test file that doesn't compile" 1 $? "$out"
expect_output "and says so" "test_market\.gd: test script doesn't compile" "$out"
cp "$work/saved-only" tests/test_market.gd
out="$(bash tools/check.sh --only tests/test_nope.gd 2>&1)"; expect_status "--only refuses a file that isn't there" 3 $? "$out"
out="$(bash tools/check.sh --only README.md 2>&1)"; expect_status "--only refuses a file that isn't a .gd script" 3 $? "$out"
out="$(bash tools/check.sh --only 2>&1)"; expect_status "--only needs a file" 3 $? "$out"
out="$(bash tools/check.sh --if-changed --only tests/test_market.gd 2>&1)"; expect_status "--only runs on its own, not with --if-changed" 3 $? "$out"
grep -q 'check\.sh --only' .godot-director/procedures/build.md && grep -q 'check\.sh --only' .godot-director/rules.md \
  && grep -q 'check\.sh --only' .claude/agents/builder.md && grep -q 'check\.sh --only' .claude/hooks/guard-git.sh \
  && ok "the build procedure, the rules, the builder agent and the guard's refusal name --only" \
  || bad "the build procedure, the rules, the builder agent and the guard's refusal name --only"

}

l_par_a() {
lane_game warm
# --- parallel tests, per-file times, timeout ----------------------------------------------------
echo "parallel tests"
parallel_prelude
out="$(bash tools/check.sh --jobs 1 2>&1)"; expect_status "--jobs 1 runs the tests in one process" 0 $? "$out"
expect_output "and runs all of the example's tests" "12 tests passed" "$out"
expect_no_output "with no group processes" "running the tests in" "$out"
expect_output "every run ends with the slowest test files" "slowest test files \(of 3, " "$out"
expect_output "each with its time and share" "[0-9]+\.[0-9] s +[0-9]+%  res://tests/test_market\.gd" "$out"
[ "$(tr -d '\r' < "$logs/check.log" | grep -cE '^GDIR-TIME: [0-9]+ res://tests/test_')" -eq 3 ] \
  && ok "the log lists each test file's time" || bad "the log lists each test file's time" "$(cat "$logs/check.log")"
serial_order="$(test_order "$logs/check.log")"
out="$(bash tools/check.sh --jobs 2 2>&1)"; expect_status "--jobs 2 passes on the example" 0 $? "$out"
expect_output "runs the tests in 2 processes" "running the tests in 2 processes" "$out"
expect_output "and merges the counts into the serial run's line" "12 tests passed · 1 screen script scanned" "$out"
expect_output "and the slowest files of both groups" "slowest test files \(of 3, " "$out"
[ -f "$logs/tests-1.log" ] && [ -f "$logs/tests-2.log" ] && [ -n "$(test_order "$logs/tests-2.log")" ] \
  && ok "each group has its own log" || bad "each group has its own log" "$(ls "$logs")"
[ -n "$serial_order" ] && [ "$(test_order "$logs/tests-1.log" "$logs/tests-2.log")" = "$serial_order" ] \
  && ok "the groups are contiguous, each in file order" || bad "the groups are contiguous, each in file order" "$(test_order "$logs/tests-1.log" "$logs/tests-2.log")"
out="$(bash tools/check.sh --if-changed --jobs 2 2>&1)"; expect_output "--if-changed works beside --jobs" "nothing changed since the last passing run" "$out"
out="$(bash tools/check.sh --jobs many 2>&1)"; expect_status "--jobs takes a number or auto" 3 $? "$out"
# A failing test in one group fails the merged report.
cp tests/test_market.gd "$work/saved"
printf '\nfunc test_selftest_failure() -> void:\n\texpect_eq(1, 2)\n' >> tests/test_market.gd
out="$(bash tools/check.sh --jobs 3 2>&1)"; expect_status "a failing test in one group fails the parallel run" 1 $? "$out"
expect_output "and names it" "test_market\.gd::test_selftest_failure: expected 2, got 1" "$out"
expect_no_output "and names no process that exited without an error line" "exited with" "$out"
cp "$work/saved" tests/test_market.gd
# Every run records the times. Without [tests] balance the deal is file order and nothing splits.
times="$logs/test-times.tsv"
[ -f "$times" ] && grep -qE '^res://tests/test_market\.gd	([0-9]+\.[0-9]{3})	1	[0-9]+\.[0-9]{3}$' "$times" \
  && ok "a whole run stores each test file's time, one shard and its time as the longest" || bad "a whole run stores each test file's time, one shard and its time as the longest" "$(cat "$times" 2>/dev/null)"
}

l_par_b1() {
lane_game warm
parallel_prelude
crash_defs
crashy "--import"
out="$(GODOT_BIN="$work/godot-crash" bash tools/check.sh --import --jobs 2 2>&1)"; expect_status "an import pass that crashes with a clean log fails the check" 1 $? "$out"
expect_output "names the import pass, its status and its log" "check: the import pass exited with 139 \(segmentation fault\) and printed no error; see \.godot/godot-director/import\.log" "$out"
before "$out" "printed no error" "^check: FAIL" && ok "and the FAIL follows it" || bad "and the FAIL follows it" "$out"
crashy "--no-tests"
out="$(GODOT_BIN="$work/godot-crash" bash tools/check.sh --jobs 2 2>&1)"; expect_status "a load pass that crashes with a clean log fails the check" 1 $? "$out"
expect_output "names the load pass, its status and its log" "check: the load pass \(tools/check\.gd --no-tests\) exited with 139 \(segmentation fault\) and printed no error; see \.godot/godot-director/check\.log" "$out"
before "$out" "printed no error" "^check: FAIL" && ok "and the FAIL follows it" || bad "and the FAIL follows it" "$out"
crashy "--tests 2 2"
out="$(GODOT_BIN="$work/godot-crash" bash tools/check.sh --jobs 2 2>&1)"; expect_status "a test group that crashes after its report fails the check" 1 $? "$out"
expect_output "names the group, its status and its log" "check: test group 2 of 2 exited with 139 \(segmentation fault\) and printed no error; see \.godot/godot-director/tests-2\.log" "$out"
before "$out" "printed no error" "^check: FAIL" && ok "and the FAIL follows it" || bad "and the FAIL follows it" "$out"
}

l_par_b2() {
lane_game warm
parallel_prelude
crash_defs
crashy "--tests 2 2" silent
out="$(GODOT_BIN="$work/godot-crash" bash tools/check.sh --jobs 2 2>&1)"; expect_status "a test group that crashes before its report fails the check" 1 $? "$out"
expect_output "names the group, its status and its log" "check: test group 2 of 2 exited with 139 \(segmentation fault\) and printed no error; see \.godot/godot-director/tests-2\.log" "$out"
expect_no_output "and doesn't also say it didn't finish" "didn't finish" "$out"
crashy "ui_capture.gd"
out="$(GODOT_BIN="$work/godot-crash" bash tools/check.sh --jobs 2 2>&1)"; expect_status "a layout lint that crashes with a clean log fails the check" 1 $? "$out"
expect_output "names the lint, its status and its log" "check: the layout lint \(tools/ui_capture\.gd --check\) exited with 139 \(segmentation fault\) and printed no error; see \.godot/godot-director/ui_lint\.log" "$out"
before "$out" "printed no error" "^check: FAIL" && ok "and the FAIL follows it" || bad "and the FAIL follows it" "$out"
crashy "tools/check.gd"
out="$(GODOT_BIN="$work/godot-crash" bash tools/check.sh --jobs 1 2>&1)"; expect_status "a serial run whose check crashes with a clean log fails the check" 1 $? "$out"
expect_output "names the check, its status and its log" "check: tools/check\.gd exited with 139 \(segmentation fault\) and printed no error; see \.godot/godot-director/check\.log" "$out"
}

l_fail_reason() {
lane_game warm
parallel_prelude
crash_defs
printf '\n[tests]\njobs=2\n' >> tools/check.cfg
# --- a failing run says why, and a repeat says it again -----------------------------------------
echo "failure reasons"
state=".godot/godot-director"
# A stand-in for Godot. Group 1 asks to ignore a line (GDIR-IGNORE) that group 2 reports as an error and then
# exits 139: the final scan allows that line away, so only the group's own line can name the failure.
cat > "$work/godot-hole" <<HOLE
#!/usr/bin/env bash
"$godot" "\$@"
status=\$?
case "\$*" in
  *"--tests 1 2"*) echo "GDIR-IGNORE:selftest hole line" ;;
  *"--tests 2 2"*) echo "ERROR: selftest hole line"; exit 139 ;;
esac
exit \$status
HOLE
# Group 1 prints a real leak at exit, an engine-noise leak, and more error lines than the saved reason holds.
cat > "$work/godot-leak" <<LEAK
#!/usr/bin/env bash
"$godot" "\$@"
status=\$?
case "\$*" in
  *"--tests 1 2"*)
    i=1; while [ \$i -le 30 ]; do echo "ERROR: selftest noise \$i"; i=\$((i + 1)); done
    echo "ERROR: 1 RID allocations of type 'Foo' were leaked at exit."
    echo "ERROR: 3 ObjectDB instances leaked at exit (run with --verbose for details)."
    ;;
esac
exit \$status
LEAK
chmod +x "$work/godot-hole" "$work/godot-leak"
fail_line="check: FAIL \(nothing changed since the last failing run; run 'bash tools/check.sh' to see why\)"
export GODOT_BIN="$work/godot-hole"
out="$(bash tools/check.sh 2>&1)"; status=$?
expect_status "a group that exits non-zero after its tests, whose error another group's GDIR-IGNORE allows, fails the check" 1 "$status" "$out"
expect_output "and names the group, its status and its log" "check: test group 2 of 2 exited 139 \(segmentation fault\) after its tests finished \(see \.godot/godot-director/tests-2\.log\)" "$out"
expect_no_output "with no error block, since the line was allowed away" "check: errors:" "$out"
[ "$(head -n 1 "$state/last-fail-reason")" = "$(cat "$state/last-fail")" ] \
  && ok "the saved reason starts with the key last-fail holds" || bad "the saved reason starts with the key last-fail holds" "$(cat "$state/last-fail-reason" 2>/dev/null)"
grep -q 'test group 2 of 2 exited 139' "$state/last-fail-reason" \
  && ok "and holds the line" || bad "and holds the line" "$(cat "$state/last-fail-reason" 2>/dev/null)"
out="$(bash tools/check.sh --if-changed 2>&1)"; status=$?
expect_status "--if-changed repeats the failure with exit 1" 1 "$status" "$out"
expect_output "keeps the FAIL line as it was" "^$fail_line\$" "$out"
expect_output "and prints the saved reason" "check: test group 2 of 2 exited 139 \(segmentation fault\) after its tests finished" "$out"
before "$out" "nothing changed since the last failing run" "test group 2 of 2 exited" && ok "after the FAIL line" || bad "after the FAIL line" "$out"
# A repeat that waits for a running check: the first look misses, and the saved reason is shown after the lock.
cp "$state/last-fail" "$work/saved-last-fail"; cp "$state/last-fail-reason" "$work/saved-last-fail-reason"
rm -f "$state/last-fail" "$state/last-fail-reason" "$work/waiter.status"
mkdir -p "$state/lock"
sleep 120 &
holder=$!
echo "$holder" > "$state/lock/pid"
( bash tools/check.sh --if-changed > "$work/waiter.out" 2>&1; echo $? > "$work/waiter.status" ) &
waited=0   # the saved result comes back only once the waiter has said it waits, so its first look missed
while ! grep -qs "waiting for another check" "$work/waiter.out" && [ "$waited" -lt 60 ]; do sleep 1; waited=$((waited + 1)); done
cp "$work/saved-last-fail" "$state/last-fail"; cp "$work/saved-last-fail-reason" "$state/last-fail-reason"
kill "$holder" 2>/dev/null; wait "$holder" 2>/dev/null
waited=0
while [ ! -f "$work/waiter.status" ] && [ "$waited" -lt 60 ]; do sleep 1; waited=$((waited + 1)); done
out="$(cat "$work/waiter.out" 2>/dev/null)"
expect_status "a repeat that waited for a running check exits 1" 1 "$(cat "$work/waiter.status" 2>/dev/null)" "$out"
expect_output "and says it waited" "waiting for another check to finish" "$out"
expect_output "and shows the saved reason after the lock too" "check: test group 2 of 2 exited 139 \(segmentation fault\) after its tests finished" "$out"
# A project upgraded from an older install has last-fail and no reason file.
rm -f "$state/last-fail-reason"
out="$(bash tools/check.sh --if-changed 2>&1)"; status=$?
expect_status "a last-fail with no reason file still repeats the failure" 1 "$status" "$out"
[ "$out" = "check: FAIL (nothing changed since the last failing run; run 'bash tools/check.sh' to see why)" ] \
  && ok "and prints just the FAIL line" || bad "and prints just the FAIL line" "$out"
# A reason saved for other files is not shown.
printf 'some other key\ncheck: stale reason\n' > "$state/last-fail-reason"
out="$(bash tools/check.sh --if-changed 2>&1)"
expect_no_output "a reason saved under another key isn't shown" "stale reason" "$out"
# The cap: leak and GDIR-FAIL lines are kept, the rest cut, and the cut is counted. Engine-noise leaks stay allowed.
export GODOT_BIN="$work/godot-leak"
out="$(bash tools/check.sh 2>&1)"; status=$?
expect_status "a leak at exit fails the check" 1 "$status" "$out"
expect_output "and is reported as an error" "ERROR: 1 RID allocations of type 'Foo' were leaked at exit" "$out"
expect_no_output "the engine-noise leak stays allowed" "ObjectDB instances leaked at exit" "$out"
lines="$(tail -n +2 "$state/last-fail-reason" | wc -l | tr -d ' ')"
[ "$lines" -le 21 ] && ok "the saved reason is capped" || bad "the saved reason is capped" "$lines lines"
grep -q "RID allocations of type 'Foo' were leaked at exit" "$state/last-fail-reason" \
  && ok "the leak line is kept past the cap" || bad "the leak line is kept past the cap" "$(cat "$state/last-fail-reason")"
grep -qE 'and [0-9]+ more reason lines' "$state/last-fail-reason" \
  && ok "and the saved reason says how many lines were left out" || bad "and the saved reason says how many lines were left out" "$(cat "$state/last-fail-reason")"
out="$(bash tools/check.sh --if-changed 2>&1)"
expect_output "a repeat shows the kept leak line" "RID allocations of type 'Foo' were leaked at exit" "$out"
# Process lines come first in the cap: 25 GDIR-FAIL lines and a group that crashed.
cat > "$work/godot-cap" <<CAP
#!/usr/bin/env bash
"$godot" "\$@"
status=\$?
case "\$*" in
  *"--tests 1 2"*) i=1; while [ \$i -le 25 ]; do echo "GDIR-FAIL: selftest finding \$i"; i=\$((i + 1)); done ;;
  *"--tests 2 2"*) exit 139 ;;
esac
exit \$status
CAP
chmod +x "$work/godot-cap"
export GODOT_BIN="$work/godot-cap"
out="$(bash tools/check.sh 2>&1)"; status=$?
expect_status "25 GDIR-FAIL lines and a crashed group fail the check" 1 "$status" "$out"
grep -q 'check: test group 2 of 2 exited with 139' "$state/last-fail-reason" \
  && ok "the saved reason keeps the line that names the crashed group" || bad "the saved reason keeps the line that names the crashed group" "$(cat "$state/last-fail-reason")"
lines="$(tail -n +2 "$state/last-fail-reason" | wc -l | tr -d ' ')"
[ "$lines" -le 21 ] && ok "and stays capped" || bad "and stays capped" "$lines lines"
grep -q 'GDIR-FAIL: selftest finding' "$state/last-fail-reason" \
  && grep -qE 'and [0-9]+ more reason lines' "$state/last-fail-reason" \
  && ok "with GDIR-FAIL lines after it and the count of what was left out" || bad "with GDIR-FAIL lines after it and the count of what was left out" "$(cat "$state/last-fail-reason")"
# When a process line is named. An ordinary failing test exits 1 and gets no line of its own; a status other than 1 is
# named at once, even with error lines in its log; status 1 is named only when another log's GDIR-IGNORE allowed
# its errors away.
exit_re="check: (tools/check\.gd|the load pass .*|test group [0-9]+ of [0-9]+) exited"
export GODOT_BIN="$work/godot-real"
cat > "$work/godot-real" <<REAL
#!/usr/bin/env bash
exec "$godot" "\$@"
REAL
chmod +x "$work/godot-real"
cp tests/test_market.gd "$work/saved-market-reason"
printf '\nfunc test_selftest_reason_failure() -> void:\n\texpect_eq(1, 2)\n' >> tests/test_market.gd
out="$(bash tools/check.sh --jobs 2 2>&1)"; status=$?
expect_status "an ordinary failing test fails a parallel run" 1 "$status" "$out"
expect_output "and the errors block names it" "test_market\.gd::test_selftest_reason_failure: expected 2, got 1" "$out"
expect_no_output "with no line for the exit of a process" "$exit_re" "$out"
out="$(bash tools/check.sh --jobs 1 2>&1)"; status=$?
expect_status "an ordinary failing test fails a serial run" 1 "$status" "$out"
expect_no_output "with no line for the exit of a process" "$exit_re" "$out"
grep -q ' exited ' "$state/last-fail-reason" && bad "and none in the saved reason" "$(cat "$state/last-fail-reason")" || ok "and none in the saved reason"
cp "$work/saved-market-reason" tests/test_market.gd
cat > "$work/godot-err139" <<ERR
#!/usr/bin/env bash
"$godot" "\$@"
status=\$?
case "\$*" in
  *"--tests 2 2"*) echo "ERROR: selftest real error"; exit 139 ;;
esac
exit \$status
ERR
cat > "$work/godot-hole1" <<HOLE1
#!/usr/bin/env bash
"$godot" "\$@"
status=\$?
case "\$*" in
  *"--tests 1 2"*) echo "GDIR-IGNORE:selftest hole line" ;;
  *"--tests 2 2"*) echo "ERROR: selftest hole line"; exit 1 ;;
esac
exit \$status
HOLE1
chmod +x "$work/godot-err139" "$work/godot-hole1"
export GODOT_BIN="$work/godot-err139"
out="$(bash tools/check.sh --jobs 2 2>&1)"; status=$?
expect_status "a group that exits 139 after its tests, with an error line in its log, fails the check" 1 "$status" "$out"
expect_output "the group is named" "check: test group 2 of 2 exited 139 \(segmentation fault\) after its tests finished" "$out"
expect_output "beside the errors block" "ERROR: selftest real error" "$out"
export GODOT_BIN="$work/godot-hole1"
out="$(bash tools/check.sh --jobs 2 2>&1)"; status=$?
expect_status "a group that exits 1 with its error allowed away by another group fails the check" 1 "$status" "$out"
expect_output "and is named, since no error is reported for it" "check: test group 2 of 2 exited 1 after its tests finished" "$out"
# The Stop hook and the pre-commit hook show the reason of a repeat.
export GODOT_BIN="$work/godot-hole"
git add -A && { git_q commit -qm "state for the reason tests" >/dev/null 2>&1 || true; }
printf '\n# a change for the reason tests\n' >> scripts/systems/market.gd
hook() { echo '{}' | CLAUDE_PROJECT_DIR="$game" bash .claude/hooks/stop-check.sh 2>&1; }
out="$(hook)"; status=$?
expect_status "the Stop hook blocks the failing change" 2 "$status" "$out"
rm -f "$state/last-reported"
out="$(hook)"; status=$?
expect_status "and blocks its repeat" 2 "$status" "$out"
expect_output "the Stop hook's repeat shows the FAIL line" "nothing changed since the last failing run" "$out"
expect_output "and the saved reason" "check: test group 2 of 2 exited 139 \(segmentation fault\) after its tests finished" "$out"
git add scripts/systems/market.gd
out="$(git_q commit -qm "failing" 2>&1)"; status=$?
expect_status "the pre-commit hook blocks the repeat" 1 "$status" "$out"
expect_output "and shows the FAIL line" "nothing changed since the last failing run" "$out"
expect_output "and the saved reason" "check: test group 2 of 2 exited 139 \(segmentation fault\) after its tests finished" "$out"
expect_output "and says the commit is blocked" "the check fails; commit blocked" "$out"
# A pass removes the reason with last-fail.
unset GODOT_BIN
git reset -q HEAD -- scripts/systems/market.gd
out="$(bash tools/check.sh 2>&1)"; expect_status "the same files pass with the real Godot" 0 $? "$out"
[ ! -f "$state/last-fail" ] && [ ! -f "$state/last-fail-reason" ] \
  && ok "a pass removes last-fail and its reason" || bad "a pass removes last-fail and its reason" "$(ls "$state")"
out="$(bash tools/check.sh --if-changed 2>&1)"
expect_no_output "and a repeat shows no reason" "check: test group" "$out"
}

l_par_c1() {
lane_game warm
parallel_prelude
printf 'res://tests/test_dev_menu.gd\t5\nres://tests/test_market.gd\t200\nres://tests/test_play_log.gd\t30\n' > "$times"
out="$(GDIR_CHECK_DEAL=1 bash tools/check.sh --jobs 3 2>&1)"; expect_status "with no balance setting, --jobs 3 passes" 0 $? "$out"
[ "$(deal_of "$out")" = "1 res://tests/test_dev_menu.gd;2 res://tests/test_market.gd;3 res://tests/test_play_log.gd;" ] \
  && ok "with no balance setting the deal is file order and nothing splits" || bad "with no balance setting the deal is file order and nothing splits" "$out"
# Opt-in, [tests] balance=true: longest first by the last run's times (files with no time first), and
# a file whose whole time is over [tests] split_over seconds runs as shards of its test methods, its
# tests counted once.
cp tools/check.cfg "$work/saved-cfg"; printf '\n[tests]\nbalance=true\nsplit_over=60\n' >> tools/check.cfg
printf 'res://tests/test_dev_menu.gd\t5\nres://tests/test_market.gd\t200\nres://tests/test_play_log.gd\t30\nres://tests/test_gone.gd\t9\n' > "$times"
# The seed is the older two-column form (path, seconds): it reads as each file's whole time.
out="$(GDIR_CHECK_DEAL=1 bash tools/check.sh --jobs 3 2>&1)"; expect_status "an old two-column timings file: --jobs 3 passes" 0 $? "$out"
expect_output "and runs every test once" "12 tests passed" "$out"
deal="$(deal_of "$out")"
[ "$deal" = "1 res://tests/test_market.gd shard 1/3;2 res://tests/test_market.gd shard 2/3;3 res://tests/test_market.gd shard 3/3;1 res://tests/test_play_log.gd;2 res://tests/test_dev_menu.gd;" ] \
  && ok "the deal is longest first, and a file over split_over is three shards" || bad "the deal is longest first, and a file over split_over is three shards" "$out"
market_runs="$(for f in "$logs"/tests-*.log; do tr -d '\r' < "$f"; done | grep '^GDIR-TEST: res://tests/test_market\.gd::')"
[ "$(printf '%s\n' "$market_runs" | wc -l | tr -d ' ')" -eq 6 ] && [ "$(printf '%s\n' "$market_runs" | /usr/bin/sort -u | wc -l | tr -d ' ')" -eq 6 ] \
  && [ "$(grep -l '^GDIR-TEST: res://tests/test_market\.gd::' "$logs"/tests-*.log | wc -l | tr -d ' ')" -eq 3 ] \
  && ok "the shards run in three processes, each of the file's tests once" || bad "the shards run in three processes, each of the file's tests once" "$market_runs"
# shard_times: the market file's shard times from the last run, as "<sum> <longest>" in seconds.
shard_times() { for f in "$logs"/tests-*.log; do tr -d '\r' < "$f"; done | awk '$1 == "GDIR-TIME:" && $3 == "res://tests/test_market.gd" { n += $2; if ($2 > m) m = $2 } END { printf "%.3f %.3f", n / 1000, m / 1000 }'; }
read -r m_sum m_longest <<EOF
$(shard_times)
EOF
grep -q "^res://tests/test_market\.gd	$m_sum	3	$m_longest\$" "$times" && ! grep -q 'test_gone' "$times" \
  && ok "a split run whose shards all finished stores their sum as the whole time, 3 shards and the longest; a deleted file's line is dropped" \
  || bad "a split run whose shards all finished stores their sum as the whole time, 3 shards and the longest; a deleted file's line is dropped" "$m_sum $m_longest$nl$(cat "$times")"
expect_output "the slowest files count a sharded file once" "slowest test files \(of 3, " "$out"
# A stored split of the same count: each shard is weighed by the stored longest shard.
printf 'res://tests/test_dev_menu.gd\t5\t1\t5\nres://tests/test_market.gd\t200\t3\t0.5\nres://tests/test_play_log.gd\t30\t1\t30\n' > "$times"
out="$(GDIR_CHECK_DEAL=1 bash tools/check.sh --jobs 3 2>&1)"; expect_status "a stored three-shard split passes" 0 $? "$out"
read -r m_sum m_longest <<EOF
$(shard_times)
EOF
[ "$(printf '%s\n' "$out" | grep -cE "^check: deal: job [0-9]+ 0\.500 res://tests/test_market\.gd shard [1-3]/3\$")" -eq 3 ] \
  && grep -q "^res://tests/test_market\.gd	$m_sum	3	$m_longest\$" "$times" \
  && ok "the split stays 3 shards, each weighed by the stored longest shard, and a lower sum replaces the whole time" \
  || bad "the split stays 3 shards, each weighed by the stored longest shard, and a lower sum replaces the whole time" "$out$nl$(cat "$times")"
# A higher sum doesn't: a slowed test makes the shards add up to more than the stored 0.010 s.
cp tests/test_market.gd "$work/saved"
printf '\nfunc test_selftest_slow() -> void:\n\tOS.delay_msec(50)\n\texpect(true)\n' >> tests/test_market.gd
cp "$work/saved-cfg" tools/check.cfg; printf '\n[tests]\nbalance=true\nsplit_over=0.005\n' >> tools/check.cfg
printf 'res://tests/test_dev_menu.gd\t0.001\t1\t0.001\nres://tests/test_market.gd\t0.010\t1\t0.010\nres://tests/test_play_log.gd\t0.001\t1\t0.001\n' > "$times"
out="$(GDIR_CHECK_DEAL=1 bash tools/check.sh --jobs 3 2>&1)"; expect_status "a split whose shards add up to more passes" 0 $? "$out"
grep -qE "^res://tests/test_market\.gd	0\.010	2	0\.[0-9]{3}\$" "$times" && expect_output "and splits in two" "deal: job [0-9]+ [0-9.]+ res://tests/test_market\.gd shard 2/2" "$out" \
  && ok "a higher sum leaves the stored whole time alone" || bad "a higher sum leaves the stored whole time alone" "$out$nl$(cat "$times")"
cp "$work/saved" tests/test_market.gd
}

l_par_c2() {
lane_game warm
parallel_prelude
cp tools/check.cfg "$work/saved-cfg"
cp "$work/saved-cfg" tools/check.cfg; printf '\n[tests]\nbalance=true\nsplit_over=60\n' >> tools/check.cfg
# A file marked no-split runs whole.
cp tests/test_market.gd "$work/saved"
{ head -n 1 "$work/saved"; echo "# gdir: no-split"; tail -n +2 "$work/saved"; } > tests/test_market.gd
printf 'res://tests/test_dev_menu.gd\t5\nres://tests/test_market.gd\t200\nres://tests/test_play_log.gd\t30\n' > "$times"
out="$(GDIR_CHECK_DEAL=1 bash tools/check.sh --jobs 3 2>&1)"; expect_status "a no-split file passes" 0 $? "$out"
[ "$(deal_of "$out")" = "1 res://tests/test_market.gd;2 res://tests/test_play_log.gd;3 res://tests/test_dev_menu.gd;" ] \
  && ok "a file with # gdir: no-split runs whole" || bad "a file with # gdir: no-split runs whole" "$out"
cp "$work/saved" tests/test_market.gd
# split_over = 0 never splits; a file with no time goes first.
cp "$work/saved-cfg" tools/check.cfg; printf '\n[tests]\nbalance=true\nsplit_over=0\n' >> tools/check.cfg
printf 'res://tests/test_market.gd\t200\nres://tests/test_play_log.gd\t30\n' > "$times"
out="$(GDIR_CHECK_DEAL=1 bash tools/check.sh --jobs 3 2>&1)"; expect_status "[tests] split_over=0 passes" 0 $? "$out"
[ "$(deal_of "$out")" = "1 res://tests/test_dev_menu.gd;2 res://tests/test_market.gd;3 res://tests/test_play_log.gd;" ] \
  && ok "split_over=0 runs the slow file whole, after the file with no time" || bad "split_over=0 runs the slow file whole, after the file with no time" "$out"
cp "$work/saved-cfg" tools/check.cfg; printf '\n[tests]\nbalance=true\nsplit_over=60\n' >> tools/check.cfg
# No timings file (or a stale one) with balance on: everything still runs, in file order.
rm -f "$times"
out="$(GDIR_CHECK_DEAL=1 bash tools/check.sh --jobs 2 2>&1)"; expect_status "no timings file: --jobs 2 passes" 0 $? "$out"
expect_output "and runs every test" "12 tests passed" "$out"
[ "$(deal_of "$out")" = "1 res://tests/test_dev_menu.gd;2 res://tests/test_market.gd;1 res://tests/test_play_log.gd;" ] \
  && ok "with no times the files are dealt in file order" || bad "with no times the files are dealt in file order" "$out"
[ "$(wc -l < "$times" | tr -d ' ')" -eq 3 ] && ok "and the run writes the timings file again" || bad "and the run writes the timings file again" "$(cat "$times" 2>/dev/null)"
printf 'res://tests/test_old.gd\t500\nnot a line\n' > "$times"
out="$(bash tools/check.sh --jobs 2 2>&1)"; expect_status "a stale timings file still runs everything" 0 $? "$out"
expect_output "every test of it" "12 tests passed" "$out"
expect_no_output "and the deal stays quiet without GDIR_CHECK_DEAL" "check: deal:" "$out"
cp "$work/saved-cfg" tools/check.cfg
# The cfg keys: the seed has them with their defaults, the example has none (the defaults apply).
grep -q '^jobs="auto"$' "$src/project/tools/check.cfg" && grep -q '^timeout=600$' "$src/project/tools/check.cfg" \
  && grep -q '^balance=false$' "$src/project/tools/check.cfg" && grep -q '^var _balance: bool = false$' tools/check.gd \
  && grep -q '^split_over=0$' "$src/project/tools/check.cfg" && grep -q '^var _split_over: float = 0\.0$' tools/check.gd \
  && grep -q 'case "$limit" in .*limit=600' tools/check.sh && ok "the seed's [tests] jobs, timeout, balance and split_over have their defaults" \
  || bad "the seed's [tests] jobs, timeout, balance and split_over have their defaults"
cp tools/check.cfg "$work/saved-cfg"
printf '\n[tests]\njobs=1\n' >> tools/check.cfg
out="$(bash tools/check.sh 2>&1)"; expect_status "[tests] jobs=1 in check.cfg runs one process" 0 $? "$out"
expect_no_output "with no group processes" "running the tests in" "$out"
cp "$work/saved-cfg" tools/check.cfg; printf '\n[tests]\njobs="2"\n' >> tools/check.cfg
out="$(bash tools/check.sh 2>&1)"; expect_output "[tests] jobs=\"2\" in check.cfg runs two" "running the tests in 2 processes" "$out"
}

l_par_d() {
lane_game warm
parallel_prelude
cp tools/check.cfg "$work/saved-cfg"; cp tests/test_market.gd "$work/saved"
# A run that hits its timeout exits 3 and names the file it was in.
if timeout --version 2>/dev/null | grep -qi coreutils || gtimeout --version 2>/dev/null | grep -qi coreutils; then
  printf 'extends "res://tools/test_case.gd"\n\nfunc test_hang() -> void:\n\tOS.delay_msec(120000)\n\texpect(true)\n' > tests/test_zz_hang.gd
  cp "$work/saved-cfg" tools/check.cfg; printf '\n[tests]\ntimeout=30\n' >> tools/check.cfg
  out="$(bash tools/check.sh --jobs 1 2>&1)"; expect_status "a serial run that hits [tests] timeout exits 3, not 1" 3 $? "$out"
  expect_output "and says so, naming the file it was running" "timed out after 30 s .*while running res://tests/test_zz_hang\.gd" "$out"
  cp "$work/saved-cfg" tools/check.cfg; printf '\n[tests]\ntimeout=9999\n' >> tools/check.cfg
  out="$(CHECK_TIMEOUT=30 bash tools/check.sh --jobs 2 2>&1)"; expect_status "a parallel group that hits CHECK_TIMEOUT exits 3" 3 $? "$out"
  expect_output "and names its group and file" "test group 2 of 2 timed out after 30 s in res://tests/[^ ]+ to res://tests/test_zz_hang\.gd .*while running res://tests/test_zz_hang\.gd" "$out"
  # A failing group beside a timed-out group: the failure wins (exit 1), and both are named.
  printf '
func test_selftest_failure() -> void:
	expect_eq(1, 2)
' >> tests/test_market.gd
  out="$(CHECK_TIMEOUT=30 bash tools/check.sh --jobs 2 2>&1)"; expect_status "a failing group plus a timed-out group exits 1" 1 $? "$out"
  expect_output "and names the failure" "test_market\.gd::test_selftest_failure: expected 2, got 1" "$out"
  expect_output "and the timeout" "test group 2 of 2 timed out after 30 s" "$out"
  cp "$work/saved" tests/test_market.gd
  rm -f tests/test_zz_hang.gd tests/test_zz_hang.gd.uid
else
  echo "  (no GNU timeout: the timeout cases are skipped)"
fi
cp "$work/saved-check-cfg-ap" tools/check.cfg
}

l_playlog() {
lane_game warm
# --- play log -----------------------------------------------------------------------------------
# The example's PlayLog runs under the check and writes nothing; tests/play-log/selftest_play_log.gd
# runs the base outside the check, into a folder of its own, and checks the files it writes.
echo "play log"
# The example's real user:// folder.
user_data_init
mkdir -p "$user_data" && : > "$work/before-play-log" && sleep 1
rm -f .godot/godot-director/last-pass
out="$(bash tools/check.sh 2>&1)"; expect_status "the check passes with the example's PlayLog" 0 $? "$out"
cp "$src/tests/play-log/selftest_play_log.gd" tools/selftest_play_log.gd
play_dir="$work/play-log"; mkdir -p "$play_dir"
command -v cygpath >/dev/null 2>&1 && play_dir="$(cygpath -m "$play_dir")"
out="$("$godot" --headless --path . --script tools/selftest_play_log.gd -- "$play_dir" 2>&1 | tr -d '\r')"
while IFS= read -r line; do
  case "$line" in
    "PASS "*) ok "${line#PASS }" ;;
    "FAIL "*) bad "${line#FAIL }" ;;
  esac
done <<EOF
$out
EOF
printf '%s\n' "$out" | grep -q '^DONE$' && ok "the play log's own test ran to the end" || bad "the play log's own test ran to the end" "$out"
# Godot's own logs/godot*.log may appear there; a play log is run-*.log and run-*.jsonl.
[ -z "$(/usr/bin/find "$user_data" -type f -name 'run-*' -newer "$work/before-play-log" 2>/dev/null)" ] \
  && ok "neither the check nor a tool script writes a play log in the game's user://" \
  || bad "neither the check nor a tool script writes a play log in the game's user://" "$(/usr/bin/find "$user_data" -type f -name 'run-*' -newer "$work/before-play-log")"
rm -f tools/selftest_play_log.gd tools/selftest_play_log.gd.uid

# --- dev menu -----------------------------------------------------------------------------------
# tests/dev-menu/selftest_dev_menu.gd builds the menu headless and runs it, with the real flag on the
# command line. A script error in it must fail too, so its output is searched for one.
echo "dev menu"
cp "$src/tests/dev-menu/selftest_dev_menu.gd" tools/selftest_dev_menu.gd
out="$("$godot" --headless --path . --script tools/selftest_dev_menu.gd -- --dev-menu 2>&1 | tr -d '\r')"
while IFS= read -r line; do
  case "$line" in
    "PASS "*) ok "${line#PASS }" ;;
    "FAIL "*) bad "${line#FAIL }" ;;
  esac
done <<EOF
$out
EOF
printf '%s\n' "$out" | grep -q '^DONE$' && ok "the dev menu's own test ran to the end" || bad "the dev menu's own test ran to the end" "$out"
expect_no_output "and raised no script error" "SCRIPT ERROR|Parse Error" "$out"
rm -f tools/selftest_dev_menu.gd tools/selftest_dev_menu.gd.uid

}

l_stop_hook() {
lane_game warm
# --- Stop hook ----------------------------------------------------------------------------------
echo "stop hook"
git add -A && { git_q commit -qm "state for the hook tests" >/dev/null 2>&1 || true; }
hook() { echo '{}' | CLAUDE_PROJECT_DIR="$game" bash .claude/hooks/stop-check.sh 2>&1; }
out="$(hook)"; expect_status "does nothing when code is unchanged" 0 $? "$out"
printf '\n# a harmless change\n' >> scripts/systems/market.gd
out="$(hook)"; expect_status "lets a passing change through" 0 $? "$out"
cp scripts/systems/market.gd "$work/passing"
printf 'func broken( -> void:\n' >> scripts/systems/market.gd
cp scripts/systems/market.gd "$work/failing"
out="$(hook)"; status=$?
expect_status "blocks a failing change" 2 "$status" "$out"
expect_output "gives Claude the check output" 'check\.sh fails' "$out"
out="$(hook)"; expect_status "reports the same failing state only once" 0 $? "$out"
out="$(bash tools/check.sh --if-changed 2>&1)"; status=$?
expect_status "--if-changed repeats a failure without rerunning" 1 "$status" "$out"
expect_output "says the failing state is unchanged" "nothing changed since the last failing run" "$out"
rm -f .godot/godot-director/last-reported
: > .godot/godot-director/building
out="$(hook)"; expect_status "leaves a builder's half-built files alone" 0 $? "$out"
rm -f .godot/godot-director/building
out="$(hook)"; expect_status "blocks again once the builder is done" 2 $? "$out"
cp "$work/passing" scripts/systems/market.gd
out="$(hook)"; expect_status "lets the fixed state through" 0 $? "$out"
cp "$work/failing" scripts/systems/market.gd
out="$(hook)"; expect_status "blocks the failing state again after it was fixed once" 2 $? "$out"
git checkout -q -- scripts/systems/market.gd

}

l_stop_hook_session() {
cd "$work" || exit 1
# --- Stop hook, per session ---------------------------------------------------------------------
# Two sessions can share one working folder (a design session and a build session, no worktree). The Stop hook runs the
# check only for a session that wrote or edited a code, scene or data file itself: session-touched.sh keeps that record by
# the session_id in the hook input (a file tool's PostToolUse; for Bash and PowerShell the git status before and after the
# command). So a design session that edits only Markdown never waits for, or is blocked by, another session's uncommitted
# code. A throwaway repository holds it, with a stand-in check that records that it ran and fails while
# .godot/godot-director/fail exists, and scripted hook inputs. It needs no Godot, so it is a lane of its own that needs no game.
echo "stop hook, per session"
sr="$work/session-stop"; new_repo "$sr"
sr_hooks="$src/framework/.claude/hooks"
mkdir -p "$sr/tools" "$sr/scripts"
cat > "$sr/tools/check.sh" <<'EOF'
#!/usr/bin/env bash
case "${1:-}" in --fingerprint) cat scripts/*.gd 2>/dev/null | git hash-object --stdin; exit 0 ;; esac
mkdir -p .godot/godot-director
: > .godot/godot-director/check-ran
if [ -f .godot/godot-director/fail ]; then echo "scripts/hero.gd:3 parse error: unexpected token"; exit 1; fi
exit 0
EOF
printf '/.godot/\n' > "$sr/.gitignore"
git -C "$sr" add -A >/dev/null 2>&1; git_q -C "$sr" commit -qm "a stand-in check" >/dev/null 2>&1
sr_state="$sr/.godot/godot-director"
sr_nl=$'\n'
sr_put() { [ -d "${1%/*}" ] || mkdir -p "${1%/*}"; printf '%s\n' "$2" > "$1"; }   # sr_put <file> <content>
_sr_wrote() { # _sr_wrote <session> <tool> <path> [path key] [event]: a file tool's PostToolUse input, through the recorder
  printf '{"session_id":"%s","cwd":"%s","hook_event_name":"%s","tool_name":"%s","tool_input":{"%s":"%s","content":"x"},"tool_response":{"success":true}}' \
    "$1" "$sr" "${5:-PostToolUse}" "$2" "${4:-file_path}" "$3" | CLAUDE_PROJECT_DIR="$sr" bash "$sr_hooks/session-touched.sh" after 2>&1
}
_sr_cmd() { # _sr_cmd <session> before|after <tool> [event]: a Bash or PowerShell command's PreToolUse or PostToolUse input
  printf '{"session_id":"%s","cwd":"%s","hook_event_name":"%s","tool_name":"%s","tool_input":{"command":"make"}}' \
    "$1" "$sr" "${4:-PostToolUse}" "$3" | CLAUDE_PROJECT_DIR="$sr" bash "$sr_hooks/session-touched.sh" "$2" 2>&1
}
_sr_stop() { # _sr_stop <hook input>: the Stop hook's output; the exit status is the hook's
  printf '%s' "$1" | CLAUDE_PROJECT_DIR="$sr" bash "$sr_hooks/stop-check.sh" 2>&1
}
_sr_stop_as() { _sr_stop "{\"session_id\":\"$1\",\"transcript_path\":\"/x/y.jsonl\",\"hook_event_name\":\"Stop\",\"stop_hook_active\":false}"; }
_sr_rec() { cat "$sr_state/sessions/$1.touched" 2>/dev/null; }
_sr_ran() { [ -e "$sr_state/check-ran" ]; }

# 1. A design session that edits only Markdown and assets, while a build session has uncommitted code in the same folder.
sr_put "$sr/scripts/hero.gd" 'extends Node'
_sr_wrote build Write "$sr/scripts/hero.gd" >/dev/null
_sr_wrote design Write "$sr/design/gdd.md" >/dev/null
_sr_wrote design Edit "$sr/TASKS.md" >/dev/null
_sr_wrote design MultiEdit "$sr/docs/notes.md" >/dev/null
_sr_wrote design Write "$sr/art/hero.png" >/dev/null
out="$(_sr_rec build)"; expect_output "records the code file a session wrote, from the project root" '^scripts/hero\.gd$' "$out"
if [ ! -e "$sr_state/sessions/design.touched" ]; then ok "records nothing for a session that edited only Markdown and an asset"; else bad "records nothing for a session that edited only Markdown and an asset" "$(_sr_rec design)"; fi
: > "$sr_state/fail"   # a check that would fail, as the other session's unfinished code makes it
out="$(_sr_stop_as design)"; status=$?
expect_status "the Stop hook exits 0 for a design session while another session has uncommitted code in the folder" 0 "$status" "$out"
if _sr_ran; then bad "the check doesn't run for the session that edited only Markdown"; else ok "the check doesn't run for the session that edited only Markdown"; fi
_sr_wrote kinds Write "$sr/scripts/a.gd" >/dev/null
_sr_wrote kinds Edit "$sr/scenes/main.tscn" >/dev/null
_sr_wrote kinds Write "$sr/scenes/packed.scn" >/dev/null
_sr_wrote kinds MultiEdit "$sr/data/items.tres" >/dev/null
_sr_wrote kinds Write "$sr/data/theme.res" >/dev/null
_sr_wrote kinds Write "$sr/shaders/water.gdshader" >/dev/null
_sr_wrote kinds NotebookEdit "$sr/shaders/noise.gdshaderinc" notebook_path >/dev/null
_sr_wrote kinds Edit "$sr/project.godot" >/dev/null
_sr_wrote kinds Write "$sr/scripts/a.gd.uid" >/dev/null
_sr_wrote kinds Write "$sr/README.md" >/dev/null
_sr_wrote kinds Write "$sr/.godot/godot-director/building" >/dev/null
_sr_wrote kinds Write "/elsewhere/outside.gd" >/dev/null
out="$(_sr_rec kinds)"
[ "$out" = "scripts/a.gd${sr_nl}scenes/main.tscn${sr_nl}scenes/packed.scn${sr_nl}data/items.tres${sr_nl}data/theme.res${sr_nl}shaders/water.gdshader${sr_nl}shaders/noise.gdshaderinc${sr_nl}project.godot" ] \
  && ok "records .gd, .tscn, .scn, .tres, .res, .gdshader, .gdshaderinc and project.godot as code, and skips a .gd.uid, Markdown, the state folder and a file outside the project" \
  || bad "records .gd, .tscn, .scn, .tres, .res, .gdshader, .gdshaderinc and project.godot as code, and skips a .gd.uid, Markdown, the state folder and a file outside the project" "$out"
if command -v cygpath >/dev/null 2>&1; then
  # Claude Code on Windows sends the path with JSON-escaped backslashes (two for each separator), and the project folder as C:\...
  sr_bs2='\\'                                                      # two backslash characters: one separator, JSON-escaped
  sr_winroot="$(cygpath -w "$sr")"                                 # C:\...\session-stop, backslashes as Windows writes them
  sr_winjson="$(printf '%s' "$sr_winroot" | sed 's/\\/\\\\/g')"    # the same, each backslash doubled as JSON writes it
  printf '{"session_id":"winpath","cwd":"%s","hook_event_name":"PostToolUse","tool_name":"Write","tool_input":{"file_path":"%s","content":"x"}}' \
    "$sr_winjson" "${sr_winjson}${sr_bs2}scripts${sr_bs2}Win.gd" | CLAUDE_PROJECT_DIR="$sr_winroot" bash "$sr_hooks/session-touched.sh" after >/dev/null 2>&1
  out="$(_sr_rec winpath)"
  [ "$out" = "scripts/Win.gd" ] && ok "reads a Windows path with JSON-escaped backslashes against a project folder written as C:\\..." \
    || bad "reads a Windows path with JSON-escaped backslashes against a project folder written as C:\\..." "$out"
fi

# 2. The build session that wrote code gets the check, is blocked once for a failure, and not twice for the same one.
: > "$sr_state/fail"
out="$(_sr_stop_as build)"; status=$?
expect_status "the session that wrote code gets the check, and is blocked when it fails" 2 "$status" "$out"
expect_output "and is given the check's output" 'parse error' "$out"
if _sr_ran; then ok "the check ran for it"; else bad "the check ran for it"; fi
rm -f "$sr_state/check-ran"
out="$(_sr_stop_as build)"; status=$?
expect_status "the same failure isn't reported twice" 0 "$status" "$out"
if _sr_ran; then bad "and the check isn't run again for it"; else ok "and the check isn't run again for it"; fi

# 3. A Bash or PowerShell command is read from git's list of changed files before and after it.
_sr_cmd shell before Bash >/dev/null
sleep 1
sr_put "$sr/scripts/made.gd" 'extends Node'
sr_put "$sr/notes.md" '# notes'
sr_put "$sr/art/new.png" 'png'
_sr_cmd shell after Bash >/dev/null
out="$(_sr_rec shell)"
[ "$out" = "scripts/made.gd" ] && ok "a Bash command that creates a .gd file is recorded, and a Markdown file, an asset and a file already changed before it are not" \
  || bad "a Bash command that creates a .gd file is recorded, and a Markdown file, an asset and a file already changed before it are not" "$out"
_sr_cmd shell2 before PowerShell PreToolUse >/dev/null
sleep 1
printf '# edited by a command\n' >> "$sr/scripts/hero.gd"
_sr_cmd shell2 after PowerShell PostToolUseFailure >/dev/null
out="$(_sr_rec shell2)"
[ "$out" = "scripts/hero.gd" ] && ok "a PowerShell command that modifies a file changed before it is recorded, one that fails too" \
  || bad "a PowerShell command that modifies a file changed before it is recorded, one that fails too" "$out"
_sr_cmd shell3 before Bash >/dev/null; _sr_cmd shell3 after Bash >/dev/null
if [ ! -e "$sr_state/sessions/shell3.touched" ]; then ok "a command that changes nothing records nothing"; else bad "a command that changes nothing records nothing" "$(_sr_rec shell3)"; fi
_sr_cmd shell4 after Bash >/dev/null
if [ ! -e "$sr_state/sessions/shell4.touched" ]; then ok "a command with no snapshot before it records nothing"; else bad "a command with no snapshot before it records nothing" "$(_sr_rec shell4)"; fi

# 4. A passing check removes the session's record, and not another session's.
rm -f "$sr_state/fail" "$sr_state/check-ran"
_sr_cmd build before Bash >/dev/null
printf '# the fix\n' >> "$sr/scripts/hero.gd"
out="$(_sr_stop_as build)"; status=$?
expect_status "a session whose code passes the check ends its turn" 0 "$status" "$out"
if _sr_ran; then ok "the check ran for it"; else bad "the check ran for it"; fi
if [ ! -e "$sr_state/sessions/build.touched" ] && [ ! -e "$sr_state/sessions/build.before" ]; then ok "a passing check removes the session's record"; else bad "a passing check removes the session's record" "$(ls "$sr_state/sessions")"; fi
if [ -s "$sr_state/sessions/shell.touched" ]; then ok "and leaves another session's"; else bad "and leaves another session's"; fi

# 5. A record older than a day is ignored, and deleted with any other session's that old.
: > "$sr_state/fail"; rm -f "$sr_state/check-ran" "$sr_state/last-reported"
_sr_wrote old Write "$sr/scripts/hero.gd" >/dev/null
_sr_wrote stale Write "$sr/scripts/hero.gd" >/dev/null
touch -t 202001010000 "$sr_state/sessions/old.touched" "$sr_state/sessions/stale.touched"
out="$(_sr_stop_as old)"; status=$?
expect_status "a record older than a day is ignored" 0 "$status" "$out"
if _sr_ran; then bad "and the check doesn't run for it"; else ok "and the check doesn't run for it"; fi
if [ ! -e "$sr_state/sessions/old.touched" ] && [ ! -e "$sr_state/sessions/stale.touched" ]; then ok "and it is deleted, as is another session's that old"; else bad "and it is deleted, as is another session's that old" "$(ls "$sr_state/sessions")"; fi

# 6. No session_id, or one that can't be a file name, behaves as before: uncommitted code runs the check once.
out="$(_sr_stop '{"hook_event_name":"Stop"}')"; status=$?
expect_status "with no session_id the hook decides from git alone: uncommitted code runs the check, and a failure blocks" 2 "$status" "$out"
if _sr_ran; then ok "and the check ran"; else bad "and the check ran"; fi
out="$(_sr_stop '{"hook_event_name":"Stop"}')"; expect_status "and the same failure isn't reported twice" 0 $? "$out"
printf '# another change\n' >> "$sr/scripts/hero.gd"; rm -f "$sr_state/check-ran"
out="$(_sr_stop_as '../../escape')"; status=$?
expect_status "a session_id that isn't a plain name behaves the same" 2 "$status" "$out"
printf '# and another\n' >> "$sr/scripts/hero.gd"
out="$(_sr_stop '{"session_id":"","hook_event_name":"Stop"}')"; expect_status "so does an empty one" 2 $? "$out"

# 7. What stays as it was: the builder marker, the prototype exit, GODOT_DIRECTOR_STOP_CHECK=0 and a project with no tools/check.sh.
printf '# once more\n' >> "$sr/scripts/hero.gd"; rm -f "$sr_state/check-ran"
_sr_wrote marked Write "$sr/scripts/hero.gd" >/dev/null
: > "$sr_state/building"
out="$(_sr_stop_as marked)"; status=$?
expect_status "a session with a record leaves a builder's half-built files alone" 0 "$status" "$out"
rm -f "$sr_state/building"
printf '# a prototype\n' > "$sr/PROTOTYPE.md"; printf 'exit 0\n' > "$sr/tools/prototype.sh"   # a stand-in for "bash tools/prototype.sh here" saying yes
out="$(_sr_stop_as marked)"; expect_status "and in a prototype" 0 $? "$out"
rm -f "$sr/PROTOTYPE.md" "$sr/tools/prototype.sh"
out="$(GODOT_DIRECTOR_STOP_CHECK=0 _sr_stop_as marked)"; expect_status "GODOT_DIRECTOR_STOP_CHECK=0 turns the Stop hook off for it" 0 $? "$out"
GODOT_DIRECTOR_STOP_CHECK=0 _sr_wrote off Write "$sr/scripts/hero.gd" >/dev/null
if [ ! -e "$sr_state/sessions/off.touched" ]; then ok "and the record with it"; else bad "and the record with it"; fi
mv "$sr/tools/check.sh" "$sr/tools/check.sh.away"
out="$(_sr_stop_as marked)"; expect_status "a project with no tools/check.sh ends the turn" 0 $? "$out"
mv "$sr/tools/check.sh.away" "$sr/tools/check.sh"
if _sr_ran; then bad "the check isn't run while the builder marker, the prototype, the switch or a missing script excuses it"; else ok "the check isn't run while the builder marker, the prototype, the switch or a missing script excuses it"; fi
out="$(_sr_stop_as marked)"; expect_status "and the record still blocks once those are gone" 2 $? "$out"

# 8. Work that is committed ends the record: the check passed in the commit, and what differs later is another's.
rm -f "$sr_state/fail" "$sr_state/check-ran"
git -C "$sr" add -A >/dev/null 2>&1; git_q -C "$sr" commit -qm "the build session's work" >/dev/null 2>&1
out="$(_sr_stop_as marked)"; status=$?
expect_status "a session whose code is all committed ends its turn" 0 "$status" "$out"
if [ ! -e "$sr_state/sessions/marked.touched" ] && ! _sr_ran; then ok "and its record is removed without running the check"; else bad "and its record is removed without running the check" "$(ls "$sr_state/sessions")"; fi
sr_put "$sr/docs/more.md" '# more'
out="$(_sr_stop '{"hook_event_name":"Stop"}')"; expect_status "with no session_id, a Markdown-only change ends the turn, as before" 0 $? "$out"

# The hooks are wired in settings.json: the snapshot before a command, the record after a file tool or a command
# (a failing one too), and the hook runs under macOS's bash 3.2 and BSD tools, so it holds none of the forms they lack.
wiring="$(awk '/^    "[A-Za-z]+": \[/ { ev = $1; gsub(/[":]/, "", ev) } /"matcher"/ { split($0, a, "\""); m = a[4] }
  /session-touched\.sh/ { print ev ";" m ";" ($0 ~ / before"/ ? "before" : "after") }' "$settings")"
[ "$wiring" = "PreToolUse;Bash|PowerShell;before${sr_nl}PostToolUse;Edit|Write|MultiEdit|NotebookEdit;after${sr_nl}PostToolUse;Bash|PowerShell;after${sr_nl}PostToolUseFailure;Bash|PowerShell;after" ] \
  && ok "settings.json runs the record hook before Bash and PowerShell, after them (a failing one too) and after Edit, Write, MultiEdit and NotebookEdit" \
  || bad "settings.json runs the record hook before Bash and PowerShell, after them (a failing one too) and after Edit, Write, MultiEdit and NotebookEdit" "$wiring"
bash4=$(grep -nE '^[^#]*(\$\{[A-Za-z_0-9]+(\[[^]]*\])?(,,|\^\^)\}|(declare|local|typeset) +-[a-zA-Z]*A|(^|[;&| ])(mapfile|readarray) +|(^|[;&| ])coproc +[A-Za-z]|[[:space:]]\|&[[:space:]]|\$\{[A-Za-z_0-9@*]+(\[[^]]*\])?: -[0-9]|stat +-c|date +-d|sed +-i|readlink +-f|-printf|-delete)' \
  "$sr_hooks/session-touched.sh" "$sr_hooks/stop-check.sh" || true)
if [ -z "$bash4" ]; then ok "the Stop hook and the record hook use no bash 4 form and no GNU-only tool flag"
else bad "the Stop hook and the record hook use no bash 4 form and no GNU-only tool flag" "$bash4"; fi

}

l_release_check() {
cd "$work" || exit 1
# --- release check hook -------------------------------------------------------------------------
# release-check.sh runs when a session starts and says when the installed version (the manifest's first line) is below the
# latest release tag on GitHub. A throwaway project holds the manifest and the cache, and a stand-in git (first on PATH) records
# each call and answers with the tags a case sets, so no case reaches the network. It needs no Godot, so it is a lane of its own.
echo "release check hook"
rc_hook="$src/framework/.claude/hooks/release-check.sh"
rc_proj="$work/rc-project"; rc_stub="$work/rc-stub"; rc_tstub="$work/rc-tstub"
rc_cache="$rc_proj/.godot/godot-director/latest-release"
rc_url="https://github.com/Freakling/Godot-Director.git"
mkdir -p "$rc_proj/.godot-director" "$rc_stub" "$rc_tstub"
cat > "$rc_stub/git" <<'EOF'
#!/bin/bash
# a stand-in git: it records each call (the prompt setting and the arguments), then fails when git-fails exists, or prints the tags file
printf '%s|%s\n' "${GIT_TERMINAL_PROMPT:-unset}" "$*" >> "$RC_STUB/calls"
[ -e "$RC_STUB/git-fails" ] && exit 128
while IFS= read -r line; do printf '%s\n' "$line"; done < "$RC_STUB/tags"
exit 0
EOF
cat > "$rc_tstub/timeout" <<'EOF'
#!/bin/bash
# a stand-in timeout: it records its limit and runs the command
printf '%s\n' "$1" >> "$RC_STUB/timeouts"
shift
exec "$@"
EOF
chmod +x "$rc_stub/git" "$rc_tstub/timeout"
unset GODOT_DIRECTOR_RELEASE_CHECK
export CLAUDE_PROJECT_DIR="$rc_proj" RC_STUB="$rc_stub"
rc_sha="0123456789abcdef0123456789abcdef01234567"
rc_set() { # rc_set <manifest first line> [tag…]: a project at that version, no cache, and a git that lists these tags
  local t
  rm -rf "$rc_proj/.godot" "$rc_stub/calls" "$rc_stub/timeouts" "$rc_stub/git-fails"
  printf '%s\n# tools claude\n%s\t.claude/settings.json\n' "$1" "$rc_sha" > "$rc_proj/.godot-director/manifest"
  shift
  : > "$rc_stub/tags"
  for t in "$@"; do printf '%s\trefs/tags/%s\n' "$rc_sha" "$t" >> "$rc_stub/tags"; done
}
rc_cache_is() { # rc_cache_is <version>: write the cache with that value
  mkdir -p "$rc_proj/.godot/godot-director"; printf '%s\n' "$1" > "$rc_cache"
}
rc_run() { # the hook's output, stdout and stderr together; its exit status is the hook's
  printf '{"session_id":"s","hook_event_name":"SessionStart","source":"startup"}' | PATH="$rc_stub:$PATH" bash "$rc_hook" 2>&1
}
rc_calls() { # how many times git was called
  local n=0 l
  [ -f "$rc_stub/calls" ] && while IFS= read -r l; do n=$((n + 1)); done < "$rc_stub/calls"
  echo "$n"
}
rc_json() { # rc_json <installed> <latest>: the line the hook prints
  local t="Godot Director $1 is installed, and the latest release is $2. Ask the agent to upgrade it when it suits you."
  printf '{"systemMessage":"%s","hookSpecificOutput":{"hookEventName":"SessionStart","additionalContext":"%s Tell the human this once, in your first reply."}}' "$t" "$t"
}

# 1. Behind the latest release: it warns, with the text for the human and for Claude in one line of JSON, and looks the tags up once.
rc_set "# godot-director 4.10.0" v4.9.0 v4.11.0 v4.10.0
out="$(rc_run)"; status=$?
expect_status "a project behind the latest release: the hook exits 0" 0 "$status" "$out"
[ "$out" = "$(rc_json 4.10.0 4.11.0)" ] && ok "and prints one line of JSON with the message for the human and the same text and the instruction for Claude" \
  || bad "and prints one line of JSON with the message for the human and the same text and the instruction for Claude" "$out"
[ "$(rc_calls)" = "1" ] && [ "$(<"$rc_stub/calls")" = "0|ls-remote --tags --refs $rc_url refs/tags/v*" ] \
  && ok "it asked git once, for the release tags only, with the terminal prompt off" || bad "it asked git once, for the release tags only, with the terminal prompt off" "$(<"$rc_stub/calls")"
[ "$(<"$rc_cache")" = "4.11.0" ] && ok "and kept the highest version in .godot/godot-director/latest-release" || bad "and kept the highest version in .godot/godot-director/latest-release" "$(<"$rc_cache")"
rc_set "# godot-director 1.9.0" v1.14.0 v1.9.0
out="$(rc_run)"; [ "$out" = "$(rc_json 1.9.0 1.14.0)" ] && ok "1.9.0 is below 1.14.0: versions compare field by field as numbers" || bad "1.9.0 is below 1.14.0: versions compare field by field as numbers" "$out"
rc_set "# godot-director 1.14.0" v1.9.0
out="$(rc_run)"; status=$?
[ -z "$out" ] && [ "$status" -eq 0 ] && ok "and 1.14.0 is not below 1.9.0" || bad "and 1.14.0 is not below 1.9.0" "$out"
rc_set "# godot-director 9.9.9" v10.0.0
out="$(rc_run)"; [ "$out" = "$(rc_json 9.9.9 10.0.0)" ] && ok "9.9.9 is below 10.0.0" || bad "9.9.9 is below 10.0.0" "$out"

# 2. Up to date, ahead, and nothing found: silent.
rc_set "# godot-director 4.11.0" v4.10.0 v4.11.0
out="$(rc_run)"; status=$?
[ -z "$out" ] && [ "$status" -eq 0 ] && ok "the latest release installed: nothing is printed" || bad "the latest release installed: nothing is printed" "$out"
rc_set "# godot-director 4.12.0" v4.11.0
out="$(rc_run)"; status=$?
[ -z "$out" ] && [ "$status" -eq 0 ] && ok "a newer install than the latest tag: nothing is printed" || bad "a newer install than the latest tag: nothing is printed" "$out"
rc_set "# godot-director 4.10.0"
out="$(rc_run)"; status=$?
[ -z "$out" ] && [ "$status" -eq 0 ] && ok "a lookup that finds no tag: nothing is printed" || bad "a lookup that finds no tag: nothing is printed" "$out"

# 3. A development snapshot's ' + unreleased (...)' tail is read as its version, and a CRLF manifest as the same one.
rc_set "# godot-director 4.10.0 + unreleased (abc1234)" v4.11.0
out="$(rc_run)"; [ "$out" = "$(rc_json 4.10.0 4.11.0)" ] && ok "a manifest saying '4.10.0 + unreleased (abc1234)' is read as 4.10.0" || bad "a manifest saying '4.10.0 + unreleased (abc1234)' is read as 4.10.0" "$out"
rc_set "# godot-director 4.10.0 + unreleased" v4.10.0
out="$(rc_run)"; [ -z "$out" ] && ok "and a snapshot of the latest release is up to date" || bad "and a snapshot of the latest release is up to date" "$out"
rc_set "# godot-director 4.10.0" v4.11.0
printf '# godot-director 4.10.0\r\n# tools claude\r\n' > "$rc_proj/.godot-director/manifest"
out="$(rc_run)"; [ "$out" = "$(rc_json 4.10.0 4.11.0)" ] && ok "a manifest with CRLF line endings is read too" || bad "a manifest with CRLF line endings is read too" "$out"

# 4. The cache: a fresh one is used without git, a day-old one is refreshed once, and the day's next start doesn't ask again.
rc_set "# godot-director 4.10.0" v4.12.0
rc_cache_is 4.11.0
out="$(rc_run)"; status=$?
[ "$out" = "$(rc_json 4.10.0 4.11.0)" ] && [ "$(rc_calls)" = "0" ] && [ "$status" -eq 0 ] && ok "a fresh cache is used and git isn't called" || bad "a fresh cache is used and git isn't called" "$out"
touch -t 202001010000 "$rc_cache"
out="$(rc_run)"
[ "$out" = "$(rc_json 4.10.0 4.12.0)" ] && [ "$(rc_calls)" = "1" ] && [ "$(<"$rc_cache")" = "4.12.0" ] \
  && ok "a cache a day old calls git once and takes the new value" || bad "a cache a day old calls git once and takes the new value" "calls $(rc_calls): $out"
out="$(rc_run)"; [ "$out" = "$(rc_json 4.10.0 4.12.0)" ] && [ "$(rc_calls)" = "1" ] && ok "and the next start the same day doesn't call it again" || bad "and the next start the same day doesn't call it again" "calls $(rc_calls): $out"
rc_set "# godot-director 4.10.0" v4.12.0
rc_cache_is "not a version"
out="$(rc_run)"; status=$?
[ -z "$out" ] && [ "$status" -eq 0 ] && [ "$(rc_calls)" = "0" ] && ok "a cache that doesn't hold a version is silent until it is a day old" || bad "a cache that doesn't hold a version is silent until it is a day old" "$out"

# 5. A lookup that fails: nothing printed, exit 0, and the day's one try is spent; an old value is kept.
rc_set "# godot-director 4.10.0" v4.12.0
: > "$rc_stub/git-fails"
out="$(rc_run)"; status=$?
[ -z "$out" ] && [ "$status" -eq 0 ] && [ "$(rc_calls)" = "1" ] && [ -f "$rc_cache" ] && [ ! -s "$rc_cache" ] \
  && ok "a failed git prints nothing, exits 0 and leaves an empty cache" || bad "a failed git prints nothing, exits 0 and leaves an empty cache" "exit $status, calls $(rc_calls): $out"
out="$(rc_run)"; status=$?
[ -z "$out" ] && [ "$status" -eq 0 ] && [ "$(rc_calls)" = "1" ] && ok "and doesn't call git again that day" || bad "and doesn't call git again that day" "exit $status, calls $(rc_calls): $out"
rc_set "# godot-director 4.10.0" v4.12.0
: > "$rc_stub/git-fails"
rc_cache_is 4.11.0; touch -t 202001010000 "$rc_cache"
out="$(rc_run)"; status=$?
[ "$out" = "$(rc_json 4.10.0 4.11.0)" ] && [ "$status" -eq 0 ] && [ "$(rc_calls)" = "1" ] && [ "$(<"$rc_cache")" = "4.11.0" ] \
  && ok "a failed refresh keeps the old value, and still warns by it" || bad "a failed refresh keeps the old value, and still warns by it" "exit $status, calls $(rc_calls): $out"
out="$(rc_run)"; [ "$out" = "$(rc_json 4.10.0 4.11.0)" ] && [ "$(rc_calls)" = "1" ] && ok "and the old value's day starts again, so git isn't called a second time that day" || bad "and the old value's day starts again, so git isn't called a second time that day" "calls $(rc_calls): $out"
rc_set "# godot-director 4.10.0" v4.12.0
out="$(printf '{}' | PATH="/nonexistent" "$BASH" "$rc_hook" 2>&1)"; status=$?
[ -z "$out" ] && [ "$status" -eq 0 ] && ok "a PATH with no git at all prints nothing and exits 0" || bad "a PATH with no git at all prints nothing and exits 0" "exit $status: $out"

# 6. Only v<major>.<minor>.<patch> tags count.
rc_set "# godot-director 4.10.0" v2.0.0-rc1 latest v4.11.0 v5.0.0-beta v4.12 v4.12.0.1 v4.13.0-rc1 nightly/v9.9.9 V9.0.0
out="$(rc_run)"
[ "$out" = "$(rc_json 4.10.0 4.11.0)" ] && [ "$(<"$rc_cache")" = "4.11.0" ] && ok "tags of any other shape (-rc1, a name, two or four fields, a prefix, a capital V) are ignored" \
  || bad "tags of any other shape (-rc1, a name, two or four fields, a prefix, a capital V) are ignored" "$out"
rc_set "# godot-director 4.10.0" v2.0.0-rc1 latest
out="$(rc_run)"; status=$?
[ -z "$out" ] && [ "$status" -eq 0 ] && [ ! -s "$rc_cache" ] && ok "and with only such tags nothing is printed" || bad "and with only such tags nothing is printed" "$out"
rc_set "# godot-director 4.10.0" v08.09.0
out="$(rc_run)"; status=$?
[ "$out" = "$(rc_json 4.10.0 8.9.0)" ] && [ "$status" -eq 0 ] && ok "a field with a leading zero is a decimal number, not an octal one" || bad "a field with a leading zero is a decimal number, not an octal one" "exit $status: $out"

# 7. The time limit: 5 seconds when timeout exists, and the lookup still runs without it.
rc_set "# godot-director 4.10.0" v4.11.0
out="$(printf '{}' | PATH="$rc_tstub:$rc_stub:$PATH" bash "$rc_hook" 2>&1)"
[ "$out" = "$(rc_json 4.10.0 4.11.0)" ] && [ "$(<"$rc_stub/timeouts")" = "5" ] && ok "the lookup runs under timeout 5 when timeout exists" || bad "the lookup runs under timeout 5 when timeout exists" "$out"
rc_set "# godot-director 4.10.0" v4.11.0
out="$(printf '{}' | PATH="$rc_stub:/nonexistent" "$BASH" "$rc_hook" 2>&1)"
[ "$out" = "$(rc_json 4.10.0 4.11.0)" ] && [ "$(rc_calls)" = "1" ] && [ ! -e "$rc_stub/timeouts" ] && ok "and without timeout on PATH it still looks the tags up" || bad "and without timeout on PATH it still looks the tags up" "calls $(rc_calls): $out"

# 8. Off, and nothing to compare: silent, and git is never called.
rc_set "# godot-director 4.10.0" v4.11.0
out="$(printf '{}' | GODOT_DIRECTOR_RELEASE_CHECK=0 PATH="$rc_stub:$PATH" bash "$rc_hook" 2>&1)"; status=$?
[ -z "$out" ] && [ "$status" -eq 0 ] && [ "$(rc_calls)" = "0" ] && [ ! -e "$rc_cache" ] && ok "GODOT_DIRECTOR_RELEASE_CHECK=0 turns the hook off: nothing printed, git not called" || bad "GODOT_DIRECTOR_RELEASE_CHECK=0 turns the hook off" "exit $status: $out"
rc_set "# godot-director 4.10.0" v4.11.0
rm -f "$rc_proj/.godot-director/manifest"
out="$(rc_run)"; status=$?
[ -z "$out" ] && [ "$status" -eq 0 ] && [ "$(rc_calls)" = "0" ] && ok "a project with no manifest: nothing printed, git not called" || bad "a project with no manifest: nothing printed, git not called" "exit $status: $out"
printf '# tools claude\n%s\t.claude/settings.json\n' "$rc_sha" > "$rc_proj/.godot-director/manifest"
out="$(rc_run)"; status=$?
[ -z "$out" ] && [ "$status" -eq 0 ] && [ "$(rc_calls)" = "0" ] && ok "a manifest with no version line: nothing printed, git not called" || bad "a manifest with no version line: nothing printed, git not called" "exit $status: $out"
rc_set "# godot-director 4.x" v4.11.0
out="$(rc_run)"; status=$?
[ -z "$out" ] && [ "$status" -eq 0 ] && [ "$(rc_calls)" = "0" ] && ok "and one whose version isn't three numbers" || bad "and one whose version isn't three numbers" "exit $status: $out"
out="$(printf '{}' | CLAUDE_PROJECT_DIR="$work/no-such-folder" PATH="$rc_stub:$PATH" bash "$rc_hook" 2>&1)"; status=$?
[ -z "$out" ] && [ "$status" -eq 0 ] && ok "a project folder that doesn't exist: nothing printed, exit 0" || bad "a project folder that doesn't exist: nothing printed, exit 0" "exit $status: $out"

# 9. The project check never runs it, so a warning can't fail tools/check.sh; settings.json runs it at session start only.
if ! grep -rq 'release-check' "$src/framework/tools" "$src/framework/.githooks" "$src/framework/.godot-director"; then ok "the project check and the git hooks don't run the release check, so a warning never fails tools/check.sh"
else bad "the project check and the git hooks don't run the release check" "$(grep -rn 'release-check' "$src/framework/tools" "$src/framework/.githooks" "$src/framework/.godot-director")"; fi
wiring="$(awk '/^    "[A-Za-z]+": \[/ { ev = $1; gsub(/[":]/, "", ev) } /"matcher"/ { split($0, a, "\""); m = a[4] }
  /release-check\.sh/ { hit = ev ";" m; next } hit != "" && /"timeout"/ { t = $2; gsub(/[^0-9]/, "", t); print hit ";" t; hit = "" }' "$settings")"
[ "$wiring" = "SessionStart;startup|resume;10" ] && ok "settings.json runs the release check at SessionStart, on startup and resume, with a timeout of 10 seconds" \
  || bad "settings.json runs the release check at SessionStart, on startup and resume, with a timeout of 10 seconds" "$wiring"
bash4=$(grep -nE '^[^#]*(\$\{[A-Za-z_0-9]+(\[[^]]*\])?(,,|\^\^)\}|(declare|local|typeset) +-[a-zA-Z]*A|(^|[;&| ])(mapfile|readarray) +|(^|[;&| ])coproc +[A-Za-z]|[[:space:]]\|&[[:space:]]|\$\{[A-Za-z_0-9@*]+(\[[^]]*\])?: -[0-9]|stat +-c|date +-d|sed +-i|readlink +-f|-printf|-delete)' \
  "$rc_hook" || true)
if [ -z "$bash4" ]; then ok "the release check uses no bash 4 form and no GNU-only tool flag"; else bad "the release check uses no bash 4 form and no GNU-only tool flag" "$bash4"; fi

}

l_orphan_report() {
cd "$work" || exit 1
# --- orphan report hook -------------------------------------------------------------------------
# orphan-report.sh runs when a session starts and lists the Python, node, shell, Godot and headless browser processes that are
# an hour old or more and whose parent is gone. Stand-ins first on PATH answer for the process list (powershell.exe on Windows, ps
# elsewhere, and uname to choose between them), and others stand in for every program that stops a process, so no case reads this
# machine's own processes or could stop one. It needs no Godot, so it is a lane of its own.
echo "orphan report hook"
or_hook="$src/framework/.claude/hooks/orphan-report.sh"
or_stub="$work/or-stub"; or_tstub="$work/or-tstub"; or_t124="$work/or-t124"; or_bare="$work/or-bare"; or_cwd="$work/or-cwd"
mkdir -p "$or_stub" "$or_tstub" "$or_t124" "$or_bare" "$or_cwd"
cat > "$or_stub/uname" <<'EOF'
#!/bin/bash
# a stand-in uname: the system a case sets in uname-is, Linux when it sets none
if [ -f "$OR_STUB/uname-is" ]; then IFS= read -r line < "$OR_STUB/uname-is"; echo "$line"; else echo Linux; fi
EOF
cat > "$or_stub/ps" <<'EOF'
#!/bin/bash
# a stand-in ps: it records its arguments, then fails when ps-fails exists, or prints the rows a case sets
printf '%s\n' "$*" >> "$OR_STUB/ps-calls"
[ -e "$OR_STUB/ps-fails" ] && exit 1
while IFS= read -r line; do printf '%s\n' "$line"; done < "$OR_STUB/ps-rows"
EOF
cat > "$or_stub/powershell.exe" <<'EOF'
#!/bin/bash
# a stand-in powershell.exe: it records its arguments, then fails when pwsh-fails exists, or prints the rows a case sets, with PowerShell's line ends
printf '%s\n' "$*" >> "$OR_STUB/pwsh-calls"
[ -e "$OR_STUB/pwsh-fails" ] && exit 1
while IFS= read -r line; do printf '%s\r\n' "$line"; done < "$OR_STUB/win-rows"
EOF
cat > "$or_stub/kill" <<'EOF'
#!/bin/bash
# a stand-in for a program that stops a process: it records the call, and no case should make one
printf '%s %s\n' "${0##*/}" "$*" >> "$OR_STUB/killed"
EOF
cp "$or_stub/kill" "$or_stub/taskkill"; cp "$or_stub/kill" "$or_stub/taskkill.exe"; cp "$or_stub/kill" "$or_stub/pkill"; cp "$or_stub/kill" "$or_stub/killall"
cat > "$or_tstub/timeout" <<'EOF'
#!/bin/bash
# a stand-in timeout: it records its limit and runs the command
printf '%s\n' "$1" >> "$OR_STUB/timeouts"
shift
exec "$@"
EOF
cat > "$or_t124/timeout" <<'EOF'
#!/bin/bash
# a stand-in timeout that runs out: the command runs, then the status is 124, as when the limit ends it
shift
"$@"
exit 124
EOF
cat > "$or_bare/uname" <<'EOF'
#!/bin/bash
echo MINGW64_NT-10.0-26300
EOF
chmod +x "$or_stub"/* "$or_tstub/timeout" "$or_t124/timeout" "$or_bare/uname"
# The builtin kill is no program on PATH, so a function stands in for it, exported to reach the hook's own bash.
kill() { printf 'kill %s\n' "$*" >> "$OR_STUB/killed"; }
export -f kill
unset GODOT_DIRECTOR_ORPHAN_REPORT
export OR_STUB="$or_stub"
or_ask="Tell the human this once, in your first reply, and don't stop them unless the human asks."
or_set() { # or_set <win|ps> [<pid> <ppid> <age in seconds> <name>]…: that machine, with these processes, in the shape of its list
  local shape="$1" f d h m s
  shift
  rm -f "$or_stub/ps-calls" "$or_stub/pwsh-calls" "$or_stub/ps-fails" "$or_stub/pwsh-fails" "$or_stub/timeouts" "$or_stub/uname-is" "$or_stub/ps-rows" "$or_stub/win-rows"
  if [ "$shape" = win ]; then echo MINGW64_NT-10.0-26300 > "$or_stub/uname-is"; f="$or_stub/win-rows"; else f="$or_stub/ps-rows"; fi
  : > "$f"
  while [ "$#" -ge 4 ]; do
    if [ "$shape" = win ]; then
      printf '%s %s %s %s\n' "$1" "$2" "$3" "$4" >> "$f"
    else   # etime as ps writes it: dd-hh:mm:ss, hh:mm:ss or mm:ss
      d=$(($3 / 86400)); h=$(($3 % 86400 / 3600)); m=$(($3 % 3600 / 60)); s=$(($3 % 60))
      if [ "$d" -gt 0 ]; then printf '%6s %5s %d-%02d:%02d:%02d %s\n' "$1" "$2" "$d" "$h" "$m" "$s" "$4" >> "$f"
      elif [ "$h" -gt 0 ]; then printf '%6s %5s %02d:%02d:%02d %s\n' "$1" "$2" "$h" "$m" "$s" "$4" >> "$f"
      else printf '%6s %5s %02d:%02d %s\n' "$1" "$2" "$m" "$s" "$4" >> "$f"; fi
    fi
    shift 4
  done
}
or_raw() { # or_raw <win|ps> <line>…: that machine, with these lines as its list, as given
  local shape="$1" f l
  or_set "$shape"
  shift
  if [ "$shape" = win ]; then f="$or_stub/win-rows"; else f="$or_stub/ps-rows"; fi
  for l in "$@"; do printf '%s\n' "$l" >> "$f"; done
}
or_run() { # the hook's output, stdout and stderr together; its exit status is the hook's
  printf '{"session_id":"s","hook_event_name":"SessionStart","source":"startup"}' | PATH="$or_stub:$PATH" bash "$or_hook" 2>&1
}
or_json() { # or_json <list>: the line the hook prints for this list
  local t="Processes that outlived the shell that started them (parent gone, over an hour old): $1. They may be left over from an ended session. Stopping them is your call."
  printf '{"systemMessage":"%s","hookSpecificOutput":{"hookEventName":"SessionStart","additionalContext":"%s %s"}}' "$t" "$t" "$or_ask"
}
or_expect() { # or_expect <what> [<list>]: the process list was read, the hook exits 0 and prints the line for this list, or nothing without one
  local out status read_it=no
  out="$(or_run)"; status=$?
  { [ -e "$or_stub/ps-calls" ] || [ -e "$or_stub/pwsh-calls" ]; } && read_it=yes
  if [ -z "${2:-}" ]; then
    [ -z "$out" ] && [ "$status" -eq 0 ] && [ "$read_it" = yes ] && ok "$1" || bad "$1" "exit $status, list read: $read_it: $out"
  else
    [ "$out" = "$(or_json "$2")" ] && [ "$status" -eq 0 ] && [ "$read_it" = yes ] && ok "$1" || bad "$1" "exit $status, list read: $read_it: $out"
  fi
}

# 0. The stand-ins are in place: the stop programs are first on PATH, and the builtin kill is a function in the hook's own bash.
if [ "$(PATH="$or_stub:$PATH" type -P taskkill)" = "$or_stub/taskkill" ] && [ "$(PATH="$or_stub:$PATH" type -P pkill)" = "$or_stub/pkill" ] && [ "$(bash -c 'type -t kill')" = function ]; then
  ok "stand-ins for kill, taskkill and pkill are in place before every case"
else bad "stand-ins for kill, taskkill and pkill are in place before every case" "$(PATH="$or_stub:$PATH" type -P taskkill) $(bash -c 'type -t kill')"; fi

# 1. The cases that read the same on both machines, with the rows in the shape of each one's list.
or_cases() { # or_cases <win|ps> <label>
  local sh="$1" lb="$2" x="" X="" odd good
  if [ "$sh" = win ]; then x=".exe"; X=".EXE"; fi
  or_set "$sh" 4 0 900000 System 500 999 3600 "python3.13$x"
  or_expect "$lb: an hour-old python3.13 with a dead parent is listed" "pid 500 python3.13 (1 h)"
  or_set "$sh" 600 700 7200 "python3.13$x" 700 4 9000 "explorer$x"
  or_expect "$lb: a process with a live parent isn't" ""
  or_set "$sh" 500 999 3540 "python3.13$x" 501 999 3599 "node$x"
  or_expect "$lb: processes 59 minutes old aren't" ""
  or_set "$sh" 500 600 7200 "node$x" 600 4 100 "cmd$x"
  or_expect "$lb: a process whose parent row is younger is listed (a reused pid)" "pid 500 node (2 h)"
  or_set "$sh" 500 600 7200 "node$x" 600 4 7200 "cmd$x"
  or_expect "$lb: and one whose parent is as old is not" ""
  or_set "$sh" 40 999 7200 "notepad$x" 41 999 7200 "sshd$x" 42 999 7200 "nodejs$x" 43 999 7200 "bashful$x" 44 999 7200 "pythonista$x" 45 999 7200 "python3.x$x" 46 999 7200 "pyw$x" 47 999 7200 "shell$x" 48 999 7200 "godo$x" 49 999 7200 "chrome-headless-shells$x"
  or_expect "$lb: names that aren't on the list (notepad, sshd, nodejs, bashful, python3.x, godo...) aren't listed" ""
  or_set "$sh" 25 999 37000 "pythonw$x" 30 999 32000 "Godot_v4.7.2-stable_win64_console$x" 21 999 41000 "python$x" 28 999 34000 "bash$x" 22 999 40000 "python3$x" 26 999 36000 "py$x" 24 999 38000 "PYTHON3.13$X" 29 999 33000 "sh$x" 23 999 39000 "python3.9$x" 27 999 35000 "node$x"
  or_ten="pid 21 python (11 h), pid 22 python3 (11 h), pid 23 python3.9 (10 h), pid 24 PYTHON3.13 (10 h), pid 25 pythonw (10 h), pid 26 py (10 h), pid 27 node (9 h), pid 28 bash (9 h), pid 29 sh (9 h), pid 30 Godot_v4.7.2-stable_win64_console (8 h)"
  or_expect "$lb: python, python3, python3.<n>, pythonw, py, node, bash, sh and godot*, in any case, are listed, oldest first" "$or_ten"
  or_set "$sh" 31 999 31000 "chrome-headless-shell$x" 25 999 37000 "pythonw$x" 30 999 32000 "Godot_v4.7.2-stable_win64_console$x" 21 999 41000 "python$x" 28 999 34000 "bash$x" 22 999 40000 "python3$x" 26 999 36000 "py$x" 24 999 38000 "PYTHON3.13$X" 29 999 33000 "sh$x" 23 999 39000 "python3.9$x" 27 999 35000 "node$x"
  or_expect "$lb: eleven orphans print the oldest ten and 'and 1 more' (a headless browser is on the list)" "$or_ten, and 1 more"
  or_set "$sh" 31 999 31000 "chrome-headless-shell$x" 32 999 30000 "node$x" 33 999 29000 "node$x" 25 999 37000 "pythonw$x" 30 999 32000 "Godot_v4.7.2-stable_win64_console$x" 21 999 41000 "python$x" 28 999 34000 "bash$x" 22 999 40000 "python3$x" 26 999 36000 "py$x" 24 999 38000 "PYTHON3.13$X" 29 999 33000 "sh$x" 23 999 39000 "python3.9$x" 27 999 35000 "node$x"
  or_expect "$lb: thirteen print ten and 'and 3 more'" "$or_ten, and 3 more"
  or_set "$sh" 31 999 172801 "node$x" 32 999 172800 "node$x" 33 999 50400 "python3.13$x" 34 999 259200 "node$x" 35 999 7199 "bash$x"
  or_expect "$lb: ages read as hours up to 48 and as days after" "pid 34 node (3 d), pid 31 node (2 d), pid 32 node (48 h), pid 33 python3.13 (14 h), pid 35 bash (1 h)"
  odd='godot "x" \y {z}, $(w) `v` 100%'
  or_set "$sh" 70 999 7200 "$odd$x" 71 999 3700 $'godot\303\276x'"$x"
  or_expect "$lb: a name with quotes, backslashes, braces, a substitution and a percent sign is cut down to [A-Za-z0-9._-], so the JSON holds" "pid 70 godotxyzwv100 (2 h), pid 71 godotx (1 h)"
  if [ "$sh" = win ]; then good="80 999 7200 node.exe"; else good="   80   999 02:00:00 node"; fi
  or_raw "$sh" 'PID PPID ELAPSED COMM' '1 2' 'a b c d' "5 6 -3 node$x" "7 8 9999999999999 node$x" '' "$good"
  or_expect "$lb: rows that aren't pid, ppid, age and name (a header, a short row, words, a negative age) are skipped" "pid 80 node (2 h)"
  or_set "$sh"
  or_expect "$lb: an empty list prints nothing" ""
  or_set "$sh" 500 999 7200 "node$x"
  if [ "$sh" = win ]; then : > "$or_stub/pwsh-fails"; else : > "$or_stub/ps-fails"; fi
  or_expect "$lb: a process tool that fails prints nothing and exits 0" ""
  or_set "$sh" 500 999 7200 "node$x"
  out="$(printf '{}' | GODOT_DIRECTOR_ORPHAN_REPORT=0 PATH="$or_stub:$PATH" bash "$or_hook" 2>&1)"; status=$?
  if [ -z "$out" ] && [ "$status" -eq 0 ] && [ ! -e "$or_stub/ps-calls" ] && [ ! -e "$or_stub/pwsh-calls" ]; then ok "$lb: GODOT_DIRECTOR_ORPHAN_REPORT=0 turns the hook off: nothing printed, the process list not read"
  else bad "$lb: GODOT_DIRECTOR_ORPHAN_REPORT=0 turns the hook off" "exit $status: $out"; fi
}
or_cases win "Windows list"
or_cases ps "ps list"

# 2. Windows: PowerShell is asked for the processes, under timeout 8 when timeout exists, and the list's own shape is read.
or_set win 500 999 7200 node.exe
out="$(or_run)"
case "$(<"$or_stub/pwsh-calls")" in
  "-NoProfile -NonInteractive -Command "*"Get-CimInstance Win32_Process"*"CreationDate"*) ok "Windows: PowerShell runs with -NoProfile -NonInteractive -Command, and asks Get-CimInstance Win32_Process for each CreationDate" ;;
  *) bad "Windows: PowerShell runs with -NoProfile -NonInteractive -Command, and asks Get-CimInstance Win32_Process for each CreationDate" "$(<"$or_stub/pwsh-calls")" ;;
esac
case "$(<"$or_stub/pwsh-calls")" in
  *'if($_.CreationDate)'*) ok "and skips a process that has no CreationDate" ;;
  *) bad "and skips a process that has no CreationDate" "$(<"$or_stub/pwsh-calls")" ;;
esac
[ ! -e "$or_stub/ps-calls" ] && ok "and ps isn't run" || bad "and ps isn't run" "$(<"$or_stub/ps-calls")"
or_set win 500 999 7200 node.exe
out="$(printf '{}' | PATH="$or_tstub:$or_stub:$PATH" bash "$or_hook" 2>&1)"
[ "$out" = "$(or_json 'pid 500 node (2 h)')" ] && [ "$(<"$or_stub/timeouts")" = "8" ] && [ -e "$or_stub/pwsh-calls" ] && ok "the PowerShell run is under timeout 8 when timeout exists" || bad "the PowerShell run is under timeout 8 when timeout exists" "$out"
or_set win 500 999 7200 node.exe
out="$(printf '{}' | PATH="$or_stub:/nonexistent" "$BASH" "$or_hook" 2>&1)"
[ "$out" = "$(or_json 'pid 500 node (2 h)')" ] && [ ! -e "$or_stub/timeouts" ] && ok "and without timeout on PATH it still asks" || bad "and without timeout on PATH it still asks" "$out"
or_set win 500 999 7200 node.exe
out="$(printf '{}' | PATH="$or_t124:$or_stub:$PATH" bash "$or_hook" 2>&1)"; status=$?
[ -z "$out" ] && [ "$status" -eq 0 ] && [ -e "$or_stub/pwsh-calls" ] && ok "a PowerShell run that times out (status 124) prints nothing, even with rows read, and exits 0" || bad "a PowerShell run that times out prints nothing" "exit $status: $out"
out="$(printf '{}' | PATH="$or_bare" "$BASH" "$or_hook" 2>&1)"; status=$?
[ -z "$out" ] && [ "$status" -eq 0 ] && ok "a Windows machine with no PowerShell prints nothing and exits 0" || bad "a Windows machine with no PowerShell prints nothing and exits 0" "exit $status: $out"
or_set win 600 0 7200 node.exe
or_expect "Windows: a ppid of 0 is a gone parent" "pid 600 node (2 h)"
for or_sys in MSYS_NT-10.0-26200 CYGWIN_NT-10.0-19045; do
  or_set win 500 999 7200 node.exe
  echo "$or_sys" > "$or_stub/uname-is"
  or_expect "$or_sys is a Windows machine too" "pid 500 node (2 h)"
done

# 3. Elsewhere: ps -A -o pid=,ppid=,etime=,comm=, with etime read from [[dd-]hh:]mm:ss and comm cut to its base name.
or_set ps 500 999 7200 node
out="$(printf '{}' | PATH="$or_tstub:$or_stub:$PATH" bash "$or_hook" 2>&1)"
[ "$out" = "$(or_json 'pid 500 node (2 h)')" ] && [ "$(<"$or_stub/ps-calls")" = "-A -o pid=,ppid=,etime=,comm=" ] && [ ! -e "$or_stub/pwsh-calls" ] && [ ! -e "$or_stub/timeouts" ] \
  && ok "elsewhere ps -A -o pid=,ppid=,etime=,comm= is run, with no PowerShell and no timeout" || bad "elsewhere ps -A -o pid=,ppid=,etime=,comm= is run" "$out"
or_raw ps '   11     1 10-00:00:00 node' '   12     1  2-01:00:00 node' '   13     1  1-23:59:59 node' '   14     1  1-08:09:09 node' '   15     1    08:09:09 node' \
  '   16     1    01:08:09 node' '   17     1       60:00 node' '   18     1       59:59 node' '   19     1    00:59:59 node'
or_expect "etime reads right as dd-hh:mm:ss, hh:mm:ss and mm:ss, with zeros that aren't octal (08:09:09), and 59:59 is under the hour" \
  "pid 11 node (10 d), pid 12 node (2 d), pid 13 node (47 h), pid 14 node (32 h), pid 15 node (8 h), pid 16 node (1 h), pid 17 node (1 h)"
or_raw ps '   81     1 05:00:00 /usr/local/bin/node' '   82     1 04:00:00 /Applications/Some App.app/Contents/MacOS/python3.13' '   83     1 03:00:00 chrome-headless' \
  '   84     1 02:00:01 Godot_v4.7-stab' '   85     1 02:00:00 /usr/sbin/sshd'
or_expect "comm is cut to its base name (a path with spaces too), and Linux's 15-character chrome-headless counts" \
  "pid 81 node (5 h), pid 82 python3.13 (4 h), pid 83 chrome-headless (3 h), pid 84 Godot_v4.7-stab (2 h)"
or_raw ps '    1     0 10-00:00:00 launchd' '   90     1 02:00:00 node' '   91     0 02:00:00 sh'
or_expect "a ppid of 1 or 0 is a gone parent, though a row for pid 1 exists and is older" "pid 90 node (2 h), pid 91 sh (2 h)"
or_set ps 500 999 7200 node
out="$(printf '{}' | PATH="/nonexistent" "$BASH" "$or_hook" 2>&1)"; status=$?
[ -z "$out" ] && [ "$status" -eq 0 ] && ok "a machine with no ps (and no uname) prints nothing and exits 0" || bad "a machine with no ps (and no uname) prints nothing and exits 0" "exit $status: $out"
or_set ps 500 999 7200 node
echo Darwin > "$or_stub/uname-is"
or_expect "Darwin reads ps too" "pid 500 node (2 h)"

# 4. It only reads: nothing is stopped, signalled or written.
if [ ! -e "$or_stub/killed" ]; then ok "no case called kill, taskkill, pkill or killall"; else bad "no case called kill, taskkill, pkill or killall" "$(<"$or_stub/killed")"; fi
or_set ps 500 999 7200 node
out="$(cd "$or_cwd" && printf '{}' | PATH="$or_stub:$PATH" bash "$or_hook" 2>&1)"
if [ -n "$out" ] && [ -z "$(ls -A "$or_cwd")" ]; then ok "a run writes no file in the folder it runs in"; else bad "a run writes no file in the folder it runs in" "$(ls -A "$or_cwd")"; fi
stops=$(grep -vE '^[[:space:]]*#' "$or_hook" | grep -niE 'kill|Stop-Process|Remove-|Set-|New-Item|Out-File|Add-Content|Invoke-' || true)
if [ -z "$stops" ]; then ok "the hook names no command that stops, changes or writes anything"; else bad "the hook names no command that stops, changes or writes anything" "$stops"; fi
writes=$(grep -vE '^[[:space:]]*#' "$or_hook" | grep '>' | grep -v '/dev/null' || true)
if [ -z "$writes" ]; then ok "and redirects its output nowhere but /dev/null"; else bad "and redirects its output nowhere but /dev/null" "$writes"; fi
unset -f kill

# 5. The project check never runs it; settings.json runs it at session start with the release check, in one entry.
if ! grep -rq 'orphan-report' "$src/framework/tools" "$src/framework/.githooks" "$src/framework/.godot-director"; then ok "the project check and the git hooks don't run the orphan report, so a report never fails tools/check.sh"
else bad "the project check and the git hooks don't run the orphan report" "$(grep -rn 'orphan-report' "$src/framework/tools" "$src/framework/.githooks" "$src/framework/.godot-director")"; fi
wiring="$(awk '/^    "[A-Za-z]+": \[/ { ev = $1; gsub(/[":]/, "", ev) } /"matcher"/ { split($0, a, "\""); m = a[4] }
  /orphan-report\.sh/ { hit = ev ";" m; next } hit != "" && /"timeout"/ { t = $2; gsub(/[^0-9]/, "", t); print hit ";" t; hit = "" }' "$settings")"
[ "$wiring" = "SessionStart;startup|resume;10" ] && ok "settings.json runs the orphan report at SessionStart, on startup and resume, with a timeout of 10 seconds" \
  || bad "settings.json runs the orphan report at SessionStart, on startup and resume, with a timeout of 10 seconds" "$wiring"
entry="$(awk '/^    "[A-Za-z]+": \[/ { ev = $1; gsub(/[":]/, "", ev) } ev == "SessionStart" && /"matcher"/ { m++ } ev == "SessionStart" && /"command":/ { n++ } END { print m ";" n }' "$settings")"
[ "$entry" = "1;2" ] && ok "and in the same entry as the release check: one matcher, two hooks" || bad "and in the same entry as the release check: one matcher, two hooks" "$entry"
bash4=$(grep -nE '^[^#]*(\$\{[A-Za-z_0-9]+(\[[^]]*\])?(,,|\^\^)\}|(declare|local|typeset) +-[a-zA-Z]*A|(^|[;&| ])(mapfile|readarray) +|(^|[;&| ])coproc +[A-Za-z]|[[:space:]]\|&[[:space:]]|\$\{[A-Za-z_0-9@*]+(\[[^]]*\])?: -[0-9]|stat +-c|date +-d|sed +-i|readlink +-f|-printf|-delete)' \
  "$or_hook" || true)
if [ -z "$bash4" ]; then ok "the orphan report uses no bash 4 form and no GNU-only tool flag"; else bad "the orphan report uses no bash 4 form and no GNU-only tool flag" "$bash4"; fi
if grep -q 'GODOT_DIRECTOR_ORPHAN_REPORT=0' "$src/PRIVACY.md" && grep -q 'names, ids and ages of the processes on this machine' "$src/PRIVACY.md" && grep -q 'ended session left behind' "$src/README.md"; then
  ok "PRIVACY.md says the hook reads the names, ids and ages of the processes and names the switch, and the README names the hook"
else bad "PRIVACY.md says the hook reads the names, ids and ages of the processes and names the switch, and the README names the hook"; fi

}

l_precommit() {
lane_game warm
git add -A && { git_q commit -qm "state for the hook tests" >/dev/null 2>&1 || true; }
# --- pre-commit hook ----------------------------------------------------------------------------
echo "pre-commit hook"
printf 'func broken( -> void:\n' >> scripts/systems/market.gd
git add scripts/systems/market.gd
out="$(git_q commit -qm "broken" 2>&1)"; expect_status "blocks a commit that fails the check" 1 $? "$out"
git reset -q HEAD -- scripts/systems/market.gd && git checkout -q -- scripts/systems/market.gd
printf '\n# a harmless change\n' >> scripts/systems/market.gd
git add scripts/systems/market.gd
out="$(git_q commit -qm "fine" 2>&1)"; expect_status "allows a commit that passes" 0 $? "$out"
printf '# notes\n' > notes.md && git add notes.md
out="$(git_q commit -qm "docs only" 2>&1)"; expect_status "allows a docs-only commit" 0 $? "$out"
expect_no_output "doesn't run the check for a docs-only commit" "running the project check" "$out"
# A research item changes no code: its note and the records commit without the check.
mkdir -p design/research
printf '# Which Web export options fit a 2D game\nR1 · Informs: (none) · Verified as of 2026-10-15 · Size: M\n' > design/research/2026-10-15-web-export.md
git add design/research/2026-10-15-web-export.md
out="$(git_q commit -qm "docs: research Web export (R1)" 2>&1)"; status=$?
expect_status "allows a commit with only a research note" 0 "$status" "$out"
expect_no_output "doesn't run the check for a research note" "running the project check" "$out"
cp scenes/shop_screen.tscn "scenes/þorp.tscn" && git add "scenes/þorp.tscn"
out="$(git_q commit -qm "non-ASCII scene" 2>&1)"; status=$?
expect_output "runs the check for a non-ASCII file name" "running the project check" "$out"
expect_status "commits it" 0 "$status" "$out"
printf 'x\n' > tools/check.sh.gdir-new
printf '\n# another change\n' >> scripts/systems/market.gd && git add scripts/systems/market.gd
out="$(git_q commit -qm "with gdir-new" 2>&1)"; expect_status "refuses while a .gdir-new file is unmerged" 1 $? "$out"
rm -f tools/check.sh.gdir-new

# A nested clone in an ignored folder is listed by ls-files as a directory. It doesn't block a
# commit, but a real upgrade file still does while the clone is there.
git restore --staged scripts/systems/market.gd && git checkout -- scripts/systems/market.gd
printf '/clones/\n' >> .git/info/exclude
mkdir -p clones/nested && (cd clones/nested && git init -q && git_q commit -q --allow-empty -m nested) >/dev/null 2>&1
out="$(git_q commit -q --allow-empty -m "with a nested clone" 2>&1)"
expect_status "a nested clone in an ignored folder doesn't block a commit" 0 $? "$out"
printf 'x\n' > tools/check.sh.gdir-new
out="$(git_q commit -q --allow-empty -m "with a nested clone and gdir-new" 2>&1)"
expect_status "a real upgrade file still blocks with a nested clone present" 1 $? "$out"
expect_no_output "names the upgrade file, not the nested clone" "clones/" "$out"
rm -f tools/check.sh.gdir-new
no_project="$work/no-project"; new_repo "$no_project"
bash "$src/install.sh" "$no_project" >/dev/null 2>&1
(cd "$no_project" && printf '%s\n' "$godot" > tools/godot_bin.local && bash tools/setup-clone.sh >/dev/null 2>&1 \
  && git add -A && git_q commit -qm "install" >/dev/null 2>&1)
expect_status "commits in a repository without project.godot yet" 0 $?

}

l_secrets_a() {
lane_game warm
# --- secrets (gitleaks) -------------------------------------------------------------------------
# gitleaks is optional. With it installed, the check scans the working tree (each credential listed as
# file:line, the value redacted) and the pre-commit hook scans the staged changes of every commit,
# whatever is staged. Without it both print a note and go on, so a game needs no extra install. A
# gitleaks that is installed but too old or unable to scan is a check that couldn't run (exit 3). A
# stand-in gitleaks covers the exit codes, the scan commands and the hook's output on any machine; the
# cases with the real one are skipped with a note when it isn't installed (or is 8.19.0, which can't
# scan). Every token is assembled at run time ("ghp_" and 36 generated letters and digits) and written
# only into a temporary copy of the example, never into a tracked file.
echo "secrets"
gitleaks_prelude
[ "$_no_gl_ok" -eq 1 ] || echo "  skip  the cases without gitleaks on PATH (no PATH without it keeps the other tools)"

# The seeds: gitleaks's built-in rules, and the allowlist for .godot/ (Godot's gitignored cache, which holds
# the export credentials). The example carries the same file.
if grep -q '^useDefault = true$' "$src/project/.gitleaks.toml" && grep -qF "'''^\\.godot[\\\\/]'''" "$src/project/.gitleaks.toml" \
    && cmp -s "$src/project/.gitleaks.toml" "$src/examples/market-day/.gitleaks.toml" \
    && grep -q '^\[gitleaks\]$' "$src/project/tools/check.cfg" && grep -q '^min-version="8\.18\.0"$' "$src/project/tools/check.cfg"; then
  ok "the seeds: .gitleaks.toml (built-in rules, .godot/ allowlisted, the example's copy the same) and [gitleaks] min-version in check.cfg"
else
  bad "the seeds: .gitleaks.toml and [gitleaks] min-version in check.cfg"
fi

sg="$work/secrets-game"
cp -R "$game" "$sg" && rm -rf "$sg/clones"
cd "$sg" || exit 1
git add -A && { git_q commit -qm "state for the secrets tests" >/dev/null 2>&1 || true; }
cp tools/check.cfg "$work/saved-check-cfg-gl"

# Exit codes with a stand-in: an installed gitleaks that is too old, or can't scan, is a check that
# couldn't run (3), and the minimum comes from tools/check.cfg. None of them is a finding.
out="$(PATH="$_fake_gl:$PATH" FAKE_GL_VERSION=8.17.0 bash tools/check.sh 2>&1)"; status=$?
expect_status "a gitleaks below the minimum is a check that couldn't run (stand-in 8.17.0)" 3 "$status" "$out"
expect_output "and says which minimum" "gitleaks 8\.17\.0 is below the minimum 8\.18\.0" "$out"
out="$(PATH="$_fake_gl:$PATH" FAKE_GL_VERSION=8.19.0 FAKE_GL_ERROR="flag accessed but not defined: source" bash tools/check.sh 2>&1)"; status=$?
expect_status "gitleaks 8.19.0, which can't scan, is a check that couldn't run (stand-in)" 3 "$status" "$out"
expect_output "and says to upgrade to 8.19.1 or later" "8\.19\.0 can't scan.*8\.19\.1 or later" "$out"
expect_no_output "and doesn't call a scan error a finding" "possible credential|found in" "$out"
out="$(PATH="$_fake_gl:$PATH" FAKE_GL_VERSION=8.30.1 FAKE_GL_ERROR="could not read the config" bash tools/check.sh 2>&1)"; status=$?
expect_status "a scan that fails with no finding is a check that couldn't run (stand-in 8.30.1)" 3 "$status" "$out"
expect_output "and shows gitleaks's own last line" "gitleaks: could not read the config" "$out"
printf '\n[gitleaks]\nmin-version="9.0.0"\n' >> tools/check.cfg
out="$(PATH="$_fake_gl:$PATH" FAKE_GL_VERSION=8.30.1 bash tools/check.sh 2>&1)"; status=$?
expect_status "the minimum is read from tools/check.cfg [gitleaks] min-version" 3 "$status" "$out"
expect_output "and the message names it" "below the minimum 9\.0\.0" "$out"
cp "$work/saved-check-cfg-gl" tools/check.cfg

# The scan command: dir from 8.19.1, detect --no-git before it; gitleaks's version is read once per run.
_fake_log="$work/fake-gl.log"; rm -f "$_fake_log"
out="$(PATH="$_fake_gl:$PATH" FAKE_GL_VERSION=8.30.1 FAKE_GL_LOG="$_fake_log" bash tools/check.sh 2>&1)"; status=$?
expect_status "a clean game passes with a stand-in gitleaks 8.30.1" 0 "$status" "$out"
expect_output "and says that nothing was found" "check: secrets: no credentials found \(gitleaks 8\.30\.1\)" "$out"
grep -q '^dir --redact --report-path=' "$_fake_log" && ok "gitleaks 8.30.1 scans with dir" || bad "gitleaks 8.30.1 scans with dir" "$(cat "$_fake_log")"
[ "$(grep -c '^version$' "$_fake_log")" -eq 1 ] && ok "and gitleaks's version is read once" || bad "and gitleaks's version is read once" "$(cat "$_fake_log")"
rm -f "$_fake_log"
out="$(PATH="$_fake_gl:$PATH" FAKE_GL_VERSION=8.18.0 FAKE_GL_LOG="$_fake_log" bash tools/check.sh 2>&1)"; status=$?
expect_status "a clean game passes with a stand-in gitleaks 8.18.0" 0 "$status" "$out"
grep -q '^detect --no-git --redact --report-path=' "$_fake_log" && ok "gitleaks 8.18.0 scans with detect --no-git" || bad "gitleaks 8.18.0 scans with detect --no-git" "$(cat "$_fake_log")"

}

l_secrets_b() {
lane_game warm
gitleaks_prelude
sg="$work/secrets-game"
cp -R "$game" "$sg" && rm -rf "$sg/clones"
cd "$sg" || exit 1
git add -A && { git_q commit -qm "state for the secrets tests" >/dev/null 2>&1 || true; }
cp tools/check.cfg "$work/saved-check-cfg-gl"
# A game with a secret in a script and in a config file, assembled at run time.
gen_token; tok_script="$_tok"; gen_token; tok_cfg="$_tok"; gen_token; tok_note="$_tok"
printf 'extends RefCounted\n\nconst API_TOKEN: String = "%s"\n' "$tok_script" > scripts/secret_config.gd
printf '[store]\nupload_token="%s"\n' "$tok_cfg" > data/store.cfg
printf '# Upload\n\nstore_token = %s\n' "$tok_note" > notes_upload.md

if [ "$_no_gl_ok" -eq 1 ]; then
  out="$(PATH="$_no_gl_path" bash tools/check.sh 2>&1)"; status=$?
  expect_status "the same game passes the check without gitleaks on PATH" 0 "$status" "$out"
  expect_output "and prints the note that names the install" "check: note: gitleaks isn't installed, so the check doesn't scan for secrets; install it from https://github.com/gitleaks/gitleaks#installing" "$out"
  expect_no_output "and doesn't scan" "check: secrets" "$out"
fi

if [ "$_gl_ok" -eq 1 ]; then
  # --if-changed after a pass recorded without gitleaks: the cached result depends on gitleaks's version,
  # so installing it makes the fast path scan.
  out="$(bash tools/check.sh --if-changed 2>&1)"; status=$?
  expect_status "installing gitleaks makes --if-changed scan, and the secrets fail the check" 1 "$status" "$out"
  expect_no_output "it doesn't repeat the pass recorded without gitleaks" "nothing changed" "$out"
  expect_output "the script's secret is named by file and line" "scripts/secret_config\.gd:3 \(" "$out"
  expect_output "and the config file's" "data/store\.cfg:2 \(" "$out"
  expect_output "and a Markdown note's: the working tree is scanned whatever the file" "notes_upload\.md:3 \(" "$out"
  expect_output "the report is named, with the values redacted" "Report \(values redacted\): \.godot/godot-director/gitleaks\.json" "$out"
  expect_no_output "the output has no token" "$tok_script|$tok_cfg|$tok_note" "$out"
  grep -qE "$tok_script|$tok_cfg|$tok_note" .godot/godot-director/gitleaks.json \
    && bad "the report has no token" || ok "the report has no token"
  expect_output "the tests still ran beside the finding" "[0-9]+ tests? passed" "$out"
  out="$(bash tools/check.sh --if-changed 2>&1)"; status=$?
  expect_status "--if-changed repeats the failure while nothing changed" 1 "$status" "$out"
  expect_output "and says so" "nothing changed since the last failing run" "$out"
  # An approved false positive: the fingerprints in .gitleaksignore (part of the check's fingerprint).
  sed -n 's/.*"Fingerprint"[[:space:]]*:[[:space:]]*"\(.*\)".*/\1/p' .godot/godot-director/gitleaks.json > .gitleaksignore
  out="$(bash tools/check.sh --if-changed 2>&1)"; status=$?
  expect_status "findings listed in .gitleaksignore pass, and --if-changed notices the file" 0 "$status" "$out"
  expect_output "with the scan said" "check: secrets: no credentials found" "$out"
  rm -f .gitleaksignore

  # The pre-commit hook: the staged scan runs on every commit, whatever is staged.
  mkdir -p notes && printf '# Upload\n\nstore_token = %s\n' "$tok_note" > notes/upload.md
  git add notes/upload.md
  out="$(git_q commit -qm "a note with a token" 2>&1)"; status=$?
  expect_status "the hook blocks a staged Markdown file with a token (real gitleaks)" 1 "$status" "$out"
  expect_output "it scanned a commit with no code staged" "scanning staged changes for secrets" "$out"
  expect_output "names the file and line" "found in: notes/upload\.md:3 \(" "$out"
  expect_output "says the commit is blocked" "commit blocked" "$out"
  expect_no_output "doesn't run the project check for a Markdown file" "running the project check" "$out"
  expect_no_output "doesn't print the token" "$tok_note" "$out"
  grep -q "$tok_note" .godot/godot-director/gitleaks-staged.json && bad "the staged report has no token" || ok "the staged report has no token"
  git reset -q HEAD -- notes/upload.md; rm -f notes/upload.md notes_upload.md
  git add scripts/secret_config.gd data/store.cfg
  out="$(git_q commit -qm "a script with a token" 2>&1)"; status=$?
  expect_status "the hook blocks a staged script with a token (real gitleaks)" 1 "$status" "$out"
  expect_no_output "and doesn't print it" "$tok_script" "$out"
  git reset -q HEAD -- scripts/secret_config.gd data/store.cfg
fi

}

l_secrets_c() {
lane_game warm
gitleaks_prelude
sg="$work/secrets-game"
cp -R "$game" "$sg" && rm -rf "$sg/clones"
cd "$sg" || exit 1
git add -A && { git_q commit -qm "state for the secrets tests" >/dev/null 2>&1 || true; }
cp tools/check.cfg "$work/saved-check-cfg-gl"
# The hook with a stand-in gitleaks: it names each finding as file:line (rule), blocks one that can't scan
# (8.19.0) without calling it a finding, and passes when the scan finds nothing.
rm -f scripts/secret_config.gd data/store.cfg notes_upload.md
mkdir -p notes && printf '# Plain\n' > notes/plain.md && git add notes/plain.md
out="$(export PATH="$_fake_gl:$PATH" FAKE_GL_FINDING=notes/plain.md; git_q commit -qm "stand-in finding" 2>&1)"; status=$?
expect_status "the hook blocks a commit the scan reports (stand-in)" 1 "$status" "$out"
expect_output "and names the finding as file:line (rule)" "found in: notes/plain\.md:7 \(selftest-rule\)" "$out"
out="$(export PATH="$_fake_gl:$PATH" FAKE_GL_VERSION=8.19.0 FAKE_GL_ERROR="flag accessed but not defined: source"; git_q commit -qm "stand-in cannot scan" 2>&1)"; status=$?
expect_status "the hook blocks a commit when gitleaks can't scan (stand-in 8.19.0)" 1 "$status" "$out"
expect_output "and says it couldn't scan" "couldn't scan the staged changes" "$out"
expect_no_output "and doesn't call it a finding" "found in:" "$out"
out="$(export PATH="$_fake_gl:$PATH"; git_q commit -qm "stand-in clean" 2>&1)"; status=$?
expect_status "the hook passes a commit the scan finds nothing in (stand-in)" 0 "$status" "$out"
expect_output "and says it scanned" "pre-commit: scanning staged changes for secrets" "$out"
if [ "$_no_gl_ok" -eq 1 ]; then
  printf '# Plain again\n' > notes/plain2.md && git add notes/plain2.md
  out="$(export PATH="$_no_gl_path"; git_q commit -qm "without gitleaks" 2>&1)"; status=$?
  expect_status "the hook lets a commit through without gitleaks on PATH" 0 "$status" "$out"
  expect_output "and prints the note that names the install" "pre-commit: note: gitleaks isn't installed, so this commit isn't scanned for secrets; install it from https://github.com/gitleaks/gitleaks#installing" "$out"
fi

if [ "$_gl_ok" -eq 1 ]; then
  # A clean game passes, with Godot's gitignored export credentials in .godot/ (a password and a key,
  # assembled here): the seed's allowlist keeps them from failing the check, and without it they do.
  _hex='0123456789abcdef'
  gen_token; _pw="${_tok#ghp_}"; _pw="${_pw:0:20}"; _key=""
  for ((_i = 0; _i < 64; _i++)); do _key="$_key${_hex:$((RANDOM % 16)):1}"; done
  mkdir -p .godot
  printf '[preset.0.options]\n\nscript_encryption_key="%s"\nkeystore/release_user="upload"\nkeystore/release_password="%s"\n' "$_key" "$_pw" > .godot/export_credentials.cfg
  out="$(bash tools/check.sh 2>&1)"; status=$?
  expect_status "a clean game passes the check with export credentials in .godot/" 0 "$status" "$out"
  expect_output "having scanned" "check: secrets: no credentials found \(gitleaks " "$out"
  mv .gitleaks.toml "$work/saved-gitleaks.toml"
  gitleaks dir --redact --report-path="$work/no-allowlist.json" . >/dev/null 2>&1; status=$?
  expect_status "without the seed's allowlist gitleaks flags the same .godot/ file" 1 "$status"
  grep -q '"File": "\.godot/export_credentials\.cfg"' "$work/no-allowlist.json" && ok "and it is the export credentials" || bad "and it is the export credentials" "$(grep '"File"' "$work/no-allowlist.json")"
  mv "$work/saved-gitleaks.toml" .gitleaks.toml
  rm -f .godot/export_credentials.cfg
  # Godot's own strings and files: uid:// values, .import files, .gd.uid files, the cache's paths with
  # their hashes. Generated here so that no fixed value sits in this file.
  _uid_fx="$work/uid-fixture"; mkdir -p "$_uid_fx/scenes" "$_uid_fx/assets" "$_uid_fx/scripts" "$_uid_fx/.godot/imported"
  cp "$src/project/.gitleaks.toml" "$_uid_fx/.gitleaks.toml"
  _b34='abcdefghijklmnopqrstuvwxy012345678'
  _uid_a="uid://"; _uid_b="uid://"; _md5=""
  for ((_i = 0; _i < 13; _i++)); do _uid_a="$_uid_a${_b34:$((RANDOM % 34)):1}"; _uid_b="$_uid_b${_b34:$((RANDOM % 34)):1}"; done
  for ((_i = 0; _i < 32; _i++)); do _md5="$_md5${_hex:$((RANDOM % 16)):1}"; done
  printf '[gd_scene load_steps=2 format=3 uid="%s"]\n\n[ext_resource type="Texture2D" uid="%s" path="res://assets/icon.svg" id="1_abcde"]\n\n[node name="Main" type="Control"]\n' "$_uid_a" "$_uid_b" > "$_uid_fx/scenes/main.tscn"
  printf '[remap]\n\nimporter="texture"\ntype="CompressedTexture2D"\nuid="%s"\npath="res://.godot/imported/icon.svg-%s.ctex"\n\n[deps]\n\nsource_file="res://assets/icon.svg"\ndest_files=["res://.godot/imported/icon.svg-%s.ctex"]\n\n[params]\n\ncompress/mode=0\n' "$_uid_b" "$_md5" "$_md5" > "$_uid_fx/assets/icon.svg.import"
  printf '%s\n' "$_uid_a" > "$_uid_fx/scripts/main.gd.uid"
  printf '[remap]\n\nuid="%s"\npath="res://.godot/imported/icon.svg-%s.ctex"\nmd5="%s"\n' "$_uid_b" "$_md5" "$_md5" > "$_uid_fx/.godot/imported/icon.svg-$_md5.md5"
  out="$(cd "$_uid_fx" && gitleaks dir --redact --report-path=report.json . 2>&1)"; status=$?
  expect_status "gitleaks finds nothing in Godot's uid:// strings, .import files and .godot/ cache" 0 "$status" "$out"
  # A clean commit with the hook.
  printf '# Plain three\n' > notes/plain3.md && git add notes/plain3.md
  out="$(git_q commit -qm "a clean note" 2>&1)"; status=$?
  expect_status "the hook passes a clean commit (real gitleaks)" 0 "$status" "$out"
  expect_output "after scanning it" "scanning staged changes for secrets" "$out"
else
  echo "  skip  the real-gitleaks cases (gitleaks isn't installed, or is below 8.18.0, or is 8.19.0, which can't scan)"
fi
}

l_prototype() {
game="$work/hook-game"; mkdir -p "$game/.claude" && cp -R "$src/framework/.claude/hooks" "$game/.claude/hooks" && cd "$game" || exit 1
gitleaks_prelude
# --- prototypes -----------------------------------------------------------------------------------
echo "prototype"
# tools/prototype.sh on a throwaway repository with an origin: start stops while origin/main is ahead, creates the
# worktree beside the game, the branch from main with no upstream, the saved Godot path and the committed
# PROTOTYPE.md, and refuses an existing name or an invalid one. Only a prototype (a linked worktree on a proto/
# branch with PROTOTYPE.md at its root) skips the check: the pre-commit hook still blocks a staged secret there
# and a commit without gitleaks (which is optional everywhere else), and runs the check everywhere else, the Stop
# hook likewise, and the pre-push hook refuses a proto/ branch. harvest prints what the harvest reads and changes
# nothing; remove never forces and keeps the branch. The stub check always fails, so a commit that goes through
# shows the check was skipped; the stand-in Godot only prints a version. A token is assembled at run time, never
# kept in a tracked file.
_pg="$work/godot-proto"; printf '#!/usr/bin/env bash\necho 4.7.2.stable.official.abcdef\n' > "$_pg"; chmod +x "$_pg"
_pp_path="$_fake_gl:$PATH"   # gitleaks on PATH: the stand-in, which scans clean
_pn_ok="$_no_gl_ok"; PATH="$_no_gl_path" command -v dirname >/dev/null 2>&1 || _pn_ok=0
_proto_repo() { # _proto_repo <folder> <origin>: a game with the prototype tools, a failing stub check and an origin
  new_repo "$1" >/dev/null 2>&1
  mkdir -p "$1/tools" "$1/.githooks"
  cp "$src/framework/tools/prototype.sh" "$src/framework/tools/setup-clone.sh" "$1/tools/"
  cp "$src/framework/.githooks/pre-commit" "$src/framework/.githooks/pre-push" "$1/.githooks/"
  printf '#!/usr/bin/env bash\necho "stub check: fails"\nexit 1\n' > "$1/tools/check.sh"
  printf 'config_version=5\n' > "$1/project.godot"
  printf '# Tasks\n\n**Next IDs:** T1 · B1 · R1\n' > "$1/TASKS.md"
  printf '.godot/\n/tools/godot_bin.local\n' > "$1/.gitignore"
  printf '%s\n' "$_pg" > "$1/tools/godot_bin.local"
  git init -q --bare "$2"
  (cd "$1" && git config user.name selftest && git config user.email selftest@localhost && git branch -M main \
    && git config branch.autoSetupMerge always \
    && git add -A && git commit -qm "tools and a stub check" && git remote add origin "$2" \
    && git push -q origin main && PATH="$_pp_path" bash tools/setup-clone.sh) >/dev/null 2>&1
}
_pa="$work/proto-app"; _pw="$work/proto-app-proto-quick-add"; _po="$work/proto-origin.git"
_proto_repo "$_pa" "$_po"
proto() { (cd "$_pa" && PATH="$_pp_path" bash tools/prototype.sh "$@" 2>&1); }
commit_in() { (cd "$1" && PATH="$2" git commit -qm "$3" 2>&1); }   # commit_in <folder> <PATH> <message>
_pa_none() { [ ! -e "$_pw" ] && [ -z "$(git -C "$_pa" for-each-ref refs/heads/proto/)" ]; }   # no prototype yet

# setup-clone installs both hooks, also when it finds no Godot (exit 3): they fail closed. An existing hook that
# isn't Godot Director's is left alone (exit 4) and the other one is installed.
_ng="$work/nogodot-clone"; new_repo "$_ng" >/dev/null 2>&1 && mkdir -p "$_ng/tools" "$_ng/.githooks" \
  && cp "$src/framework/tools/setup-clone.sh" "$_ng/tools/" && cp "$src/framework/.githooks/pre-commit" "$src/framework/.githooks/pre-push" "$_ng/.githooks/"
out="$(cd "$_ng" && bash tools/setup-clone.sh "$work/no-such-godot" 2>&1)"; status=$?
expect_status "setup-clone exits 3 when it finds no Godot" 3 "$status" "$out"
grep -qs "Godot Director" "$_ng/.git/hooks/pre-commit" && grep -qs "Godot Director" "$_ng/.git/hooks/pre-push" \
  && ok "and still installs the pre-commit and pre-push hooks, which fail closed" || bad "setup-clone without Godot installs no hooks" "$out"
grep -qs '\.githooks/pre-push' "$_ng/.git/hooks/pre-push" && ok "the pre-push shim runs the committed hook" || bad "the pre-push shim runs the committed hook"
out="$(cd "$_ng" && bash tools/setup-clone.sh --skip-hook "$work/no-such-godot" 2>&1)"; status=$?
expect_status "setup-clone --skip-hook with no Godot still exits 3" 3 "$status" "$out"
_nh="$work/foreign-hook-clone"; new_repo "$_nh" >/dev/null 2>&1 && mkdir -p "$_nh/tools" "$_nh/.githooks" \
  && cp "$src/framework/tools/setup-clone.sh" "$_nh/tools/" && cp "$src/framework/.githooks/pre-commit" "$src/framework/.githooks/pre-push" "$_nh/.githooks/"
printf '#!/bin/sh\n# somebody else'"'"'s hook\nexit 0\n' > "$_nh/.git/hooks/pre-push"
# What to add to a pre-push hook that is somebody else's: Git LFS's reads the pushed refs on stdin, and only one
# hook can, so ours is given a copy.
_snip=$'refs="$(cat)"; printf \'%s\\n\' "$refs" | bash .githooks/pre-push "$@" || exit 1'
out="$(cd "$_nh" && bash tools/setup-clone.sh "$_pg" 2>&1)"; status=$?
expect_status "setup-clone exits 4 when a pre-push hook that doesn't run ours exists" 4 "$status" "$out"
expect_output "and says it doesn't run .githooks/pre-push" "pre-push already exists and doesn't run \.githooks/pre-push" "$out"
printf '%s' "$out" | grep -qF -- "Add this to it: $_snip" && ok "and gives the stdin-safe line to add" || bad "setup-clone doesn't give the stdin-safe pre-push line" "$out"
grep -q "somebody else" "$_nh/.git/hooks/pre-push" && grep -qs "Godot Director" "$_nh/.git/hooks/pre-commit" \
  && ok "and leaves that hook as it was, installing the pre-commit hook" || bad "setup-clone changed a pre-push hook that isn't Godot Director's, or didn't install the pre-commit hook"
# A hook that already chains ours (found by its .githooks/ path, not by who wrote it) is left alone, and exit 0.
cat > "$_nh/.git/hooks/pre-push" <<'HOOK'
#!/bin/sh
# somebody else's hook, which runs ours
refs="$(cat)"; printf '%s\n' "$refs" | bash .githooks/pre-push "$@" || exit 1
printf '%s\n' "$refs" | cat >/dev/null
exit 0
HOOK
out="$(cd "$_nh" && bash tools/setup-clone.sh "$_pg" 2>&1)"; status=$?
expect_status "setup-clone exits 0 when a pre-push hook of somebody else's already runs ours" 0 "$status" "$out"
expect_output "and says it left that hook as it is" "pre-push already runs \.githooks/pre-push; left as it is" "$out"
grep -q "somebody else's hook, which runs ours" "$_nh/.git/hooks/pre-push" && ok "and that hook is as it was" || bad "setup-clone changed a hook that already runs ours"

out="$(proto list)"
expect_output "list says so when there are no prototypes" "^prototype: no prototypes \(no proto/ branches\)$" "$out"

# A prototype's only gates are its hooks and gitleaks, so start refuses, creating nothing, without them.
_pa_hooks="$(git -C "$_pa" rev-parse --git-path hooks)"
[ "${_pa_hooks#/}" = "$_pa_hooks" ] && [ "${_pa_hooks#?:}" = "$_pa_hooks" ] && _pa_hooks="$_pa/$_pa_hooks"
mv "$_pa_hooks/pre-push" "$work/pre-push.saved"
out="$(proto start quick-add)"; status=$?
{ [ "$status" -eq 1 ] && printf '%s' "$out" | grep -q "pre-push is missing: run bash tools/setup-clone.sh here, which installs it" && _pa_none; } \
  && ok "start refuses, creating nothing, while this clone has no pre-push hook" || bad "start refuses while this clone has no pre-push hook (exit $status)" "$out"
mv "$work/pre-push.saved" "$_pa_hooks/pre-push"
# A hook that is somebody else's must run ours, whoever wrote it, found by the .githooks/ path in it: one that doesn't
# is refused with the line to add (the stdin-safe one for pre-push), one that chains ours passes and does its job.
_pf="$work/proto-foreign"; _proto_repo "$_pf" "$work/proto-foreign-origin.git"
foreign() { (cd "$_pf" && PATH="$_pp_path" bash tools/prototype.sh start "$1" 2>&1); }
printf '#!/bin/sh\n# somebody else'"'"'s hook\nexit 0\n' > "$_pf/.git/hooks/pre-push"
out="$(foreign chained)"; status=$?
{ [ "$status" -eq 1 ] && printf '%s' "$out" | grep -q "pre-push doesn't run \.githooks/pre-push: add this to it: " && printf '%s' "$out" | grep -qF -- "$_snip" \
  && [ ! -e "$work/proto-foreign-proto-chained" ]; } \
  && ok "start refuses, creating nothing, when the pre-push hook is somebody else's and doesn't run ours, and says what to add" \
  || bad "start refuses a foreign pre-push hook that doesn't run ours (exit $status)" "$out"
cat > "$_pf/.git/hooks/pre-push" <<'HOOK'
#!/bin/sh
# somebody else's hook, which runs ours
refs="$(cat)"; printf '%s\n' "$refs" | bash .githooks/pre-push "$@" || exit 1
printf '%s\n' "$refs" | cat >/dev/null
exit 0
HOOK
chmod +x "$_pf/.git/hooks/pre-push"
out="$(foreign chained)"; status=$?
expect_status "start accepts a pre-push hook of somebody else's that runs ours" 0 "$status" "$out"
expect_output "and setup-clone leaves that hook as it is" "pre-push already runs \.githooks/pre-push; left as it is" "$out"
out="$(cd "$_pf" && PATH="$_pp_path" git push -q origin proto/chained 2>&1)"; status=$?
{ [ "$status" -ne 0 ] && printf '%s' "$out" | grep -q "a prototype is never pushed; push blocked"; } \
  && ok "and the push of the prototype is refused through that hook, which passes the refs on" || bad "the chained pre-push hook doesn't refuse a proto/ push (exit $status)" "$out"
# core.hooksPath on another hook manager's folder, relative to the repository top: its hooks have to run ours too.
_ph="$work/proto-hookspath"; _proto_repo "$_ph" "$work/proto-hookspath-origin.git"
mkdir -p "$_ph/hooks-x"; printf '#!/bin/sh\nexit 0\n' > "$_ph/hooks-x/pre-commit"; printf '#!/bin/sh\nexit 0\n' > "$_ph/hooks-x/pre-push"
chmod +x "$_ph/hooks-x/pre-commit" "$_ph/hooks-x/pre-push"
git -C "$_ph" config core.hooksPath hooks-x
out="$(cd "$_ph" && PATH="$_pp_path" bash tools/prototype.sh start other 2>&1)"; status=$?
{ [ "$status" -eq 1 ] && printf '%s' "$out" | grep -q "core.hooksPath=hooks-x" && printf '%s' "$out" | grep -qF "hooks-x/pre-commit doesn't run .githooks/pre-commit: add this to it (create the file if it is missing): bash .githooks/pre-commit || exit 1" \
  && printf '%s' "$out" | grep -qF -- "$_snip" && [ ! -e "$work/proto-hookspath-proto-other" ]; } \
  && ok "start refuses, creating nothing, when the hooks in core.hooksPath don't run ours, and says what to add to each" \
  || bad "start refuses hooks in core.hooksPath that don't run ours (exit $status)" "$out"
out="$(cd "$_ph" && PATH="$_pp_path" bash tools/setup-clone.sh "$_pg" 2>&1)"; status=$?
expect_status "setup-clone exits 4 for them, and says the same" 4 "$status" "$out"
expect_output "naming the hook folder and the hooks that don't" "core\.hooksPath=hooks-x \(e\.g\. husky\), and these hooks there don't run Godot Director's \.githooks/ ones: pre-commit pre-push" "$out"
printf '%s' "$out" | grep -qF -- "Add this to hooks-x/pre-push (create the file if it is missing): $_snip" && ok "and the stdin-safe line for its pre-push" || bad "setup-clone doesn't give the stdin-safe line for a core.hooksPath pre-push" "$out"
printf '#!/bin/sh\nbash .githooks/pre-commit || exit 1\n' > "$_ph/hooks-x/pre-commit"
cat > "$_ph/hooks-x/pre-push" <<'HOOK'
#!/bin/sh
refs="$(cat)"; printf '%s\n' "$refs" | bash .githooks/pre-push "$@" || exit 1
exit 0
HOOK
(cd "$_ph" && git add hooks-x && PATH="$_pp_path" git commit -qm "hooks of the other manager") >/dev/null 2>&1
out="$(cd "$_ph" && PATH="$_pp_path" bash tools/setup-clone.sh "$_pg" 2>&1)"; status=$?
expect_status "setup-clone exits 0 once core.hooksPath's hooks run ours" 0 "$status" "$out"
out="$(cd "$_ph" && PATH="$_pp_path" bash tools/prototype.sh start other 2>&1)"; status=$?
expect_status "start accepts them, and the worktree commits its notes through them" 0 "$status" "$out"
[ "$(git -C "$_ph" rev-list --count main..proto/other 2>/dev/null)" = 1 ] && ok "the notes are committed there" || bad "the notes aren't committed in the core.hooksPath prototype" "$out"
git -C "$_ph" config --unset core.hooksPath
if [ "$_pn_ok" -eq 1 ]; then
  out="$(cd "$_pa" && PATH="$_no_gl_path" bash tools/prototype.sh start quick-add 2>&1)"; status=$?
  { [ "$status" -eq 1 ] && printf '%s' "$out" | grep -q "gitleaks isn't on PATH, and a prototype's commits have no other secrets gate (elsewhere it is optional)" && _pa_none; } \
    && ok "start refuses, creating nothing, without gitleaks, which is optional everywhere else" || bad "start refuses without gitleaks (exit $status)" "$out"
else
  echo "  skip  start without gitleaks (git, bash or dirname shares a folder with gitleaks on this machine)"
fi
_pm="$work/proto-old-main"; _proto_repo "$_pm" "$work/proto-old-origin.git"
(cd "$_pm" && git rm -q .githooks/pre-push && PATH="$_pp_path" git commit -qm "a main from before the pre-push hook") >/dev/null 2>&1
out="$(cd "$_pm" && PATH="$_pp_path" bash tools/prototype.sh start quick-add 2>&1)"; status=$?
{ [ "$status" -eq 1 ] && printf '%s' "$out" | grep -q "main has no committed .githooks/pre-push" && [ ! -e "$work/proto-old-main-proto-quick-add" ]; } \
  && ok "start refuses, creating nothing, when main has no committed pre-push hook" || bad "start refuses when main has no committed pre-push hook (exit $status)" "$out"

# origin/main ahead of main (as last fetched): start creates nothing and says how to go on.
_pa_ahead="$(cd "$_pa" && git commit-tree -p main -m "a commit only origin has" "main^{tree}")"
git -C "$_pa" update-ref refs/remotes/origin/main "$_pa_ahead"
out="$(proto start quick-add)"; status=$?
expect_status "start stops when origin/main is ahead of main (exit 5)" 5 "$status" "$out"
expect_output "and offers to bring main up to date or to start as it is" "git pull --ff-only.*start quick-add --as-is" "$out"
[ ! -e "$_pw" ] && ! git -C "$_pa" show-ref --verify --quiet refs/heads/proto/quick-add \
  && ok "and creates no branch and no worktree" || bad "start created a prototype while origin/main was ahead"
out="$(proto start quick-add --as-is)"; status=$?
git -C "$_pa" update-ref refs/remotes/origin/main main
expect_status "start --as-is creates a prototype from main as it is" 0 "$status" "$out"
[ -d "$_pw" ] && [ "$(git -C "$_pw" symbolic-ref --short HEAD 2>/dev/null)" = "proto/quick-add" ] \
  && ok "start creates the worktree beside the game, named after it, on the new branch proto/quick-add" \
  || bad "start creates the worktree beside the game, named after it, on the new branch proto/quick-add" "$out"
[ "$(git -C "$_pa" merge-base main proto/quick-add 2>/dev/null)" = "$(git -C "$_pa" rev-parse main)" ] \
  && ok "the prototype's branch starts from local main" || bad "the prototype's branch starts from local main"
[ -z "$(git -C "$_pa" config --get branch.proto/quick-add.merge)" ] \
  && ok "the prototype's branch has no upstream, even with branch.autoSetupMerge = always" \
  || bad "the prototype's branch has an upstream: $(git -C "$_pa" config --get branch.proto/quick-add.merge)"
[ "$(head -n 1 "$_pw/tools/godot_bin.local" 2>/dev/null)" = "$_pg" ] \
  && ok "start copies this clone's saved Godot path to the worktree, which gitignores it" || bad "start copies the saved Godot path to the worktree" "$out"
expect_output "start runs setup-clone in the worktree, which finds Godot from it" "^setup: Godot 4\.7" "$out"
expect_output "and installs the pre-commit hook" "^setup: pre-commit hook installed" "$out"
expect_output "and the pre-push hook" "^setup: pre-push hook installed" "$out"
grep -q "^## What we're trying$" "$_pw/PROTOTYPE.md" && grep -q '^## How it felt$' "$_pw/PROTOTYPE.md" \
  && grep -q '^## What to keep$' "$_pw/PROTOTYPE.md" \
  && grep -qF 'A session in a checkout that `bash tools/prototype.sh here` calls a prototype (a linked worktree on a `proto/` branch with this file at its root) is a prototype session: read `.godot-director/procedures/prototype.md` › In a prototype session before any work.' "$_pw/PROTOTYPE.md" \
  && [ -z "$(git -C "$_pw" status --porcelain)" ] && [ "$(git -C "$_pa" rev-list --count main..proto/quick-add)" = 1 ] \
  && ok "start writes PROTOTYPE.md from its template (what we're trying, how it felt, what to keep) and commits it" \
  || bad "start writes PROTOTYPE.md from its template and commits it" "$(cat "$_pw/PROTOTYPE.md" 2>&1)"

out="$(proto start quick-add)"; status=$?
expect_status "start refuses a name whose branch exists" 1 "$status" "$out"
expect_output "and says the branch exists" "the branch proto/quick-add already exists" "$out"
mkdir -p "$work/proto-app-proto-taken"
out="$(proto start taken)"; status=$?
expect_status "start refuses a name whose folder exists" 1 "$status" "$out"
expect_output "and says the folder exists" "the folder .*proto-app-proto-taken already exists" "$out"
_proto_bad=""
for _pn in Quick quick_add -x x- a/b .. 'two words' list harvest remove here ''; do
  out="$(proto start "$_pn")"; status=$?
  { [ "$status" -eq 1 ] && printf '%s' "$out" | grep -q "isn't a prototype name"; } || _proto_bad="$_proto_bad '$_pn'"
done
[ -z "$_proto_bad" ] && ok "start refuses an invalid name: capitals, an underscore, a dash at either end, a slash, dots, a space, a command word, none" \
  || bad "start doesn't refuse these names:$_proto_bad"
[ "$(git -C "$_pa" for-each-ref refs/heads/proto/ | wc -l | tr -d ' ')" = 1 ] && [ "$(git -C "$_pa" worktree list | wc -l | tr -d ' ')" = 2 ] \
  && ok "a refused start creates no branch and no worktree" || bad "a refused start creates no branch and no worktree" "$(git -C "$_pa" worktree list)"
out="$(cd "$_pw" && PATH="$_pp_path" bash tools/prototype.sh start other 2>&1)"; status=$?
expect_status "start refuses to run in a prototype session" 1 "$status" "$out"
out="$(cd "$_pw" && bash tools/prototype.sh here 2>&1)"; status=$?
expect_status "here: the worktree is a prototype" 0 "$status" "$out"
out="$(cd "$_pa" && bash tools/prototype.sh here 2>&1)"; status=$?
expect_status "here: the main checkout isn't" 1 "$status" "$out"
out="$(proto list)"
expect_output "list shows the prototype, its worktree and its commits since main" "^proto/quick-add · .*proto-app-proto-quick-add · 1 commit\(s\) since main$" "$out"

# The pre-commit hook in the prototype: no check, but the staged secrets scan, which needs gitleaks there.
(cd "$_pw" && printf 'extends Node\nvar tried: int = 1\n' > tried.gd && git add tried.gd)
out="$(commit_in "$_pw" "$_pp_path" "proto: try it")"; status=$?
expect_status "pre-commit lets a source commit through in a prototype while the check fails" 0 "$status" "$out"
expect_output "and says the check is skipped in a prototype" "this checkout is a prototype, so the project check is skipped" "$out"
expect_no_output "and doesn't run the check there" "running the project check|stub check" "$out"
(cd "$_pw" && printf 'var more: int = 2\n' >> tried.gd && git add tried.gd)
out="$(cd "$_pw" && PATH="$_pp_path" FAKE_GL_FINDING=tried.gd git commit -qm "proto: a secret" 2>&1)"; status=$?
expect_status "pre-commit still blocks a staged secret in a prototype (stand-in)" 1 "$status" "$out"
expect_output "and names the finding in the prototype (stand-in)" "found in: tried\.gd:7 \(selftest-rule\)" "$out"
expect_output "and tells the agent to ask the human in the main session about a false positive" "ask the human in the main session: allowlisting is theirs to decide" "$out"
expect_no_output "and not to add a fingerprint to .gitleaksignore" "Fingerprint to \.gitleaksignore" "$out"
(cd "$_pa" && printf 'a line\n' >> README.md && git add README.md)
out="$(cd "$_pa" && PATH="$_pp_path" FAKE_GL_FINDING=README.md git commit -qm "docs: a secret" 2>&1)"; status=$?
expect_status "pre-commit blocks a staged secret outside a prototype too (stand-in)" 1 "$status" "$out"
expect_output "and there the message keeps the fingerprint route for the human to approve" "Fingerprint to \.gitleaksignore, record why in design/decisions\.md, and have the human approve" "$out"
(cd "$_pa" && git reset -q -- README.md && git checkout -q -- README.md)
if [ "$_pn_ok" -eq 1 ]; then
  out="$(commit_in "$_pw" "$_no_gl_path" "proto: no gitleaks")"; status=$?
  expect_status "pre-commit blocks a commit in a prototype when gitleaks is missing" 1 "$status" "$out"
  expect_output "and says the scan is the only gate there" "in a prototype the secrets scan is the only gate, so the" "$out"
else
  echo "  skip  a prototype commit without gitleaks (git, bash or dirname shares a folder with gitleaks on this machine)"
fi
(cd "$_pw" && git reset -q -- tried.gd && git checkout -q -- tried.gd)
# In a prototype, .gitleaksignore and .gitleaks.toml must be main's, on disk and staged: allowlisting needs the human.
(cd "$_pw" && printf 'var ok: int = 3\n' >> tried.gd && git add tried.gd && printf 'tried.gd:generic-api-key:1\n' > .gitleaksignore)
out="$(commit_in "$_pw" "$_pp_path" "proto: an allowlist on disk")"; status=$?
expect_status "pre-commit blocks a prototype commit while a .gitleaksignore on disk differs from main's" 1 "$status" "$out"
expect_output "and says allowlisting needs the human" "\.gitleaksignore differs from main's in this prototype; commit blocked" "$out"
(cd "$_pw" && git add .gitleaksignore)
out="$(commit_in "$_pw" "$_pp_path" "proto: an allowlist staged")"; status=$?
expect_status "pre-commit blocks a prototype commit that stages a .gitleaksignore" 1 "$status" "$out"
(cd "$_pw" && git rm -q --cached .gitleaksignore && rm -f .gitleaksignore && printf '[extend]\nuseDefault = true\n' > .gitleaks.toml)
out="$(commit_in "$_pw" "$_pp_path" "proto: rules on disk")"; status=$?
expect_status "pre-commit blocks a prototype commit while a .gitleaks.toml on disk differs from main's" 1 "$status" "$out"
rm -f "$_pw/.gitleaks.toml"
(cd "$_pw" && git reset -q -- tried.gd && git checkout -q -- tried.gd)
# An inline allow (a gitleaks:allow comment) on a staged line hides it from the scan, which is allowlisting too:
# blocked in a prototype, where the scan is the only gate, and fine in any other commit. A removed line doesn't count.
gen_token
(cd "$_pw" && printf 'extends Node\nconst TOKEN: String = "%s" # gitleaks:allow\n' "$_tok" > allowed.gd && git add allowed.gd)
out="$(commit_in "$_pw" "$_pp_path" "proto: an inline allow")"; status=$?
expect_status "pre-commit blocks a staged gitleaks:allow comment in a prototype" 1 "$status" "$out"
expect_output "and says which line it is" "a staged line has a gitleaks:allow comment; commit blocked" "$out"
expect_output "and that an inline allow needs the human, in the main session" "so it needs the human, in the main$" "$out"
expect_no_output "and doesn't print the token" "$_tok" "$out"
(cd "$_pw" && git reset -q -- allowed.gd && rm -f allowed.gd)
(cd "$_pf" && printf 'a note # gitleaks:allow\n' > allow.md && git add allow.md)
out="$(commit_in "$_pf" "$_pp_path" "docs: an inline allow outside a prototype")"; status=$?
expect_status "an inline gitleaks:allow comment is not blocked outside a prototype" 0 "$status" "$out"
(cd "$_pf" && printf 'a note\n' > allow.md && git add allow.md && PATH="$_pp_path" git commit -qm "docs: take the allow out") >/dev/null 2>&1
if [ "$_gl_ok" -eq 1 ]; then
  gen_token
  (cd "$_pw" && printf 'extends Node\nconst TOKEN: String = "%s"\n' "$_tok" > leak.gd && git add leak.gd)
  _pt_commits="$(git -C "$_pw" rev-list --count HEAD)"
  out="$(commit_in "$_pw" "$PATH" "proto: a token")"; status=$?
  expect_status "pre-commit blocks a token staged in a prototype (real gitleaks)" 1 "$status" "$out"
  expect_output "and names the file in the prototype (real gitleaks)" "found in: leak\.gd" "$out"
  expect_no_output "and doesn't print the token" "$_tok" "$out"
  [ "$(git -C "$_pw" rev-list --count HEAD)" = "$_pt_commits" ] && ok "the blocked commit in the prototype is not made" \
    || bad "the blocked commit in the prototype is not made"
  (cd "$_pw" && git reset -q -- leak.gd && rm -f leak.gd)
else
  echo "  skip  real gitleaks staged-secret test in a prototype (gitleaks not found, below 8.18.0, or 8.19.0)"
fi

# Everywhere else the check runs, and gitleaks stays optional: the prototype's worktree without PROTOTYPE.md or on a
# detached HEAD, a proto/ branch in the main checkout (with or without PROTOTYPE.md: it isn't a linked worktree),
# main, and protoish.
_proto_runs() { # _proto_runs <what> <folder>: a staged source file's commit there runs the failing check
  (cd "$2" && printf 'extends Node\n' > runs.gd && git add runs.gd)
  out="$(commit_in "$2" "$_pp_path" "feat: runs")"; status=$?
  { [ "$status" -eq 1 ] && printf '%s' "$out" | grep -q "running the project check"; } \
    && ok "pre-commit runs the check $1" || bad "pre-commit runs the check $1 (exit $status)" "$out"
  (cd "$2" && git reset -q -- runs.gd && rm -f runs.gd)
}
mv "$_pw/PROTOTYPE.md" "$work/PROTOTYPE.md.saved"
_proto_runs "in a worktree on a proto/ branch without PROTOTYPE.md" "$_pw"
mv "$work/PROTOTYPE.md.saved" "$_pw/PROTOTYPE.md"
git -C "$_pw" checkout -q --detach
_proto_runs "on a detached HEAD, in the prototype's worktree" "$_pw"
git -C "$_pw" switch -q proto/quick-add
git -C "$_pa" switch -q -c proto/fake
_proto_runs "on a proto/ branch in the main checkout" "$_pa"
printf '# Prototype: fake\n' > "$_pa/PROTOTYPE.md"
_proto_runs "on a proto/ branch in the main checkout, with a PROTOTYPE.md (not a linked worktree)" "$_pa"
rm -f "$_pa/PROTOTYPE.md"
git -C "$_pa" switch -q main && git -C "$_pa" branch -q -d proto/fake
_proto_runs "on main" "$_pa"
git -C "$_pa" switch -q -c protoish
_proto_runs "on a branch whose name only starts like one (protoish)" "$_pa"
git -C "$_pa" switch -q main
if [ "$_pn_ok" -eq 1 ]; then
  (cd "$_pa" && printf '# notes\n' > notes.md && git add notes.md)
  out="$(commit_in "$_pa" "$_no_gl_path" "docs: a note")"; status=$?
  expect_status "outside a prototype a missing gitleaks stays a note: the commit goes through" 0 "$status" "$out"
  expect_output "and the note names the install" "pre-commit: note: gitleaks isn't installed, so this commit isn't scanned for secrets; install it from https://github.com/gitleaks/gitleaks#installing" "$out"
fi

# The Stop hook runs the check when game files differ from the last commit, but not in a prototype.
_stop_in() { printf '{}' | CLAUDE_PROJECT_DIR="$1" bash "$src/framework/.claude/hooks/stop-check.sh" 2>&1; }
printf 'extends Node\n' > "$_pw/wip.gd"
out="$(_stop_in "$_pw")"; expect_status "the Stop hook doesn't run the check in a prototype" 0 $? "$out"
printf 'extends Node\n' > "$_pa/wip.gd"
out="$(_stop_in "$_pa")"; expect_status "the Stop hook runs the check on main, and blocks on a failure" 2 $? "$out"
rm -f "$_pa/wip.gd"

# The pre-push hook refuses a proto/ branch, from the prototype or to the remote, and any push that carries a
# prototype's commits under another name, and lets main through.
_push_refused() { # _push_refused <what> <folder> <refspec> <reason pattern>
  out="$(cd "$2" && PATH="$_pp_path" git push -q origin "$3" 2>&1)"; status=$?
  { [ "$status" -ne 0 ] && printf '%s' "$out" | grep -q "a prototype is never pushed; push blocked" && printf '%s' "$out" | grep -q "$4"; } \
    && ok "pre-push refuses $1" || bad "pre-push refuses $1 (exit $status)" "$out"
}
_push_refused "a proto/ branch" "$_pw" proto/quick-add "(a proto/ branch)"
_push_refused "a push to a proto/ branch on the remote" "$_pa" main:refs/heads/proto/sneak "(a proto/ branch)"
_push_refused "HEAD under another name, from the prototype" "$_pw" HEAD:refs/heads/x "carries a prototype's commits"
_push_refused "a prototype's commit by its hash" "$_pa" "$(git -C "$_pa" rev-parse proto/quick-add):refs/heads/y" "carries a prototype's commits"
_push_refused "proto/quick-add~0 under another name" "$_pa" "proto/quick-add~0:refs/heads/z" "carries a prototype's commits"
git -C "$_pa" branch from-proto proto/quick-add >/dev/null 2>&1
_push_refused "a branch made from a prototype's commit" "$_pa" from-proto "carries a prototype's commits"
(cd "$_pa" && printf '# game\n\nA note.\n' > README.md && git add README.md && PATH="$_pp_path" git commit -qm "docs: a note") >/dev/null 2>&1
out="$(cd "$_pa" && PATH="$_pp_path" git push -q origin main 2>&1)"
expect_status "pre-push lets main through" 0 $? "$out"
[ "$(git --git-dir="$_po" for-each-ref --format='%(refname)')" = "refs/heads/main" ] \
  && ok "the origin has main and nothing else" || bad "a refused push reached the origin" "$(git --git-dir="$_po" for-each-ref)"

# The files that gate a prototype's commits and pushes can't be written from a prototype session: the Edit and Write
# guard refuses them when PROTOTYPE.md is at the project root, in every spelling of the path, and lets the same paths
# through in a checkout that isn't one.
guard_write 2 "a prototype: .githooks/pre-commit" '.githooks/pre-commit' "$_pw"
guard_write 2 "a prototype: a new hook in .githooks/, absolute" "$_pw/.githooks/post-commit" "$_pw"
guard_write 2 "a prototype: ./.githooks/pre-push" './.githooks/pre-push' "$_pw"
guard_write 2 "a prototype: x/../.githooks/pre-commit" 'x/../.githooks/pre-commit' "$_pw"
guard_write 2 "a prototype: .claude/settings.json" '.claude/settings.json' "$_pw"
guard_write 2 "a prototype: .claude/hooks/guard-git.sh, absolute" "$_pw/.claude/hooks/guard-git.sh" "$_pw"
guard_write 2 "a prototype: .claude/settings.local.json" '.claude/settings.local.json' "$_pw"
guard_write 2 "a prototype: tools/prototype.sh" 'tools/prototype.sh' "$_pw"
guard_write 2 "a prototype: tools/setup-clone.sh" 'tools/setup-clone.sh' "$_pw"
guard_write 2 "a prototype: .gitleaksignore" '.gitleaksignore' "$_pw"
guard_write 2 "a prototype: .gitleaks.toml" '.gitleaks.toml' "$_pw"
guard_write 2 "a prototype: director/x is still the human's" 'director/x' "$_pw"
guard_write 0 "a prototype: scripts/x.gd" 'scripts/x.gd' "$_pw"
guard_write 0 "a prototype: tools/check.sh" 'tools/check.sh' "$_pw"
guard_write 0 "a prototype: PROTOTYPE.md, its notes" 'PROTOTYPE.md' "$_pw"
guard_write 0 "a prototype: .githooks-notes.md, a name that only starts like it" '.githooks-notes.md' "$_pw"
guard_write 0 "the main checkout: .githooks/pre-commit" '.githooks/pre-commit' "$_pa"
guard_write 0 "the main checkout: .claude/settings.json" '.claude/settings.json' "$_pa"
guard_write 0 "the main checkout: tools/prototype.sh" 'tools/prototype.sh' "$_pa"
guard_write 0 "the main checkout: .gitleaksignore" '.gitleaksignore' "$_pa"

# list and harvest name the gate files a prototype changed (committed or not), and say nothing when none differs.
out="$(proto list)"
expect_no_output "list names no gate file while none differs from main's" "gate files" "$out"
printf '# tried\n' >> "$_pw/.githooks/pre-push"
out="$(proto list)"
expect_output "list names a gate file with an uncommitted change in the prototype" "^  gate files that differ from main's: \.githooks/pre-push$" "$out"
expect_output "and still lists the prototype first" "^proto/quick-add · .*proto-app-proto-quick-add · 2 commit\(s\) since main$" "$out"

# harvest prints the prototype's commits, files, the diff command, uncommitted changes and notes, and writes nothing.
_pa_state() { git -C "$_pa" status --porcelain; git -C "$_pa" rev-parse HEAD proto/quick-add; git -C "$_pa" for-each-ref; cksum < "$_pa/TASKS.md" 2>/dev/null; }
_pa_before="$(_pa_state)"
out="$(proto harvest quick-add)"; status=$?
expect_status "harvest prints what the harvest reads" 0 "$status" "$out"
expect_output "harvest lists the prototype's commits since main" "proto: try it" "$out"
expect_output "harvest lists the files the prototype changed, with the diff command" "read the diff with: git diff main\.\.\.proto/quick-add$" "$out"
expect_output "harvest lists a changed file" "tried\.gd" "$out"
expect_output "harvest names the worktree's uncommitted changes, which the diff leaves out" "^\?\? wip\.gd$" "$out"
expect_output "harvest shows the prototype's notes" "^## How it felt$" "$out"
expect_output "harvest names the gate files that differ from main's, which only the human changes" "^--- gate files that differ from main's: .*only the human changes them" "$out"
expect_output "and lists the one the prototype changed" "^\.githooks/pre-push$" "$out"
[ "$(_pa_state)" = "$_pa_before" ] && ok "harvest writes no item, record, commit or branch without the human" \
  || bad "harvest changed the main checkout or the branches" "$(_pa_state)"
git -C "$_pw" checkout -q -- .githooks/pre-push
out="$(proto harvest nothing-here)"; expect_status "harvest refuses a prototype that doesn't exist" 1 $? "$out"

# remove: never forced, and the branch stays for the human to delete.
out="$(proto remove quick-add)"; status=$?
expect_status "remove fails on a worktree with uncommitted changes" 1 "$status" "$out"
[ -f "$_pw/wip.gd" ] && ok "and leaves the worktree and its changes in place" || bad "remove deleted a worktree with uncommitted changes"
expect_output "and says why, without forcing it" "git worktree remove failed \(above\); uncommitted changes are the usual cause.*never force it" "$out"
rm -f "$_pw/wip.gd"
out="$(proto remove quick-add)"; status=$?
expect_status "remove removes a clean worktree" 0 "$status" "$out"
[ ! -e "$_pw" ] && git -C "$_pa" show-ref --verify --quiet refs/heads/proto/quick-add \
  && ok "remove deletes the worktree's folder and keeps the branch with its commits" \
  || bad "remove deletes the worktree's folder and keeps the branch with its commits" "$out"
expect_output "remove asks the human to delete the branch, with the command" "the human runs that.*: git branch -D proto/quick-add$" "$out"
out="$(proto list)"
expect_output "list shows a prototype whose worktree is gone" "^proto/quick-add · no worktree · 2 commit\(s\) since main$" "$out"
[ -z "$(git --git-dir="$_po" for-each-ref refs/heads/proto/)" ] && [ -n "$(git --git-dir="$_po" for-each-ref refs/heads/main)" ] \
  && ok "nothing pushes a proto/ branch" || bad "a proto/ branch reached the origin" "$(git --git-dir="$_po" for-each-ref)"

# A game folder whose name has a space.
_ps="$work/proto space game"; _psw="$work/proto space game-proto-try"
_proto_repo "$_ps" "$work/proto-space-origin.git"
out="$(cd "$_ps" && PATH="$_pp_path" bash tools/prototype.sh start try 2>&1)"; status=$?
expect_status "start works in a game folder whose name has a space" 0 "$status" "$out"
out="$(cd "$_psw" && bash tools/prototype.sh here 2>&1)"
expect_status "the worktree beside it, named after it, is a prototype" 0 $? "$out"
out="$(cd "$_ps" && bash tools/prototype.sh list 2>&1)"
expect_output "list names its folder, space and all" "^proto/try · .*proto space game-proto-try · 1 commit\(s\) since main$" "$out"
out="$(cd "$_ps" && bash tools/prototype.sh harvest try 2>&1)"
expect_status "harvest works there" 0 $? "$out"
expect_no_output "and names no gate file while none differs" "gate files" "$out"
(cd "$_psw" && printf '# tried\n' >> .githooks/pre-commit && git add .githooks/pre-commit && PATH="$_pp_path" git commit -qm "proto: touch a hook") >/dev/null 2>&1
out="$(cd "$_ps" && bash tools/prototype.sh harvest try 2>&1)"
expect_output "harvest names a gate file the prototype committed" "^\.githooks/pre-commit$" "$out"
out="$(cd "$_ps" && bash tools/prototype.sh list 2>&1)"
expect_output "and so does list" "^  gate files that differ from main's: \.githooks/pre-commit$" "$out"
out="$(cd "$_ps" && bash tools/prototype.sh remove try 2>&1)"; status=$?
[ "$status" -eq 0 ] && [ ! -e "$_psw" ] && ok "remove works there" || bad "remove works in a folder whose name has a space (exit $status)" "$out"
}

capture_defs() { # the lint fixtures: write_fixtures, remove_fixtures and lint_fixtures (both capture lanes use them)
write_fixtures() {
  mkdir -p ui_fixtures
  # A HUD an autoload draws, and a scene a screen can name as an overlay.
  cat > ui_fixtures/hud.gd <<'EOF'
extends CanvasLayer
## Selftest fixture: a HUD on a CanvasLayer, owned by an autoload.


func _ready() -> void:
	layer = 5
	var label: Label = Label.new()
	label.name = "HudLabel"
	label.text = "HUD"
	label.position = Vector2(8, 8)
	add_child(label)
	label.owner = self
	label.unique_name_in_owner = true
EOF
  cat > ui_fixtures/toast.tscn <<'EOF'
[gd_scene format=3]

[node name="Toast" type="Control"]
layout_mode = 3
anchors_preset = 0

[node name="ToastLabel" type="Label" parent="."]
unique_name_in_owner = true
layout_mode = 0
offset_left = 8.0
offset_top = 40.0
offset_right = 120.0
offset_bottom = 64.0
text = "Saved"
EOF
  cp project.godot "$work/saved-project"
  awk '{ print } /^RunState=/ { print "Hud=\"*res://ui_fixtures/hud.gd\"" }' "$work/saved-project" > project.godot
  cat > ui_fixtures/hard_coded.tscn <<'EOF'
[gd_scene format=3]

[node name="HardCoded" type="Control"]
layout_mode = 3
anchors_preset = 15
anchor_right = 1.0
anchor_bottom = 1.0

[node name="Column" type="VBoxContainer" parent="."]
layout_mode = 0
offset_right = 200.0
offset_bottom = 120.0

[node name="Placed" type="Button" parent="Column"]
layout_mode = 2
offset_left = 120.0
offset_top = 40.0
text = "Placed"
EOF
  cat > tools/ui_screens.gd <<'EOF'
extends "res://tools/ui_catalog.gd"
## Selftest fixtures: one screen per lint rule, built to break it, and a clean one.


func screens() -> Array[Dictionary]:
	return [
		{"id": "clean", "title": "Clean", "setup": _clean},
		{"id": "squeezed", "title": "Squeezed label", "setup": _squeezed},
		{"id": "stretched", "title": "Stretched button", "setup": _stretched},
		{"id": "offscreen", "title": "Off-screen button", "setup": _offscreen},
		{"id": "overlap", "title": "Overlapping buttons", "setup": _overlap},
		{"id": "unreachable", "title": "Unreachable button", "setup": _unreachable},
		{"id": "nofocus", "title": "No default focus", "setup": _nofocus},
		{"id": "hardcoded", "title": "Hard-coded position", "scene": "res://ui_fixtures/hard_coded.tscn", "setup": _hardcoded},
		{"id": "pickable", "title": "3D pickable", "setup": _pickable},
		{"id": "rows", "title": "Rows built in code", "setup": _rows},
		{"id": "sheet", "title": "SubViewport page with a provider", "setup": _sheet.bind("provided")},
		{"id": "sheetnone", "title": "SubViewport page with no provider", "setup": _sheet.bind("none")},
		{"id": "sheethidden", "title": "SubViewport page whose provider has no rect", "setup": _sheet.bind("hidden")},
		{"id": "boxed", "title": "SubViewportContainer with a provider", "setup": _boxed.bind(true)},
		{"id": "boxednone", "title": "SubViewportContainer with no provider", "setup": _boxed.bind(false)},
		{"id": "withhud", "title": "With the HUD", "setup": _clean, "overlays": ["/root/Hud"]},
		{"id": "withhud2", "title": "With the HUD, again", "setup": _clean, "overlays": ["/root/Hud"]},
		{"id": "nohud", "title": "Without the HUD", "setup": _clean},
		{"id": "withtoast", "title": "With a toast scene", "setup": _clean, "overlays": ["res://ui_fixtures/toast.tscn"]},
		{"id": "specfix", "title": "Spec fixture", "setup": _spec_fixture.bind(0.0)},
		{"id": "specmoved", "title": "Spec fixture, Gear moved 10%", "setup": _spec_fixture.bind(-0.1)},
		{"id": "specdrawn", "title": "Spec fixture, Gear moved, drawn", "setup": _spec_fixture.bind(-0.1)},
	]


func _page() -> Control:
	var page: Control = Control.new()
	page.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	screen_root().add_child(page)
	return page


func _centred(page: Control, box: Container) -> Container:
	var center: CenterContainer = CenterContainer.new()
	center.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	page.add_child(center)
	center.add_child(box)
	return box


func _button(parent: Node, text: String) -> Button:
	var button: Button = Button.new()
	button.text = text
	parent.add_child(button)
	return button


func _clean() -> Node:
	var page: Control = _page()
	var box: Container = _centred(page, VBoxContainer.new())
	var label: Label = Label.new()
	label.text = "A clean screen"
	box.add_child(label)
	var small: Label = Label.new()
	small.text = "Small print, in its own label settings"
	small.label_settings = LabelSettings.new()
	small.label_settings.font_size = 8
	box.add_child(small)
	focus_default(_button(box, "Start"))
	_button(box, "Quit")
	return page


func _squeezed() -> Node:
	var page: Control = _page()
	var box: Container = _centred(page, HBoxContainer.new())
	var label: Label = Label.new()
	label.text = "Belt: Simple"
	label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	box.add_child(label)
	var equip: Button = _button(box, "Equip")
	equip.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	focus_default(equip)
	return page


func _stretched() -> Node:
	var page: Control = _page()
	var box: Container = _centred(page, HBoxContainer.new())
	var portrait: ColorRect = ColorRect.new()
	portrait.custom_minimum_size = Vector2(100, 300)
	box.add_child(portrait)
	focus_default(_button(box, "Repair"))
	return page


func _offscreen() -> Node:
	var page: Control = _page()
	var far: Button = _button(page, "Far away")
	far.position = Vector2(page.get_viewport_rect().size.x - 20, 20)
	focus_default(far)
	return page


func _overlap() -> Node:
	var page: Control = _page()
	var under: Button = _button(page, "Under")
	under.position = Vector2(100, 100)
	under.size = Vector2(120, 40)
	var over: Button = _button(page, "Over")
	over.position = Vector2(150, 110)
	over.size = Vector2(120, 40)
	focus_default(under)
	return page


func _unreachable() -> Node:
	var page: Control = _page()
	var box: Container = _centred(page, VBoxContainer.new())
	var one: Button = _button(box, "One")
	var two: Button = _button(box, "Two")
	_button(box, "Three")
	for pair: Array in [[one, two], [two, one]]:
		var from: Button = pair[0]
		var to: NodePath = from.get_path_to(pair[1] as Node)
		var stay: NodePath = from.get_path_to(from)
		from.focus_next = to
		from.focus_previous = to
		from.focus_neighbor_top = to
		from.focus_neighbor_bottom = to
		from.focus_neighbor_left = stay
		from.focus_neighbor_right = stay
	focus_default(one)
	return page


func _nofocus() -> Node:
	var page: Control = _page()
	_button(_centred(page, VBoxContainer.new()), "Start")
	return page


func _hardcoded() -> Node:
	var view: Node = open_view("res://ui_fixtures/hard_coded.tscn")
	focus_default(view)
	return view


func _pickable() -> Node:
	var world: Node3D = Node3D.new()
	var camera: Camera3D = Camera3D.new()
	camera.position = Vector3(0, 0, 5)
	world.add_child(camera)
	var area: Area3D = Area3D.new()
	area.name = "Chest"
	var shape: CollisionShape3D = CollisionShape3D.new()
	shape.shape = BoxShape3D.new()
	area.add_child(shape)
	world.add_child(area)
	return world


## Rows added at runtime, with names Godot picks; their ids must not depend on what ran before.
func _rows() -> Node:
	var page: Control = _page()
	var box: Container = _centred(page, VBoxContainer.new())
	for row: int in 3:
		var label: Label = Label.new()
		label.text = "Row %d" % row
		box.add_child(label)
	focus_default(_button(box, "Done"))
	return page


## A button of a SubViewport, with a unique name (owned by the screen's page).
func _in_viewport(page: Control, viewport: Viewport, button_name: String, x: float) -> void:
	var button: Button = Button.new()
	button.name = button_name
	button.text = "Go"
	button.position = Vector2(x, 20.0)
	button.size = Vector2(160, 40)
	viewport.add_child(button)
	button.owner = page
	button.unique_name_in_owner = true


## A page in a SubViewport (800 x 600 rendered, laid out in 400 x 300 units, as a sheet's page is) that
## the screen shows at half size in its lower right, with two buttons side by side. Mapped by their place
## on the screen, they don't leave the page, overlap or hold the focus. mode "provided" gives the
## SubViewport a provider, "hidden" a provider with no rect (the page isn't shown), "none" none.
func _sheet(mode: String) -> Node:
	var page: Control = _page()
	var flat: Button = _button(page, "Flat")
	flat.position = Vector2(20, 20)
	focus_default(flat)
	var viewport: SubViewport = SubViewport.new()
	viewport.size = Vector2i(800, 600)
	viewport.size_2d_override = Vector2i(400, 300)
	viewport.size_2d_override_stretch = true
	page.add_child(viewport)
	_in_viewport(page, viewport, "PageGo", 20.0)
	_in_viewport(page, viewport, "PageMore", 200.0)
	if mode == "provided":
		viewport.set_meta(&"godot_director_screen_rect", func(rect: Rect2) -> Rect2: return Rect2(Vector2(400, 200) + rect.position * 0.5, rect.size * 0.5))
	elif mode == "hidden":
		viewport.set_meta(&"godot_director_screen_rect", func(_rect: Rect2) -> Rect2: return Rect2())
	return page


## A SubViewportContainer at (300, 100), 200 x 100, with a button in its SubViewport; the provider maps
## the page through the container's transform.
func _boxed(provided: bool) -> Node:
	var page: Control = _page()
	focus_default(_button(page, "Flat"))
	var container: SubViewportContainer = SubViewportContainer.new()
	container.stretch = true
	container.position = Vector2(300, 100)
	container.size = Vector2(200, 100)
	page.add_child(container)
	var viewport: SubViewport = SubViewport.new()
	container.add_child(viewport)
	_in_viewport(page, viewport, "BoxGo", 10.0)
	if provided:
		viewport.set_meta(&"godot_director_screen_rect", func(rect: Rect2) -> Rect2: return container.get_global_transform_with_canvas() * rect)
	return page


## Three controls placed by their anchors alone, with unique names a screen spec can list. Moving
## Gear by shift (a fraction of the screen) is the deviation verify must find.
func _spec_fixture(shift: float) -> Node:
	var page: Control = _page()
	_placed(page, "Sheet", Panel.new(), Rect2(0.01, 0.11, 0.20, 0.70))
	_placed(page, "Gear", Panel.new(), Rect2(0.62 + shift, 0.12, 0.34, 0.60))
	var go: Button = Button.new()
	go.text = "Go"
	_placed(page, "Go", go, Rect2(0.62, 0.80, 0.18, 0.08))
	focus_default(go)
	return page


func _placed(page: Control, node_name: String, control: Control, area: Rect2) -> void:
	control.name = node_name
	page.add_child(control)
	control.owner = page
	control.unique_name_in_owner = true
	control.anchor_left = area.position.x
	control.anchor_top = area.position.y
	control.anchor_right = area.end.x
	control.anchor_bottom = area.end.y
	control.offset_left = 0.0
	control.offset_top = 0.0
	control.offset_right = 0.0
	control.offset_bottom = 0.0
EOF
}
remove_fixtures() { rm -rf ui_fixtures; [ -f "$work/saved-project" ] && cp "$work/saved-project" project.godot; }
lint_fixtures() { # lint_fixtures <how>: each broken fixture gets exactly its own rule; the clean one nothing
  local rule file found
  [ ! -s "$captures/clean@1280x720.lint.txt" ] && [ -f "$captures/clean@1280x720.lint.txt" ] \
    && ok "lint reports nothing on a clean screen ($1)" || bad "lint on the clean fixture ($1)" "$(cat "$captures/clean@1280x720.lint.txt" 2>&1)"
  for rule in squeezed-text:squeezed stretched-control:stretched off-screen:offscreen overlap:overlap unreachable:unreachable \
      no-default-focus:nofocus hard-coded-position:hardcoded; do
    file="$captures/${rule#*:}@1280x720.lint.txt"
    found="$(cut -d ' ' -f 1 "$file" 2>/dev/null | tr '\n' ' ')"
    [ "$found" = "${rule%%:*} " ] && ok "lint catches ${rule%%:*} ($1)" || bad "lint on the ${rule#*:} fixture ($1): found '$found'" "$(cat "$file" 2>&1)"
  done
}
}

l_capture_a1() {
lane_game warm
user_data_init
capture_defs
# --- screen capture (/ui-design) ----------------------------------------------------------------
echo "ui capture"
captures=design/ui/captures
# The catalogs below have views no adapter opens, and these tests are about the layout lint: keep the
# check's autoplay smoke (tools/check.cfg) off until the autoplay sections.
cp tools/check.cfg "$work/saved-check-cfg-ui"
sed -e 's/^check_in_check=.*/check_in_check=false/' "$work/saved-check-cfg-ui" > tools/check.cfg
out="$(GODOT_BIN=/nonexistent/godot bash tools/ui_capture.sh --all 2>&1)"; expect_status "capture exits 3 without Godot" 3 $? "$out"
[ ! -e "$captures" ] && ok "and writes nothing" || bad "capture without Godot wrote $captures"
out="$(bash tools/ui_capture.sh --list 2>&1)"; expect_status "lists the catalog" 0 $? "$out"
expect_output "lists each screen with its states and scene" "^shop · Shop screen · states: default, closed · opens res://scenes/shop_screen\.tscn · drawing: no · spec: no$" "$out"

# Lint fixtures: a screen built to break each rule, and a clean one. Headless, so no display needed.
cp tools/ui_screens.gd "$work/saved-catalog"
write_fixtures
out="$(bash tools/ui_capture.sh --all --no-images --size 1280x720 2>&1)"; expect_status "--no-images maps and lints the fixtures headless" 0 $? "$out"
lint_fixtures "headless"
grep -q '"id":"Chest","path":"Node3D#[0-9]*/Chest","kind":"Area3D"' "$captures/pickable@1280x720.elements.json" 2>/dev/null \
  && ok "maps a clickable 3D object through the camera" || bad "maps a clickable 3D object through the camera" "$(cat "$captures/pickable@1280x720.elements.json" 2>&1)"
[ ! -e "$captures/clean@1280x720.png" ] && ok "--no-images writes no images" || bad "--no-images writes no images"
grep -q '"id":"Label#1","stable":false,"path":"Control#[0-9]*/CenterContainer#0/VBoxContainer#0/Label#1"' "$captures/rows@1280x720.elements.json" 2>/dev/null \
  && ok "names a node Godot named by its class and place" || bad "names a node Godot named by its class and place" "$(head -n 8 "$captures/rows@1280x720.elements.json" 2>&1)"
# A SubViewport is drawn into a texture, so the map leaves its controls out unless the game gave it a
# screen-rect provider (tools/ui_lint.gd); then they are mapped where the provider puts them, a
# SubViewportContainer's page too, and no rule reads that place as the control's own.
for mapped in sheet:PageGo:820,420,160,40 sheet:PageMore:1000,420,160,40 boxed:BoxGo:620,240,320,80; do
  IFS=: read -r pg_screen pg_control pg_rect <<< "$mapped"
  grep -qE "\"id\":\"$pg_control\",\"stable\":true,[^}]*\"rect\":\[$pg_rect\]" "$captures/$pg_screen@1280x720.elements.json" 2>/dev/null \
    && ok "a SubViewport with a provider: $pg_control is mapped at its place on screen" \
    || bad "a SubViewport with a provider: $pg_control is mapped at its place on screen" "$(grep -o '"id":"[A-Za-z]*","stable":[a-z]*,[^}]*"rect":\[[0-9,]*\]' "$captures/$pg_screen@1280x720.elements.json" 2>&1)"
done
for left_out in sheetnone sheethidden boxednone; do
  if grep -q '"name":"Flat"' "$captures/$left_out@1280x720.elements.json" 2>/dev/null && ! grep -qE '"id":"(PageGo|PageMore|BoxGo)"' "$captures/$left_out@1280x720.elements.json"; then
    ok "$left_out: a SubViewport with no provider, or none with a rect, is left out of the map as before"
  else
    bad "$left_out: a SubViewport with no provider, or none with a rect, is left out of the map as before" "$(grep -o '"id":"[A-Za-z#0-9]*"' "$captures/$left_out@1280x720.elements.json" 2>&1)"
  fi
done
for lint_file in sheet sheetnone sheethidden boxed boxednone; do
  [ -f "$captures/$lint_file@1280x720.lint.txt" ] && [ ! -s "$captures/$lint_file@1280x720.lint.txt" ] \
    && ok "$lint_file: no finding, though a provided page is read in its own canvas and keeps its focus to itself" \
    || bad "$lint_file: no finding for the page" "$(cat "$captures/$lint_file@1280x720.lint.txt" 2>&1)"
done
cp "$captures/rows@1280x720.elements.json" "$work/rows-all"
out="$(bash tools/ui_capture.sh rows --no-images --size 1280x720 2>&1)"
cmp -s "$captures/rows@1280x720.elements.json" "$work/rows-all" && ok "a screen built in code maps the same alone as in --all" \
  || bad "a screen built in code maps the same alone as in --all" "$(diff "$work/rows-all" "$captures/rows@1280x720.elements.json")"

# Overlays: what an autoload draws is in the screen's shot, and is back where it was afterwards (the
# second screen with the HUD finds it again), and a scene an entry names is instanced in the shot.
out="$(bash tools/ui_capture.sh --all --no-images --size 1280x720 2>&1)"; expect_status "the HUD is moved in and put back after each capture, so --all captures every screen" 0 $? "$out"
if grep -q '"id":"HudLabel","stable":true' "$captures/withhud@1280x720.elements.json" 2>/dev/null \
    && grep -q '"id":"HudLabel","stable":true' "$captures/withhud2@1280x720.elements.json" 2>/dev/null; then
  ok "a capture shows the HUD an autoload draws, when the entry names it in overlays"
else
  bad "a capture shows the HUD an autoload draws, when the entry names it in overlays" "$(head -n 6 "$captures/withhud@1280x720.elements.json" 2>&1)"
fi
grep -q 'HudLabel' "$captures/nohud@1280x720.elements.json" 2>/dev/null && bad "a screen that doesn't name the HUD doesn't show it" \
  || ok "a screen that doesn't name the HUD doesn't show it"
grep -q '"id":"ToastLabel","stable":true' "$captures/withtoast@1280x720.elements.json" 2>/dev/null \
  && ok "an overlay scene is instanced in the screen's viewport" || bad "an overlay scene is instanced in the screen's viewport" "$(head -n 6 "$captures/withtoast@1280x720.elements.json" 2>&1)"
grep -q 'HudLabel' "$captures/nohud@1280x720.elements.json" 2>/dev/null && bad "the HUD stays out of a later screen that doesn't name it" \
  || ok "the HUD stays out of a later screen that doesn't name it"

# verify: the Layout table of the spec against the capture, headless. specfix is built as its spec
# says; specmoved has Gear 10% of the screen to the left; specdrawn is the same, with a drawing in
# which a box was drawn over Gear where the spec says it is.
mkdir -p design/ui
spec_table='| # | Element | Name | Where (x, y, w, h %) | Shows | Does | Size |
|---|---|---|---|---|---|---|
| 1 | Hero sheet | %Sheet | 1, 11, 20, 70 | - | - | fill |
| 2 | Gear list | %Gear | 62, 12, 34, 60 | - | - | fill |
| 3 | Go | %Go | 62, 80, 18, 8 | - | click | fit |'
printf '# Spec fixture\n\n## Layout (at 1280x720)\n%s\n' "$spec_table" > design/ui/specfix.md
cp design/ui/specfix.md design/ui/specmoved.md
printf '# Spec fixture\n\n## Layout (at 1280x720)\n%s\n' "$(printf '%s\n' "$spec_table" | grep -v '%Gear')" > design/ui/specdrawn.md
out="$(bash tools/ui_capture.sh specfix --verify --no-images --size 1280x720 2>&1)"; expect_status "verify: a screen built as its spec says" 0 $? "$out"
expect_output "reports no deviations" "3 elements checked, 0 deviations" "$out"
out="$(bash tools/ui_capture.sh specmoved --verify --no-images --size 1280x720 2>&1)"; expect_status "verify: a screen with one element moved 10% exits 1" 1 $? "$out"
expect_output "reports exactly one deviation" "3 elements checked, 1 deviation$" "$out"
if printf '%s\n' "$out" | grep -q '^| Gear list | %Gear | 62, 12, 34, 60 | 52, .* | moved: ' && [ "$(printf '%s\n' "$out" | grep -c '| ok |$')" -eq 2 ]; then
  ok "and it is that element, with what the spec says and what the capture shows; the other two are ok"
else
  bad "and it is that element, with what the spec says and what the capture shows; the other two are ok" "$out"
fi
printf '{"schema":1,"source":"director/ui/specdrawn.excalidraw","frames":[{"name":"specdrawn","state":"default","size":[1280,720],"boxes":[{"id":"b1","label":"Gear list","intent":"keep","rect_pct":[62,12,34,60],"overlaps":[{"n":2,"name":"Gear","iou":1}]}]}]}\n' \
  > "$captures/specdrawn.drawing.json"
out="$(bash tools/ui_capture.sh specdrawn --verify --no-images --size 1280x720 2>&1)"; expect_status "verify: a drawn box whose element moved away is a deviation" 1 $? "$out"
expect_output "and both rectangles are reported" "moved from the drawing: %Gear, box b1 \(Gear list\) was drawn at 62, 12, 34, 60 and is now at 52, " "$out"
expect_output "and an element the spec doesn't list is named" "not in the spec: %Gear " "$out"
out="$(bash tools/ui_capture.sh clean --verify --no-images --size 1280x720 2>&1)"; expect_status "verify: a screen with no spec exits 3" 3 $? "$out"
expect_output "and says where the spec goes" "no spec at design/ui/clean\.md" "$out"
out="$(bash tools/ui_capture.sh --all --verify 2>&1)"; expect_status "verify takes one screen" 1 $? "$out"

}

l_capture_a2() {
lane_game warm
user_data_init
capture_defs
captures=design/ui/captures
cp tools/check.cfg "$work/saved-check-cfg-ui"; sed -e 's/^check_in_check=.*/check_in_check=false/' "$work/saved-check-cfg-ui" > tools/check.cfg
cp tools/ui_screens.gd "$work/saved-catalog"
write_fixtures
# The lint in the check (tools/ui_capture.cfg › [lint]): a screen under enforce with a finding fails
# the check, one without passes, and with the lint off (or the keys missing) the check is unchanged.
cp tools/ui_capture.cfg "$work/saved-lint-cfg"
set_lint() { # set_lint <check_in_check> <enforce as JSON>
  sed -e "s/^check_in_check=.*/check_in_check=$1/" -e "s/^enforce=.*/enforce=$2/" "$work/saved-lint-cfg" > tools/ui_capture.cfg
}
set_lint true '["squeezed"]'
out="$(bash tools/check.sh 2>&1)"; expect_status "check_in_check with a screen under enforce fails on its lint finding" 1 $? "$out"
expect_output "and names the screen, size and rule" "GDIR-FAIL: ui lint: squeezed@1920x1080: squeezed-text element" "$out"
set_lint true '["clean"]'
out="$(bash tools/check.sh 2>&1)"; expect_status "the same lint passes for a clean screen under enforce" 0 $? "$out"
expect_output "and says what it linted" "ui lint: 1 screen linted at 1920x1080" "$out"
set_lint true '["hardcoded"]'
out="$(bash tools/check.sh 2>&1)"; expect_status "a warning (hard-coded-position) under enforce doesn't fail the check" 0 $? "$out"
set_lint true '[]'
out="$(bash tools/check.sh 2>&1)"; expect_status "enforce left empty lints nothing" 0 $? "$out"
set_lint false '["squeezed"]'
rm -f .godot/godot-director/ui_lint.log
out="$(bash tools/check.sh 2>&1)"; expect_status "with check_in_check=false the same finding doesn't fail the check" 0 $? "$out"
if ! printf '%s' "$out" | grep -q 'ui lint' && [ ! -e .godot/godot-director/ui_lint.log ]; then
  ok "and the check runs no lint: no extra Godot run, no mention of it"
else
  bad "and the check runs no lint: no extra Godot run, no mention of it" "$out"
fi
grep -v -e '^check_in_check=' -e '^enforce=' "$work/saved-lint-cfg" > tools/ui_capture.cfg
out="$(bash tools/check.sh 2>&1)"; expect_status "with the keys missing the lint reads as off" 0 $? "$out"
expect_no_output "and the check says nothing about it" "ui lint" "$out"
fp_before="$(bash tools/check.sh --fingerprint)"
set_lint false '[]'
[ "$fp_before" != "$(bash tools/check.sh --fingerprint)" ] && ok "the check's fingerprint covers tools/ui_capture.cfg" || bad "the check's fingerprint covers tools/ui_capture.cfg"
cp "$work/saved-lint-cfg" tools/ui_capture.cfg

}

l_capture_a3() {
lane_game warm
user_data_init
capture_defs
captures=design/ui/captures
cp tools/check.cfg "$work/saved-check-cfg-ui"; sed -e 's/^check_in_check=.*/check_in_check=false/' "$work/saved-check-cfg-ui" > tools/check.cfg
cp tools/ui_screens.gd "$work/saved-catalog"
write_fixtures
# A catalog with problems: each is named, the good screen is still captured, exit 1.
cat > tools/ui_screens.gd <<'EOF'
extends "res://tools/ui_catalog.gd"


func screens() -> Array[Dictionary]:
	return [
		{"id": "good", "title": "Good", "setup": _good},
		{"id": "good", "title": "Twice", "setup": _good},
		{"id": "typo", "title": "Typo", "scen": "res://scenes/shop_screen.tscn"},
		{"id": "missing", "title": "Missing", "scene": "res://nowhere.tscn"},
		{"id": "broken", "title": "Broken", "setup": _broken},
		{"id": "stuck", "title": "Stuck", "setup": _stuck},
		{"id": "after", "title": "After", "setup": _good},
		{"id": "lost", "title": "Lost overlay", "setup": _good, "overlays": ["/root/Nowhere"]},
		{"id": "badoverlay", "title": "Bad overlay", "setup": _good, "overlays": ["Hud"]},
	]


func _good() -> Node:
	return open_view("res://scenes/shop_screen.tscn")


func _broken() -> Node:
	var nothing: Node = null
	nothing.get_name()
	return null


func _stuck() -> Node:
	await tree().create_timer(600.0).timeout
	return null
EOF
cp tools/ui_capture.cfg "$work/saved-capture-cfg"
sed 's/^setup_timeout=.*/setup_timeout=2/' "$work/saved-capture-cfg" > tools/ui_capture.cfg
out="$(bash tools/ui_capture.sh --all --no-images --size 1280x720 2>&1)"; expect_status "fails when a screen fails" 1 $? "$out"
expect_output "names a duplicate id" "entry 2 \(good\): duplicate id" "$out"
expect_output "names an unknown key" "entry 3 \(typo\): unknown key 'scen'" "$out"
expect_output "names a missing scene" "entry 4 \(missing\): the scene res://nowhere\.tscn doesn't exist" "$out"
expect_output "names the screen whose setup errors" "FAIL: broken@1280x720: its setup printed errors" "$out"
head -n 1 "$captures/broken@1280x720.lint.txt" 2>/dev/null | grep -q '^error: SCRIPT ERROR' \
  && ok "puts the setup's error at the top of its lint file" || bad "puts the setup's error at the top of its lint file"
[ -f "$captures/good@1280x720.elements.json" ] && ok "goes on with the other screens" || bad "goes on with the other screens" "$out"
expect_output "names an overlay that isn't a node path or a scene" "entry 9 \(badoverlay\): overlay 'Hud' must be a node path" "$out"
expect_output "fails a screen whose overlay isn't in the scene tree" "FAIL: lost@1280x720: the overlay /root/Nowhere isn't in the scene tree" "$out"
head -n 1 "$captures/lost@1280x720.lint.txt" 2>/dev/null | grep -q "^error: the overlay /root/Nowhere" && [ -f "$captures/lost@1280x720.elements.json" ] \
  && ok "and still captures it, with the error at the top of its lint file" || bad "and still captures it, with the error at the top of its lint file"
expect_output "fails a setup that doesn't finish" "FAIL: stuck@1280x720: the setup didn't finish within 2 seconds" "$out"
grep -q "^error: the setup didn't finish" "$captures/stuck@1280x720.lint.txt" 2>/dev/null && [ -f "$captures/after@1280x720.elements.json" ] \
  && ok "writes that to its lint file and goes on" || bad "writes that to its lint file and goes on" "$out"
cp "$work/saved-capture-cfg" tools/ui_capture.cfg
out="$(bash tools/ui_capture.sh nowhere --no-images 2>&1)"; expect_output "refuses an unknown screen" "no screen 'nowhere'" "$out"
cp "$work/saved-catalog" tools/ui_screens.gd; remove_fixtures; rm -rf "$captures"

}

l_capture_b() {
lane_game warm
user_data_init
capture_defs
captures=design/ui/captures
cp tools/check.cfg "$work/saved-check-cfg-ui"; sed -e 's/^check_in_check=.*/check_in_check=false/' "$work/saved-check-cfg-ui" > tools/check.cfg
cp tools/ui_screens.gd "$work/saved-catalog"
mkdir -p design/ui
spec_table='| # | Element | Name | Where (x, y, w, h %) | Shows | Does | Size |
|---|---|---|---|---|---|---|
| 1 | Hero sheet | %Sheet | 1, 11, 20, 70 | - | - | fill |
| 2 | Gear list | %Gear | 62, 12, 34, 60 | - | - | fill |
| 3 | Go | %Go | 62, 80, 18, 8 | - | click | fit |'
printf '# Spec fixture\n\n## Layout (at 1280x720)\n%s\n' "$spec_table" > design/ui/specfix.md
cp design/ui/specfix.md design/ui/specmoved.md
printf '# Spec fixture\n\n## Layout (at 1280x720)\n%s\n' "$(printf '%s\n' "$spec_table" | grep -v '%Gear')" > design/ui/specdrawn.md
# Drawings, headless. The fixture drawing (tests/ui-drawing/) has a green box with bound text and
# click:, a blue box over an existing element, a red X over an element, an arrowed comment, a box
# inside a box, a note outside the frame and a freehand squiggle; its expected reading was worked
# out by hand. The scaled copy has the background image and everything over it moved and scaled to
# 50% (the frame stays), so only a reading measured against the image gives the same numbers.
fixtures="$src/tests/ui-drawing"
mkdir -p drawing_fixtures/captures && cp "$fixtures"/fixture* drawing_fixtures/ && cp "$fixtures/starter.expected.excalidraw" drawing_fixtures/
cp drawing_fixtures/fixture.elements.json 'drawing_fixtures/captures/hero_room@1000x500.elements.json'
cat > tools/selftest_drawings.gd <<'EOF'
extends SceneTree
## compare <actual> <expected>: the same reading, apart from where it came from.
## validate <starter> <screen> <W> <H>: the starter is valid Excalidraw (types.ts in excalidraw/excalidraw) and reads back empty.
const UiDrawing := preload("res://tools/ui_drawing.gd")
const TYPES: PackedStringArray = ["rectangle", "text", "image", "frame", "line", "arrow", "freedraw", "ellipse", "diamond"]
const FILLS: PackedStringArray = ["hachure", "cross-hatch", "solid", "zigzag"]
const STROKES: PackedStringArray = ["solid", "dashed", "dotted"]


func _initialize() -> void:
	var args: PackedStringArray = OS.get_cmdline_user_args()
	quit(_compare(args[1], args[2]) if args[0] == "compare" else _validate(args[1], args[2], Vector2(float(args[3]), float(args[4]))))


func _load(path: String) -> Variant:
	return JSON.parse_string(FileAccess.get_file_as_string(path))


func _compare(actual_path: String, expected_path: String) -> int:
	var actual: Dictionary = _load(actual_path)
	var expected: Dictionary = _load(expected_path)
	for key: String in ["source", "sha1"]:
		actual.erase(key)
		expected.erase(key)
	if actual == expected:
		print("SAME")
		return 0
	print("actual:\n" + UiDrawing.dump(actual) + "\nexpected:\n" + UiDrawing.dump(expected))
	return 1


func _is_int(value: Variant) -> bool:
	return (value is float or value is int) and floorf(float(value)) == float(value)


func _validate(path: String, screen: String, size: Vector2) -> int:
	var problems: PackedStringArray = PackedStringArray()
	var document: Variant = _load(path)
	if not (document is Dictionary):
		print("not JSON")
		return 1
	var doc: Dictionary = document
	if doc.get("type") != "excalidraw" or not _is_int(doc.get("version")) or int(doc["version"]) != 2:
		problems.append("type excalidraw, version 2")
	if not (doc.get("elements") is Array) or not (doc.get("appState") is Dictionary) or not (doc.get("files") is Dictionary):
		print("elements, appState and files are required")
		return 1
	var files: Dictionary = doc["files"]
	for key: String in files:
		var file: Dictionary = files[key]
		if str(file.get("id")) != key or file.get("mimeType") != "image/png" or not str(file.get("dataURL")).begins_with("data:image/png;base64,") or not (file.get("created") is float):
			problems.append("file " + key)
	var ids: Dictionary = {}
	var frames: Array[String] = []
	var previous: String = ""
	for item: Variant in (doc["elements"] as Array):
		var e: Dictionary = item
		var id: String = str(e.get("id", ""))
		if id.is_empty() or ids.has(id):
			problems.append("id '%s' is empty or repeated" % id)
		ids[id] = e
		if e.get("type") == "frame":
			frames.append(id)
		if not TYPES.has(str(e.get("type"))):
			problems.append(id + ": type")
		for number: String in ["x", "y", "width", "height", "angle", "strokeWidth", "roughness", "opacity", "updated"]:
			if not (e.get(number) is float):
				problems.append("%s: %s must be a number" % [id, number])
		for number: String in ["seed", "version", "versionNonce"]:
			if not _is_int(e.get(number)):
				problems.append("%s: %s must be an integer" % [id, number])
		for string: String in ["strokeColor", "backgroundColor", "index"]:
			if not (e.get(string) is String):
				problems.append("%s: %s must be a string" % [id, string])
		if not FILLS.has(str(e.get("fillStyle"))) or not STROKES.has(str(e.get("strokeStyle"))):
			problems.append(id + ": fillStyle or strokeStyle")
		if not (e.get("groupIds") is Array) or not (e.get("isDeleted") is bool) or not (e.get("locked") is bool):
			problems.append(id + ": groupIds, isDeleted or locked")
		for nullable: String in ["frameId", "roundness", "boundElements", "link"]:
			if not e.has(nullable):
				problems.append("%s: %s is missing (null is fine)" % [id, nullable])
		if str(e.get("index", "")) <= previous:
			problems.append(id + ": index must grow with the array order")
		previous = str(e.get("index", ""))
		match str(e.get("type")):
			"text":
				for string: String in ["text", "originalText"]:
					if not (e.get(string) is String):
						problems.append("%s: %s" % [id, string])
				if not (e.get("fontSize") is float) or not (e.get("fontFamily") is float) or not (e.get("lineHeight") is float) or not (e.get("autoResize") is bool):
					problems.append(id + ": fontSize, fontFamily, lineHeight or autoResize")
				if not ["left", "center", "right"].has(e.get("textAlign")) or not ["top", "middle", "bottom"].has(e.get("verticalAlign")) or not e.has("containerId"):
					problems.append(id + ": textAlign, verticalAlign or containerId")
			"image":
				if not files.has(str(e.get("fileId"))) or e.get("status") != "saved" or not (e.get("scale") is Array) or (e["scale"] as Array).size() != 2 or not e.has("crop"):
					problems.append(id + ": fileId, status, scale or crop")
			"frame":
				if not (e.get("name") is String):
					problems.append(id + ": name")
	if frames.size() != 1:
		problems.append("one frame is expected")
	else:
		var frame: Dictionary = ids[frames[0]]
		var background: Dictionary = ids.get("ddd-background", {})
		if frame.get("name") != screen or float(frame["width"]) != size.x or float(frame["height"]) != size.y:
			problems.append("the frame is named after the screen and is the size of the capture")
		if background.is_empty() or background.get("type") != "image" or background.get("locked") != true or background.get("frameId") != frames[0] \
				or float(background["width"]) != size.x or float(background["height"]) != size.y:
			problems.append("the screenshot is a locked image filling the frame")
		for id: String in ids:
			var e: Dictionary = ids[id]
			if e.get("type") != "frame" and e.get("frameId") != frames[0] and id != "ddd-legend":
				problems.append(id + ": frameId")
			if str(e.get("id")).begins_with("ddd-existing") and (e.get("locked") != false or float(e["opacity"]) != 25.0 or e.get("groupIds") != ["ddd-existing"]):
				problems.append(id + ": the existing group is unlocked (it can be dragged), at 25% opacity")
		if ids.has("ddd-legend") and (ids["ddd-legend"] as Dictionary).get("frameId") != null:
			problems.append("the legend is outside the frame")
	var read: Dictionary = UiDrawing.read_drawing(FileAccess.get_file_as_string(path), path, "", screen, path.get_base_dir().path_join("captures"))
	if read.has("error"):
		problems.append("reading it back: " + str(read["error"]))
	else:
		var back: Dictionary = ((read["drawing"] as Dictionary)["frames"] as Array)[0]
		if not (back["boxes"] as Array).is_empty() or not (back["unparsed"] as Array).is_empty() or not (back["notes"] as Array).is_empty() or not (back["removed"] as Array).is_empty():
			problems.append("saving the starter unchanged and reading it back must give no boxes, notes or unparsed entries")
	if problems.is_empty():
		print("VALID")
		return 0
	print("\n".join(problems))
	return 1
EOF
reader() { # reader <drawing> <output name>
  "$godot" --headless --path . --script tools/ui_drawing.gd -- "drawing_fixtures/$1" "drawing_fixtures/$2/hero_room.drawing.json" 2>&1
}
for variant in fixture:read fixture-scaled:moved; do
  mkdir -p "drawing_fixtures/${variant#*:}"; cp drawing_fixtures/fixture.elements.json "drawing_fixtures/${variant#*:}/hero_room@1000x500.elements.json"
  out="$(reader "${variant%%:*}.excalidraw" "${variant#*:}")"; expect_status "the reader reads ${variant%%:*}.excalidraw" 0 $? "$out"
  out="$("$godot" --headless --path . --script tools/selftest_drawings.gd -- compare "drawing_fixtures/${variant#*:}/hero_room.drawing.json" drawing_fixtures/fixture.expected.json 2>&1)"
  case "${variant%%:*}" in
    fixture) expect_output "the fixture drawing gives exactly the expected boxes, intents, parent, comment, removal, note and one unparsed entry, to 0.1%" "^SAME" "$out" ;;
    *) expect_output "the same drawing with the background image moved and scaled 50% gives the same percentages" "^SAME" "$out" ;;
  esac
done
out="$(reader fixture.excalidraw read)"; expect_output "a moved grey box that nothing else claims prints no conflict note" "^GDIR-UI: read" "$out"
case "$out" in *claimed*) bad "the fixture has no claimed element" "$out" ;; *) ok "the fixture has no claimed element" ;; esac
out="$(reader fixture-conflict.excalidraw read)"; expect_output "an element claimed by a moved grey box and a blue box is named in one note" "GDIR-UI-NOTE: hero_room: element 4 \(GearList\) is claimed by a moved grey box and a blue box named after it" "$out"
mkdir -p drawing_fixtures/nomap; out="$(reader fixture.excalidraw nomap)"; expect_output "with no element map the moved grey boxes are skipped with one note per frame" "GDIR-UI-NOTE: hero_room: no element map hero_room@1000x500.elements.json, so the moved grey boxes are ignored" "$out"
[ "$(printf '%s
' "$out" | grep -c 'no element map')" = "1" ] && ok "and it is one note" || bad "and it is one note" "$out"
out="$(reader nowhere.excalidraw read)"; expect_status "the reader refuses a missing drawing" 1 $? "$out"
printf '{ not json' > drawing_fixtures/broken.excalidraw
out="$(reader broken.excalidraw read)"; expect_status "the reader refuses invalid JSON" 1 $? "$out"; expect_output "and says so" "isn't valid JSON" "$out"
printf '{"type":"excalidraw","version":2,"elements":[],"files":{}}' > drawing_fixtures/empty.excalidraw
out="$(reader empty.excalidraw read)"; expect_status "the reader refuses a drawing with no frame" 1 $? "$out"; expect_output "and says so" "has no frame" "$out"
out="$("$godot" --headless --path . --script tools/ui_drawing.gd -- starter drawing_fixtures/fixture drawing_fixtures/hero_room.starter.excalidraw 2>&1)"
expect_status "the starter drawing is written from a capture's files" 0 $? "$out"
cmp -s drawing_fixtures/hero_room.starter.excalidraw drawing_fixtures/starter.expected.excalidraw && ok "the starter matches the hand-checked fixture (a frame named hero_room, the screenshot locked inside)" \
  || bad "the starter matches the hand-checked fixture" "$(diff drawing_fixtures/hero_room.starter.excalidraw drawing_fixtures/starter.expected.excalidraw | head -n 10)"
out="$("$godot" --headless --path . --script tools/selftest_drawings.gd -- validate drawing_fixtures/hero_room.starter.excalidraw hero_room 1000 500 2>&1)"
expect_output "the starter is valid Excalidraw, and saved unchanged it reads back with no boxes and no unparsed entries" "^VALID" "$out"
rm -rf drawing_fixtures

# The example's screens with a display: every state and size, nothing in user://, repeatable.
mkdir -p "$user_data" && : > "$work/before-capture" && sleep 1
out="$(bash tools/ui_capture.sh --all 2>&1)"; status=$?
if [ "$status" -eq 3 ]; then
  echo "  skip  capture with a display: $(printf '%s' "$out" | tail -n 1)"
else
  expect_status "captures every screen in the example's catalog" 0 "$status" "$out"
  missing=""
  for base in shop shop.closed; do
    for size in 1920x1080 2560x1080 1280x720; do
      for ext in png elements.json map.png lint.txt; do
        [ -f "$captures/$base@$size.$ext" ] || missing="$missing $base@$size.$ext"
      done
    done
  done
  [ -z "$missing" ] && ok "writes a PNG, element map, map image and lint file per screen, state and size" || bad "capture outputs missing:$missing" "$out"
  [ "$(/usr/bin/find "$captures" -name '*.starter.excalidraw' | wc -l | tr -d ' ')" = "1" ] && [ -f "$captures/shop.starter.excalidraw" ] \
    && ok "writes one starter drawing, for the default state at the default size" || bad "writes one starter drawing, for the default state at the default size" "$(ls "$captures")"
  [ "$(od -An -tu1 -j16 -N8 "$captures/shop@2560x1080.png" | tr -s ' ' | sed 's/^ //')" = "0 0 10 0 0 0 4 56" ] \
    && ok "a capture has the requested size (2560x1080)" || bad "a capture has the requested size (2560x1080)"
  [ -z "$(cat "$captures"/shop*.lint.txt)" ] && ok "the example's screens are lint-clean" || bad "the example's screens are lint-clean" "$(cat "$captures"/shop*.lint.txt)"
  out="$(bash tools/ui_capture.sh shop --state default --size 7680x4320 2>&1)"; expect_status "captures a size larger than any usual monitor (7680x4320)" 0 $? "$out"
  [ "$(od -An -tu1 -j16 -N8 "$captures/shop@7680x4320.png" | tr -s ' ' | sed 's/^ //')" = "0 0 30 0 0 0 16 224" ] \
    && ok "at that size" || bad "the 7680x4320 capture has that size"
  grep -q '"id":"Buy","stable":true,"path":"ShopScreen/Center/Layout/Buy","kind":"Button"' "$captures/shop@1920x1080.elements.json" \
    && grep -q '"schema": 1, "adapter": "godot"' "$captures/shop@1920x1080.elements.json" \
    && ok "the element map lists the unique-named controls" || bad "the element map lists the unique-named controls" "$(head -n 8 "$captures/shop@1920x1080.elements.json")"
  [ -z "$(/usr/bin/find "$user_data" -type f -newer "$work/before-capture" 2>/dev/null)" ] && ok "writes nothing in user://" \
    || bad "writes nothing in user://" "$(/usr/bin/find "$user_data" -type f -newer "$work/before-capture")"
  cp "$captures/shop@1280x720.elements.json" "$work/first-map"; cp "$captures/shop@1280x720.map.png" "$work/first-map-image"
  out="$(bash tools/ui_capture.sh shop --state default --size 1280x720 2>&1)"
  cmp -s "$captures/shop@1280x720.elements.json" "$work/first-map" && ok "a second capture gives the same element map" \
    || bad "a second capture gives the same element map" "$out"
  rm -f "$captures/shop@1280x720.map.png"
  out="$("$godot" --headless --path . --script tools/ui_overlay.gd -- map "$captures/shop@1280x720" 2>&1)"
  cmp -s "$captures/shop@1280x720.map.png" "$work/first-map-image" && ok "ui_overlay.gd redraws the same map image headless" \
    || bad "ui_overlay.gd redraws the same map image headless" "$out"
  mkdir -p drawing_fixtures/captures && cp "$captures/shop.starter.excalidraw" drawing_fixtures/ && cp "$captures/shop@1920x1080.elements.json" drawing_fixtures/captures/
  out="$("$godot" --headless --path . --script tools/selftest_drawings.gd -- validate drawing_fixtures/shop.starter.excalidraw shop 1920 1080 2>&1)"
  expect_output "a captured starter drawing is valid Excalidraw and reads back empty" "^VALID" "$out"
  rm -rf drawing_fixtures
  write_fixtures; rm -rf "$captures"
  out="$(bash tools/ui_capture.sh --all --size 1280x720 2>&1)"; expect_status "captures the lint fixtures with a display" 0 $? "$out"
  lint_fixtures "with a display"
  if cmp -s "$captures/withhud@1280x720.png" "$captures/nohud@1280x720.png"; then
    bad "the HUD an overlay names is in the image"
  elif cmp -s "$captures/withhud@1280x720.png" "$captures/withhud2@1280x720.png"; then
    ok "the HUD an overlay names is in the image, the same each time it is moved in and put back"
  else
    bad "the HUD an overlay names is in the image, the same each time it is moved in and put back"
  fi
  # verify with a drawing: the compare image holds the drawing's screenshot beside the new capture.
  mkdir -p drawing_fixtures
  "$godot" --headless --path . --script tools/ui_drawing.gd -- starter "$captures/specfix@1280x720" drawing_fixtures/specfix.excalidraw >/dev/null 2>&1
  "$godot" --headless --path . --script tools/ui_drawing.gd -- drawing_fixtures/specfix.excalidraw "$captures/specfix.drawing.json" specfix >/dev/null 2>&1
  out="$(bash tools/ui_capture.sh specfix --verify --size 1280x720 2>&1)"; expect_status "verify with a display and a drawing" 0 $? "$out"
  expect_output "it names the compare image" "compare image: design/ui/captures/specfix\.compare@1280x720\.png" "$out"
  [ "$(od -An -tu1 -j16 -N8 "$captures/specfix.compare@1280x720.png" 2>/dev/null | tr -s ' ' | sed 's/^ //')" = "0 0 10 8 0 0 2 208" ] \
    && ok "and writes it: the drawing's screenshot and the capture side by side (2568x720)" || bad "and writes the compare image: the drawing's screenshot and the capture side by side (2568x720)" "$out"
  rm -rf drawing_fixtures
  cp "$work/saved-catalog" tools/ui_screens.gd; remove_fixtures; rm -rf "$captures"
fi

rm -f tools/selftest_drawings.gd tools/selftest_drawings.gd.uid design/ui/spec*.md
}

l_autoplay() {
lane_game warm
user_data_init
# --- autoplay -----------------------------------------------------------------------------------
# The example plays itself through its adapter: the real main scene, ui actions by real input and an
# api action, screenshots and element maps, the invariants, repros and replays, and the same log
# from the same seed. The planted bugs are the spec's three: a script error in a view's button
# handler, a progress block that never clears, a view with no default focus.
echo "autoplay"
out="$(GODOT_BIN=/nonexistent/godot bash tools/autoplay.sh smoke --no-images 2>&1)"; expect_status "autoplay exits 3 without Godot" 3 $? "$out"
[ -z "$(ls -A "$runs" 2>/dev/null)" ] && ok "and writes nothing" || bad "autoplay without Godot wrote $runs"
out="$(bash tools/autoplay.sh --list 2>&1)"; expect_status "lists the scenarios" 0 $? "$out"
[ "$(printf '%s\n' "$out" | awk -F ' · ' 'NF >= 3 { printf "%s %s ", $1, $2 }')" = "smoke smoke trade_week scripted greedy_trader strategy " ] \
  && ok "with the smoke, scripted and strategy scenarios" || bad "with the smoke, scripted and strategy scenarios" "$out"
mkdir -p "$user_data" && : > "$work/before-autoplay" && sleep 1
out="$(bash tools/autoplay.sh --all --no-images 2>&1)"; expect_status "plays every scenario headless, with nothing found" 0 $? "$out"
[ "$(printf '%s\n' "$out" | grep -c ' · 0 findings · ')" = "3" ] && ok "one clean run per scenario" || bad "one clean run per scenario" "$out"
run="$(latest_run smoke-1)"
if [ -n "$run" ] && [ -f "$(ls "$run"/run-*.log 2>/dev/null | head -n 1)" ] && [ -f "$run/0000-start.elements.json" ] \
    && grep -q '"event":"screenshot","text":"0000-start.elements.json"' "$run"/run-*.jsonl \
    && grep -q '"event":"autoplay.step".*"kind":"ui","route":"%Buy"' "$run"/run-*.jsonl && grep -q '"event":"trade.buy"' "$run"/run-*.jsonl \
    && grep -qE '"event":"view.changed"|"reason":"view"' "$run"/run-*.jsonl && [ -f "$run/0003-snapshot.elements.json" ] && [ ! -f "$run/repro.json" ]; then
  ok "smoke writes the play log, element maps at the start, view and snapshots, and screenshot lines; the shop's buttons are clicked"
else
  bad "smoke writes the play log, element maps at the start, view and snapshots, and screenshot lines" "$(ls "$run" 2>&1)"
fi
# A run that starts without a view change names the current view: the example's shell never announces
# the shop, so the log's one view line is the first view, logged once.
if [ -n "$run" ] && [ "$(grep -c '"event":"view.changed"' "$run"/run-*.jsonl)" = "1" ] \
    && grep -q '"event":"view.changed","text":"shop","data":{"view":"shop","from":"","initial":true}' "$run"/run-*.jsonl; then
  ok "the play log names the shop as the first view of a run that starts without a view change, once"
else
  bad "the play log names the first view of a run that starts without a view change, once" "$(grep -h '"event":"view.changed"' "$run"/run-*.jsonl 2>&1 | head -n 3)"
fi
grep -q '"event":"autoplay.step".*"action":"next_day_fast","kind":"api"' "$(latest_run trade_week-1)"/run-*.jsonl \
  && ok "the scripted scenario mixes ui actions and an api action, and its expects hold" || bad "the scripted scenario performs its api action"
[ -z "$(/usr/bin/find "$user_data" -type f -newer "$work/before-autoplay" 2>/dev/null)" ] && ok "autoplay writes nothing in the game's user://" \
  || bad "autoplay writes nothing in the game's user://" "$(/usr/bin/find "$user_data" -type f -newer "$work/before-autoplay")"
# Several scenarios in one call play side by side: each has its own run folder and log, the results
# come out in the order given, and the exit code is the worst.
before_multi="$(ls "$runs")"
out="$(bash tools/autoplay.sh trade_week smoke --no-images 2>&1)"; expect_status "two scenarios in one call both run, with nothing found" 0 $? "$out"
[ "$(printf '%s\n' "$out" | grep -c ' · 0 findings · ')" = "2" ] && ok "a result line for each of the two scenarios" || bad "a result line for each of the two scenarios" "$out"
[ "$(printf '%s\n' "$out" | grep -E '^autoplay: (trade_week|smoke) · ' | cut -d ' ' -f 2 | uniq | tr '\n' ' ')" = "trade_week smoke " ] \
  && ok "the results are in the order given" || bad "the results are in the order given" "$out"
new_runs="$(ls "$runs" | grep -v -x -F "$before_multi")"
[ "$(printf '%s\n' "$new_runs" | grep -c -E '^(trade_week|smoke)-1-')" = "2" ] \
  && ok "each scenario has its own run folder" || bad "each scenario has its own run folder" "$new_runs"
mrun_a="$(printf '%s\n' "$new_runs" | grep '^trade_week-1-' | head -n 1)"; mrun_b="$(printf '%s\n' "$new_runs" | grep '^smoke-1-' | head -n 1)"
if [ -n "$mrun_a" ] && [ -n "$mrun_b" ] && [ -f "$(ls "$runs/$mrun_a"/run-*.log 2>/dev/null | head -n 1)" ] && [ -f "$(ls "$runs/$mrun_b"/run-*.log 2>/dev/null | head -n 1)" ] \
    && [ -f .godot/godot-director/autoplay-0.log ] && [ -f .godot/godot-director/autoplay-1.log ] \
    && grep -q '"scenario":"trade_week"\|trade_week' "$runs/$mrun_a"/run-*.jsonl && ! grep -q 'trade_week' "$runs/$mrun_b"/run-*.jsonl; then
  ok "each run has its own play log, and Godot's output goes to its own log"
else
  bad "each run has its own play log, and Godot's output goes to its own log" "$mrun_a $mrun_b"
fi
out="$(bash tools/autoplay.sh smoke nosuch_scenario --no-images 2>&1)"; expect_status "a failing scenario beside a passing one exits 1" 1 $? "$out"
expect_output "the passing one is reported" "^autoplay: smoke · .* · 0 findings · " "$out"
expect_output "the failing one is reported" "FAIL: .*no scenario 'nosuch_scenario'" "$out"
out="$(bash tools/autoplay.sh nosuch_scenario smoke --no-images --steps 2 2>&1)"; expect_status "the order given doesn't change the exit code" 1 $? "$out"
expect_output "the options reach every scenario" " · 2 steps · " "$out"
out="$(AUTOPLAY_JOBS=1 bash tools/autoplay.sh smoke trade_week --no-images 2>&1)"; expect_status "capped at one process: the scenarios still all run" 0 $? "$out"
[ "$(printf '%s\n' "$out" | grep -c ' · 0 findings · ')" = "2" ] && ok "and report both" || bad "and report both" "$out"
out="$(bash tools/autoplay.sh smoke trade_week --replay x --no-images 2>&1)"; expect_status "--replay with several scenarios is refused" 1 $? "$out"
# Determinism: the same seed twice gives the same JSONL, apart from time stamps and run ids, and the
# same element maps, with a Tween that widens the shop's Buy button after every change (autoplay
# runs at a fixed 60 frames a second, and each step settles until the tween has ended).
cp scripts/ui/shop_screen.gd "$work/saved-shop"; cp tools/autoplay_adapter.gd "$work/saved-adapter"
after_line "$work/saved-shop" 'func _refresh() -> void:' '\t_buy.custom_minimum_size.x = 0.0\n\tcreate_tween().tween_property(_buy, "custom_minimum_size:x", 300.0, 0.5)' \
  > scripts/ui/shop_screen.gd
out="$(bash tools/autoplay.sh smoke --no-images --seed 42 2>&1)"; first="$(latest_run smoke-42)"
out="$(bash tools/autoplay.sh smoke --no-images --seed 42 2>&1)"; second="$(latest_run smoke-42)"
if [ -n "$first" ] && [ "$first" != "$second" ] && normalized "$first" > "$work/autoplay-first" && normalized "$second" > "$work/autoplay-second" \
    && [ "$(grep -c '"event":"autoplay.step"' "$work/autoplay-first")" -gt 5 ] && cmp -s "$work/autoplay-first" "$work/autoplay-second"; then
  ok "the same seed and scenario twice give the same actions and the same JSONL, time stamps aside"
else
  bad "the same seed and scenario twice give the same actions and the same JSONL, time stamps aside" "$(diff "$work/autoplay-first" "$work/autoplay-second" 2>&1 | head -n 10)"
fi
differ=""
for map in $(cd "$first" && ls *.elements.json); do cmp -s "$first/$map" "$second/$map" || differ="$differ $map"; done
[ -z "$differ" ] && [ -n "$(ls "$first"/*.elements.json 2>/dev/null)" ] && ok "and the same element maps, with a Tween running after every action" \
  || bad "and the same element maps, with a Tween running after every action:$differ"
grep -qE '"id":"Buy","stable":true,[^}]*"rect":\[[0-9]+,[0-9]+,300,' "$first/0003-snapshot.elements.json" \
  && ok "each step settles until the tween has ended (the Buy button is 300 px wide)" || bad "the step settles until the tween has ended" "$(grep '"id":"Buy"' "$first/0003-snapshot.elements.json")"
cp "$work/saved-shop" scripts/ui/shop_screen.gd
out="$(bash tools/autoplay.sh smoke --no-images --steps 2 2>&1)"; expect_output "--steps caps a run" " · 2 steps · " "$out"
# Planted bug 1: a script error in a view's button handler, found at the click with its script line,
# an element map, a repro with the save from before the step, and replayed at the same step.
cp scripts/ui/shop_screen.gd "$work/saved-shop"; cp tools/autoplay_adapter.gd "$work/saved-adapter"
after_line "$work/saved-shop" 'func _on_buy_pressed() -> void:' '\tvar receipt: Node = null\n\treceipt.queue_free()' > scripts/ui/shop_screen.gd
printf '\n\nfunc save_run(path: String) -> bool:\n\tvar file: FileAccess = FileAccess.open(path, FileAccess.WRITE)\n\tfile.store_string(JSON.stringify(state()))\n\treturn true\n' >> tools/autoplay_adapter.gd
out="$(bash tools/autoplay.sh smoke --no-images 2>&1)"; expect_status "planted script error: the run fails" 1 $? "$out"
expect_output "it's found at the click, with the script line and the run folder" "FAIL: smoke step 1: error: Cannot call method 'queue_free' on a null value\. \(at res://scripts/ui/shop_screen\.gd:[0-9]+ in _on_buy_pressed\(\)\) · element map playtesting/autoplay/smoke-1-[0-9-]+/0001-error\.elements\.json · repro playtesting/autoplay/smoke-1-" "$out"
run="$(latest_run smoke-1)"
[ -f "$run/0001-error.elements.json" ] && grep -q '"step":1,"kind":"error"' "$run/repro.json" && grep -q '"save":"saves/before-0001.save"' "$run/repro.json" \
  && grep -q '"day":1,"gold":50,"grain":0' "$run/saves/before-0001.save" && grep -q '"event":"autoplay.finding"' "$run"/run-*.jsonl \
  && ok "its repro has the step, the actions, the element map and the save from before the step" || bad "the planted error's repro" "$(cat "$run/repro.json" 2>&1)"
out="$(bash tools/autoplay.sh --replay "$run" --no-images 2>&1)"; expect_status "--replay reproduces it" 1 $? "$out"
expect_output "at the same step" "FAIL: smoke step 1: error: Cannot call method 'queue_free' on a null value\. .*-replay/0001-error\.elements\.json" "$out"
out="$(bash tools/autoplay.sh --replay "$run" --until 0 --no-images 2>&1)"; expect_status "--until 0 stops before the step that fails" 0 $? "$out"
# --- log review ---------------------------------------------------------------------------------
# tools/log_review.sh reads the JSONL: the normalisation fixture, a person's logs in a fixture user
# dir (--player), and the planted error's autoplay runs (reused from above) for the sections, the
# delta between two runs, the signatures file and --check.
echo "log review"
review_section() { # review_section <review.md> <heading>: the lines under "## <heading>"
  awk -v head="## $2" '$0 == head { on = 1; next } /^## / { on = 0 } on' "$1"
}
sig_of() { sed -n 's/.*"signature": "\(sig-[0-9a-f]*\)".*/\1/p' "$1" | head -n 1; }
tab="$(printf '\t')"
cases="$src/tests/log-review/signature-cases.tsv"
command -v cygpath >/dev/null 2>&1 && cases="$(cygpath -m "$cases")"
out="$("$godot" --headless --path . --script tools/log_review.gd -- --cases "$cases" 2>&1 | tr -d '\r')"
while IFS= read -r line; do
  case "$line" in
    "PASS "*) ok "normalisation: ${line#PASS }" ;;
    "FAIL "*) bad "normalisation: ${line#FAIL }" ;;
  esac
done <<EOF
$out
EOF
printf '%s\n' "$out" | grep -q '^DONE$' && ok "the normalisation fixture ran to the end" || bad "the normalisation fixture ran to the end" "$out"
awk '!done && sub(/sig-2f29a879/, "sig-00000000") { done = 1 } { print }' "$src/tests/log-review/signature-cases.tsv" > "$work/cases-wrong.tsv"
wrong="$work/cases-wrong.tsv"; command -v cygpath >/dev/null 2>&1 && wrong="$(cygpath -m "$wrong")"
out="$("$godot" --headless --path . --script tools/log_review.gd -- --cases "$wrong" 2>&1 | tr -d '\r')"
printf '%s\n' "$out" | grep -q '^FAIL .*expected sig-00000000' && ok "a wrong expected signature in the fixture fails" || bad "a wrong expected signature in the fixture fails" "$out"
out="$(bash tools/log_review.sh --check nonsense 2>&1)"; expect_status "--check refuses a signature that isn't one" 2 $? "$out"
out="$(bash tools/log_review.sh "$work/no-such-run" 2>&1)"; expect_status "a folder that isn't there can't be reviewed" 3 $? "$out"

# A person's logs, in a fixture user dir: Market Day's user://logs/play, found from project.godot.
fx="$work/player-fixture"; mkdir -p "$fx"
case "$(uname -s)" in
  MINGW*|MSYS*|CYGWIN*) player_data="$fx"; player_std="$fx/Godot/app_userdata" ;;
  Darwin) player_data="$fx/Library/Application Support"; player_std="$player_data/Godot/app_userdata" ;;
  *) player_data="$fx/.local/share"; player_std="$player_data/godot/app_userdata" ;;
esac
fx_appdata="$fx"; command -v cygpath >/dev/null 2>&1 && fx_appdata="$(cygpath -w "$fx")"
as_player() { env APPDATA="$fx_appdata" XDG_DATA_HOME="$fx/.local/share" HOME="$fx" "$@"; }
logs="$player_std/Market Day/logs/play"; mkdir -p "$logs"
fl() { printf '{"t":%s,"turn":%s,"cat":"%s","event":"%s","text":"%s","data":%s}\n' "$1" "$2" "$3" "$4" "$5" "$6"; }
fixture_start() { fl 10 0 session session.start "Market Day $1 · Godot 4.7 · Windows · debug · args: (none)" "{\"game\":\"Market Day\",\"build\":\"$1\",\"godot\":\"4.7.2.stable\",\"os\":\"Windows\"}"; }
# 0.3.0: the index error and a hitch.
{ fixture_start 0.3.0
  fl 20 1 snapshot snapshot "day=1" '{"day":1}'
  fl 30 1 "engine error" engine.error "Index 3 is out of bounds (size 3). (at res://scripts/roster.gd:88 in pick())" '{"kind":"error"}'
  fl 40 1 hitch frame.hitch "frame took 120 ms" '{"ms":120}'
  fl 50 1 session session.end "session ended" '{}'
} > "$logs/run-20260101-090000.jsonl"
# 0.3.1: every kind of finding, two views (one not in the catalog), a key press, and a line that isn't JSON.
{ fixture_start 0.3.1
  fl 20 0 run run.new "new run 20260102-100000" '{"run":"20260102-100000"}'
  fl 30 1 view view.changed "shop" '{"view":"shop","from":""}'
  fl 35 1 snapshot snapshot "day=1" '{"day":1}'
  fl 40 1 input input.action "buy" '{"action":"buy"}'
  fl 50 1 trade trade.buy "bought grain" '{}'
  fl 55 2 snapshot snapshot "day=2" '{"day":2}'
  fl 60 2 progress progress.blocked "blocked: the grain cart is late, grain 3" '{"reason":"the grain cart is late, grain 3"}'
  fl 70 2 progress progress.pressed_blocked "pressed while blocked: the grain cart is late, grain 4" '{"blocked":"the grain cart is late, grain 4"}'
  fl 80 2 "engine error" engine.error "Index 17 is out of bounds (size 17). (at res://scripts/roster.gd:91 in pick())" '{"kind":"error"}'
  fl 90 2 "engine warning" engine.warning "selling at a loss (at res://scripts/ui/shop_screen.gd:41 in _on_sell_pressed())" '{"kind":"warning"}'
  fl 95 3 view view.changed "ledger" '{"view":"ledger","from":"shop"}'
  fl 96 3 snapshot snapshot "day=3" '{"day":3}'
  fl 100 3 hitch frame.hitch "frame took 140 ms" '{"ms":140}'
  fl 110 3 session session.end "session ended" '{}'
  printf '{"t":120,"turn":3,"cat":"bro\n'
} > "$logs/run-20260102-100000.jsonl"
# A launch that ended before a run began: never what a player played.
{ fixture_start 0.3.1; fl 20 null "engine error" engine.error "a boot-only error" '{}'; } > "$logs/boot-20260104-100000.jsonl"
index_sig="sig-2f29a879"; cart_sig="sig-d8ddb8e4"; sell_sig="sig-0dc8bfae"; hitch_sig="sig-40dd34bd"
out="$(bash tools/log_review.sh "$logs/run-20260101-090000.jsonl" 2>&1)"; expect_status "reviews a .jsonl by its path" 0 $? "$out"
expect_output "and says a person played it" "played by a person · 0 steps · 1 turn · 2 findings \(error 1, hitch 1\)" "$out"
last_seen=".godot/godot-director/signatures-last-seen.tsv"
grep -q "^$index_sig${tab}error${tab}Index <n> is out of bounds (size <n>)\. (at res://scripts/roster\.gd:<n> in pick())${tab}0\.3\.0\$" playtesting/signatures.tsv \
  && grep -q "^$index_sig${tab}0\.3\.0\$" "$last_seen" \
  && ok "the signatures file gets the signature, its kind, text and first build; the last seen build goes to the gitignored sidecar" || bad "the signatures file gets the signature" "$(cat playtesting/signatures.tsv "$last_seen")"
out="$(as_player bash tools/log_review.sh --player 2>&1)"; expect_status "--player reviews the newest run in the game's user://logs/play" 0 $? "$out"
expect_output "which is the one a person played last, not the boot file" "played by a person · 0 steps · 3 turns · 4 findings \(error 1, blocked 1, warning 1, hitch 1\)" "$out"
review="$logs/review.md"; findings="$logs/findings.json"
[ -f "$review" ] && [ -f "$findings" ] && ok "review.md and findings.json are written next to the log, in the user dir" || bad "review.md and findings.json next to the player's log" "$(ls "$logs")"
expect_output "the header: a person, the build, the length with a line that isn't JSON, the findings" "Played by: a person.*Build: 0\.3\.1 · Godot 4\.7\.2\.stable · Windows · Market Day.*Length: 15 lines, 3 turns \(T1-T3\) · session end logged · 1 unreadable line skipped.*Findings: 4 signatures \(error 1, blocked 1, warning 1, hitch 1\)" "$(tr '\n' ' ' < "$review")"
timeline="$(review_section "$review" Timeline)"
expect_output "timeline: the views in order" "^Views: shop > ledger$" "$timeline"
expect_output "timeline: a row per turn with its views and game events" "^\| T1 \| shop \| trade\.buy \|  \|$" "$timeline"
expect_output "timeline: findings sit in the turn they happened in" "^\| T2 \| .*\| $cart_sig, $index_sig, $sell_sig \|$" "$timeline"
expect_output "timeline: and the hitch in the last" "^\| T3 \| ledger \|  \| $hitch_sig \|$" "$timeline"
body="$(review_section "$review" Findings)"
expect_output "findings: grouped by signature, with the kind and the count" "^### $index_sig · error · 1x$" "$body"
expect_output "findings: a blocked reason that changed is one signature, counted twice" "^### $cart_sig · blocked · 2x$" "$body"
expect_output "findings: the normalised text, and the line as logged" "^- What: .*roster\.gd:<n> in pick\(\).*$" "$body"
expect_output "findings: and the first turn and line" "^- First: T2, line [0-9]+$" "$body"
expect_no_output "findings: a person's log has no step, screenshot or repro to name" "step [0-9]|Screenshot|Repro|Element map" "$body"
expect_no_output "findings: and the boot-only file is left out" "boot-only" "$body"
cover="$(review_section "$review" Coverage)"
expect_output "coverage: views opened against the catalog, and one the catalog doesn't have" "^- Views opened: 1 of 1 in the catalog \(shop, ledger\) · opened but not in the catalog: ledger$" "$cover"
expect_output "coverage: the keys pressed" "^- Controls actions pressed: buy x1 \(the game defines no input action beyond ui_\*\)$" "$cover"
expect_output "coverage: and that a person took no adapter actions" "^- Adapter actions taken: none \(a person played\)$" "$cover"
expect_output "delta: only autoplay runs have one" "^None: only an autoplay run folder has a delta" "$(review_section "$review" Delta)"
grep -q '"schema": 1' "$findings" && grep -q '"autoplay": false' "$findings" && [ "$(grep -c '"signature":' "$findings")" = "4" ] && grep -q '"first_step": null' "$findings" \
  && ok "findings.json holds the four signatures, with no step for a person's log" || bad "findings.json" "$(head -n 30 "$findings")"
grep -q "^$index_sig${tab}error${tab}.*${tab}0\.3\.0\$" playtesting/signatures.tsv && grep -q "^$cart_sig${tab}blocked${tab}the grain cart is late, grain <n>${tab}0\.3\.1\$" playtesting/signatures.tsv \
  && [ "$(grep -c "^$index_sig${tab}" playtesting/signatures.tsv)" = "1" ] && grep -q "^$index_sig${tab}0\.3\.1\$" "$last_seen" \
  && grep -q "^$cart_sig${tab}0\.3\.1\$" "$last_seen" \
  && ok "a known signature keeps its row, its last seen build moves in the sidecar, and the new ones are added" || bad "the signatures file after the second log" "$(cat playtesting/signatures.tsv "$last_seen")"
# 0.3.2: the index error is gone and the cart is still late.
{ fixture_start 0.3.2
  fl 20 1 snapshot snapshot "day=1" '{"day":1}'
  fl 30 1 progress progress.blocked "blocked: the grain cart is late, grain 9" '{"reason":"the grain cart is late, grain 9"}'
  fl 40 1 session session.end "session ended" '{}'
} > "$logs/run-20260103-100000.jsonl"
out="$(as_player bash tools/log_review.sh --player --check "$index_sig" 2>&1)"; expect_status "--check: a signature missing from the newest log is absent (exit 0)" 0 $? "$out"
expect_output "and says what it was and when it was seen" "check $index_sig: absent from .*logs/play · build 0\.3\.2 · played by a person · error: Index <n> is out of bounds .* first seen in build 0\.3\.0, last seen in build 0\.3\.1" "$out"
out="$(as_player bash tools/log_review.sh --player --check "$cart_sig" 2>&1)"; expect_status "--check: one still in it is present (exit 1)" 1 $? "$out"
expect_output "and says how often and where it first came" "check $cart_sig: PRESENT in .* build 0\.3\.2 .* \(1x, first at T1, line [0-9]+\)" "$out"
out="$(as_player bash tools/log_review.sh --player --check sig-00000000 2>&1)"; expect_status "--check: a signature the file doesn't know is an error (exit 2)" 2 $? "$out"
expect_output "and says to review first" "isn't in playtesting/signatures\.tsv" "$out"
# A signatures file from before 4.9.0 has a fifth column, last_seen_build. It reads as before, a review
# that finds only known signatures leaves it as it is, and the first new signature rewrites it
# without the column, its values moved to the sidecar.
cp playtesting/signatures.tsv "$work/sigs-new-format"; cp "$last_seen" "$work/sigs-last-seen"
{ printf 'id\tkind\ttext\tfirst_seen_build\tlast_seen_build\n'
  grep "^$index_sig${tab}" "$work/sigs-new-format" | sed "s/\$/${tab}0.2.9/"
  grep "^$hitch_sig${tab}" "$work/sigs-new-format" | sed "s/\$/${tab}0.2.9/"
  printf 'sig-0000beef\terror\tan old error\t0.1.0\t0.2.0\n'
} > playtesting/signatures.tsv
cp playtesting/signatures.tsv "$work/sigs-old-format"; rm -f "$last_seen"
out="$(bash tools/log_review.sh "$logs/run-20260101-090000.jsonl" 2>&1)"; expect_status "an old five-column signatures file still reads" 0 $? "$out"
cmp -s playtesting/signatures.tsv "$work/sigs-old-format" && ok "and a review with only known signatures leaves it as it is" || bad "the old file is left as it is" "$(cat playtesting/signatures.tsv)"
out="$(bash tools/log_review.sh "$logs/run-20260101-090000.jsonl" --check sig-0000beef 2>&1)"; expect_status "--check on the old file: a signature not in the log is absent" 0 $? "$out"
expect_output "and its last seen build comes from the old column" "first seen in build 0\.1\.0, last seen in build 0\.2\.0" "$out"
out="$(bash tools/log_review.sh "$logs/run-20260102-100000.jsonl" 2>&1)"; expect_status "a review with new signatures on the old file" 0 $? "$out"
[ "$(head -n 1 playtesting/signatures.tsv)" = "$(printf 'id\tkind\ttext\tfirst_seen_build')" ] \
  && grep -q "^sig-0000beef${tab}error${tab}an old error${tab}0\.1\.0\$" playtesting/signatures.tsv \
  && grep -q "^$cart_sig${tab}blocked${tab}.*${tab}0\.3\.1\$" playtesting/signatures.tsv \
  && grep -q "^sig-0000beef${tab}0\.2\.0\$" "$last_seen" && grep -q "^$index_sig${tab}0\.3\.1\$" "$last_seen" \
  && ok "rewrites it without last_seen_build, adds the new ones and moves the old values to the sidecar" || bad "the old file after a new signature" "$(cat playtesting/signatures.tsv "$last_seen")"
cp "$work/sigs-new-format" playtesting/signatures.tsv; cp "$work/sigs-last-seen" "$last_seen"
# use_custom_user_dir puts the folder straight under the data folder, named by custom_user_dir_name.
cp project.godot "$work/saved-project-godot"
after_line "$work/saved-project-godot" 'config/name="Market Day"' 'config/use_custom_user_dir=true\nconfig/custom_user_dir_name="Market Stall"' > project.godot
mkdir -p "$player_data/Market Stall/logs/play" && cp "$logs/run-20260101-090000.jsonl" "$player_data/Market Stall/logs/play/run-20260101-090000.jsonl"
out="$(as_player bash tools/log_review.sh --player 2>&1)"; expect_status "--player follows use_custom_user_dir" 0 $? "$out"
[ -f "$player_data/Market Stall/logs/play/review.md" ] && ok "and writes the review in the custom folder" || bad "the review in the custom user dir" "$out"
cp "$work/saved-project-godot" project.godot
rm -f "$logs"/*
out="$(as_player bash tools/log_review.sh --player 2>&1)"; expect_status "--player without a log exits 3" 3 $? "$out"
expect_output "and says to play first" "no run-\*\.jsonl|play the game first" "$out"

# The planted script error's autoplay run (above): every section, then the delta between runs.
planted="$(latest_run smoke-1)"
out="$(bash tools/log_review.sh "$planted" 2>&1)"; expect_status "reviews an autoplay run folder" 0 $? "$out"
expect_output "and says what it found, with the delta against the run before" "log_review: playtesting/autoplay/smoke-1-[0-9-]+ · scenario smoke seed 1 · 9 steps · [0-9]+ turns · 1 finding \(error 1\) · vs smoke-[0-9]+-[0-9-]+: 1 new, 0 gone, 0 still present" "$out"
review="$planted/review.md"; findings="$planted/findings.json"; sig="$(sig_of "$findings")"
[ -f "$review" ] && [ -f "$findings" ] && printf '%s' "$sig" | grep -qE '^sig-[0-9a-f]{8}$' && ok "review.md and findings.json are written next to the log" || bad "review.md and findings.json" "$(ls "$planted")"
expect_output "the header: autoplay, scenario and seed, the steps, one signature" "Played by: autoplay, scenario smoke, seed 1.*, 9 steps · session end logged.*Findings: 1 signature \(error 1\)" "$(tr '\n' ' ' < "$review")"
timeline="$(review_section "$review" Timeline)"
expect_output "timeline: the view" "^Views: shop$" "$timeline"
expect_output "timeline: steps per turn, and where the finding came from" "^\| T1 \| 1-3 \| shop \| .*\| $sig \|$" "$timeline"
body="$(review_section "$review" Findings)"
expect_output "findings: the signature, kind and count" "^### $sig · error · [0-9]+x$" "$body"
expect_output "findings: the text without the line number" "^- What: .*queue_free' on a null value\. \(at res://scripts/ui/shop_screen\.gd:<n> in _on_buy_pressed\(\)\).$" "$body"
expect_output "findings: and as logged, with it" "^- As logged: .*shop_screen\.gd:[0-9]+ in _on_buy_pressed\(\)" "$body"
expect_output "findings: the first step, turn and line" "^- First: step 1, T1, line [0-9]+$" "$body"
expect_output "findings: the element map, for an assistant that can't see images" "^- Element map: playtesting/autoplay/smoke-1-[0-9-]+/0001-error\.elements\.json$" "$body"
expect_output "findings: the repro" "^- Repro: playtesting/autoplay/smoke-1-[0-9-]+/repro\.json$" "$body"
expect_output "findings: the save from before the step" "^- Save before the step: playtesting/autoplay/smoke-1-[0-9-]+/saves/before-0001\.save$" "$body"
expect_output "findings: the replay command" "^- Replay: bash tools/autoplay\.sh --replay playtesting/autoplay/smoke-1-[0-9-]+ --until 1$" "$body"
cover="$(review_section "$review" Coverage)"
expect_output "coverage: the catalog's view was opened" "^- Views opened: 1 of 1 in the catalog \(shop\)$" "$cover"
expect_output "coverage: the adapter actions taken, with their kind" "^- Adapter actions taken: buy x[0-9]+ \(ui\), next_day x3 \(ui\)$" "$cover"
delta="$(review_section "$review" Delta)"
expect_output "delta: against the earlier run" "^Against playtesting/autoplay/smoke-[0-9]+-[0-9-]+ \(seed [0-9]+\)\.$" "$delta"
expect_output "delta: the error is new" "^- New:$" "$delta"
expect_output "delta: it's named" "^  - $sig \`error: Cannot call method" "$delta"
expect_output "delta: nothing is gone" "^- Gone: none$" "$delta"
expect_output "delta: and nothing is still present" "^- Still present: none$" "$delta"
grep -q '"first_step": 1,' "$findings" && grep -q '"kind": "error",' "$findings" && grep -q '"elements": "0001-error.elements.json",' "$findings" \
  && grep -q '"repro": "repro.json",' "$findings" && grep -q '"save": "saves/before-0001.save"' "$findings" && grep -q '"against": "playtesting/autoplay/smoke-' "$findings" \
  && ok "findings.json has the step, the files the finding names and the delta" || bad "findings.json" "$(head -n 40 "$findings")"
grep -q "^$sig${tab}error${tab}Cannot call method 'queue_free' on a null value\. (at res://scripts/ui/shop_screen\.gd:<n> in _on_buy_pressed())${tab}unversioned\$" playtesting/signatures.tsv \
  && ok "the signatures file has it, with the build named unversioned when the game sets no version" || bad "the signatures file has the planted error" "$(tail -n 3 playtesting/signatures.tsv)"
# The same error two lines lower has the same signature, and is still present.
after_line "$work/saved-shop" 'func _on_buy_pressed() -> void:' '\t# the same error, two lines lower:\n\t# the signature has no line number\n\tvar receipt: Node = null\n\treceipt.queue_free()' > scripts/ui/shop_screen.gd
out="$(bash tools/autoplay.sh smoke --no-images 2>&1)"; lower="$(latest_run smoke-1)"
git add playtesting/signatures.tsv && git_q -c core.hooksPath=/dev/null commit -qm "selftest: the signatures so far" -- playtesting/signatures.tsv
status_before="$(git status --porcelain)"
out="$(bash tools/log_review.sh "$lower" 2>&1)"; expect_status "reviews the next run" 0 $? "$out"
[ "$(git status --porcelain)" = "$status_before" ] && git diff --quiet -- playtesting/signatures.tsv \
  && ok "a review with only known signatures leaves the committed signatures file and git status as they were" \
  || bad "the review left the tree dirty" "$(git status --porcelain; git diff -- playtesting/signatures.tsv)"
[ "$lower" != "$planted" ] && [ "$(sig_of "$lower/findings.json")" = "$sig" ] && ok "the same error two lines lower has the same signature" || bad "the same signature at another line" "$(grep -h 'As logged' "$planted/review.md" "$lower/review.md")"
delta="$(review_section "$lower/review.md" Delta)"
expect_output "delta: still present" "^  - $sig " "$delta"
expect_output "delta: and not new" "^- New: none$" "$delta"
[ "$(grep -c "^$sig${tab}" playtesting/signatures.tsv)" = "1" ] && ok "and has one row in the signatures file" || bad "one row in the signatures file" "$(grep "^$sig" playtesting/signatures.tsv)"
# The fix: a clean run. The error is gone, and --check confirms it from the signatures file.
cp "$work/saved-shop" scripts/ui/shop_screen.gd
out="$(bash tools/autoplay.sh smoke --no-images 2>&1)"; clean="$(latest_run smoke-1)"
out="$(bash tools/log_review.sh "$clean" 2>&1)"; expect_status "reviews the clean run" 0 $? "$out"
expect_output "findings: none" "^None: no error" "$(review_section "$clean/review.md" Findings)"
delta="$(review_section "$clean/review.md" Delta)"
expect_output "delta: the error is gone" "^- Gone:$" "$delta"
expect_output "delta: it's named" "^  - $sig " "$delta"
expect_output "delta: nothing is new" "^- New: none$" "$delta"
expect_output "delta: and nothing is still present" "^- Still present: none$" "$delta"
out="$(bash tools/log_review.sh --check "$sig" 2>&1)"; expect_status "--check: absent from the newest autoplay run (exit 0)" 0 $? "$out"
expect_output "and says what it was" "check $sig: absent from playtesting/autoplay/smoke-1-[0-9-]+ · build unversioned · scenario smoke · error: Cannot call method .* first seen in build unversioned, last seen in build unversioned" "$out"
# The error comes back.
after_line "$work/saved-shop" 'func _on_buy_pressed() -> void:' '\tvar receipt: Node = null\n\treceipt.queue_free()' > scripts/ui/shop_screen.gd
out="$(bash tools/autoplay.sh smoke --no-images 2>&1)"; back="$(latest_run smoke-1)"
out="$(bash tools/log_review.sh --check "$sig" 2>&1)"; expect_status "--check: present in the newest run again (exit 1)" 1 $? "$out"
expect_output "and says where" "check $sig: PRESENT in playtesting/autoplay/smoke-1-[0-9-]+ .* \([0-9]+x, first at step 1, T1, line [0-9]+\)" "$out"
expect_output "delta: new again, against the clean run" "^  - $sig " "$(review_section "$back/review.md" Delta)"
out="$(bash tools/log_review.sh "$back"/run-*.jsonl 2>&1)"; expect_status "reviews a run's .jsonl by its path" 0 $? "$out"
cp "$work/saved-shop" scripts/ui/shop_screen.gd
}

l_autoplay2_a() {
lane_game warm
user_data_init
cp scripts/ui/shop_screen.gd "$work/saved-shop"; cp tools/autoplay_adapter.gd "$work/saved-adapter"
echo "autoplay"
# --from-save: the save written before the failing step, loaded through the adapter's load_save(),
# and the recorded actions from that step on, with the same step numbers.
after_line "$work/saved-shop" 'func _on_sell_pressed() -> void:' '\tvar receipt: Node = null\n\treceipt.queue_free()' > scripts/ui/shop_screen.gd
cp "$work/saved-adapter" tools/autoplay_adapter.gd
printf '\n\nfunc save_run(path: String) -> bool:\n\tvar data: Dictionary = {"seed": RunState.get("_market").get("_seed"), "day": RunState.day, "gold": RunState.gold, "grain": RunState.grain}\n\tvar file: FileAccess = FileAccess.open(path, FileAccess.WRITE)\n\tfile.store_string(JSON.stringify(data))\n\treturn true\n\n\nfunc load_save(path: String) -> bool:\n\tvar data: Variant = JSON.parse_string(FileAccess.get_file_as_string(path))\n\tif not (data is Dictionary):\n\t\treturn false\n\tRunState.start_run(int(data["seed"]))\n\tRunState.day = int(data["day"])\n\tRunState.gold = int(data["gold"])\n\tRunState.grain = int(data["grain"])\n\tPlayLog.set_turn(RunState.day)\n\tRunState.changed.emit()\n\treturn true\n' >> tools/autoplay_adapter.gd
out="$(bash tools/autoplay.sh smoke --no-images 2>&1)"
expect_output "a script error in the Sell handler, four steps in" "FAIL: smoke step 4: error: Cannot call method 'queue_free' on a null value\. \(at res://scripts/ui/shop_screen\.gd:[0-9]+ in _on_sell_pressed\(\)\)" "$out"
run="$(latest_run smoke-1)"
grep -q '"replay_from_save": "bash tools/autoplay.sh --replay .* --from-save"' "$run/repro.json" && grep -q '"day":2' "$run/saves/before-0004.save" \
  && ok "its repro offers a replay from the save written before step 4" || bad "the repro offers a replay from the save" "$(head -n 14 "$run/repro.json")"
out="$(bash tools/autoplay.sh --replay "$run" --from-save --no-images 2>&1)"; expect_status "--from-save reproduces it" 1 $? "$out"
expect_output "at the same step" "FAIL: smoke step 4: error: Cannot call method 'queue_free' on a null value\. .*in _on_sell_pressed" "$out"
replayed="$(ls -d "$runs"/smoke-1-*-replay* | LC_ALL=C /usr/bin/sort | tail -n 1)"
grep -q '"text":"step 4: Sell grain (%Sell)"' "$replayed"/run-*.jsonl && ! grep -q '"text":"step [1-3]: ' "$replayed"/run-*.jsonl \
  && ok "starting from the save, without playing steps 1 to 3" || bad "--from-save starts from the save" "$(grep -o '"text":"step [^"]*"' "$replayed"/run-*.jsonl)"
cp "$work/saved-shop" scripts/ui/shop_screen.gd; cp "$work/saved-adapter" tools/autoplay_adapter.gd
# An adapter whose start_run() doesn't start a run leaves the play log in the boot's temporary files.
replace_line "$work/saved-adapter" '\tRunState.start_run(run_seed)' '\tpass' > tools/autoplay_adapter.gd
out="$(bash tools/autoplay.sh smoke --no-images 2>&1)"
expect_output "a play log outside the run folder after start_run() is a finding" "FAIL: smoke step 0: adapter: the play log isn't writing into the run folder after start_run\(1\)" "$out"
cp "$work/saved-adapter" tools/autoplay_adapter.gd
# A ui action whose click never reaches its control: an invisible panel over the whole shop.
cp scenes/shop_screen.tscn "$work/saved-shop-scene"
printf '\n[node name="Glass" type="Control" parent="."]\nlayout_mode = 1\nanchors_preset = 15\nanchor_right = 1.0\nanchor_bottom = 1.0\ngrow_horizontal = 2\ngrow_vertical = 2\n' >> scenes/shop_screen.tscn
out="$(bash tools/autoplay.sh smoke --no-images 2>&1)"; expect_status "an invisible panel over the buttons fails the run" 1 $? "$out"
expect_output "the click that never reaches Next Day is a drive finding" "FAIL: smoke step 3: drive: the click on %NextDay \(next_day\) didn't reach it: something on top took it" "$out"
expect_output "and smoke says it never played its turns" "FAIL: smoke step 200: smoke: played 0 of 3 turns in 200 steps" "$out"
cp "$work/saved-shop-scene" scenes/shop_screen.tscn
# Planted bug 2: a progress block that never clears, with nothing offered that clears it.
cp tools/play_log.gd "$work/saved-play-log"
# Its reason changes as the player trades, as a countdown would; it's still the same block.
sed 's/return "the market has closed" if RunState.is_over() else ""/return "the market has closed" if RunState.is_over() else ("the grain cart is late, grain %d" % RunState.grain if RunState.day >= 2 else "")/' \
  "$work/saved-play-log" > tools/play_log.gd
out="$(bash tools/autoplay.sh smoke --no-images 2>&1)"; expect_status "planted progress block: the run fails" 1 $? "$out"
expect_output "it's a softlock, ten actions after the block began, naming the latest reason" "FAIL: smoke step 13: softlock: progress blocked across 10 actions \(the grain cart is late, grain [0-9]+\), and nothing list_actions\(\) offers unblocks it · element map .*/0013-softlock\.elements\.json · repro " "$out"
run="$(latest_run smoke-1)"
[ -f "$run/0013-softlock.elements.json" ] && [ -f "$run/0003-blocked.elements.json" ] && grep -q '"step":13,"kind":"softlock"' "$run/repro.json" \
  && ok "with element maps where it blocked and where it became a softlock, and a repro" || bad "the softlock's element maps and repro" "$(ls "$run")"
out="$(bash tools/autoplay.sh --replay "$run" --no-images 2>&1)"; expect_output "--replay reproduces it at the same step" "FAIL: smoke step 13: softlock: " "$out"
cp "$work/saved-play-log" tools/play_log.gd
# Planted bug 3: a view with no default focus.
sed '/_buy.grab_focus()/d' "$work/saved-shop" > scripts/ui/shop_screen.gd
out="$(bash tools/autoplay.sh smoke --no-images 2>&1)"; expect_status "planted missing focus: the run fails" 1 $? "$out"
expect_output "it's found when the view opens" "FAIL: smoke step 0: no-focus: the view shop has no focused control under ShopScreen \(so a keyboard or controller player can't act\) · element map .*/0000-no-focus\.elements\.json · repro " "$out"
run="$(latest_run smoke-1)"
out="$(bash tools/autoplay.sh --replay "$run" --until 0 --no-images 2>&1)"; expect_output "--replay reproduces it at the same step" "FAIL: smoke step 0: no-focus: the view shop " "$out"
cp "$work/saved-shop" scripts/ui/shop_screen.gd
}

l_autoplay2_b() {
lane_game warm
user_data_init
cp scripts/ui/shop_screen.gd "$work/saved-shop"; cp tools/autoplay_adapter.gd "$work/saved-adapter"
# Where a view keeps its focus: the adapter's focus_roots(). The shop has no default focus here, and
# the planted adapter adds a HUD layer outside the view node whose stand-in button holds the window's
# focus (and, for _make_page(), a SubViewport page under the view whose own button has the page's, the
# only control in the view that takes focus).
cat > "$work/focus-helpers.gd" <<'GDEOF'


var _hud: CanvasLayer = null
var _page: SubViewport = null


func _make_hud() -> void:
	_hud = CanvasLayer.new()
	_hud.name = "HUD"
	tree.root.add_child(_hud)
	var stand_in: Button = Button.new()
	stand_in.name = "StandIn"
	_hud.add_child(stand_in)
	stand_in.grab_focus()


func _make_page() -> void:
	_make_hud()
	# The shop's own buttons take no focus (a click leaves the focus where it is), as on a sheet view.
	for button: Node in tree.current_scene.find_children("*", "Button", true, false):
		(button as Button).focus_mode = Control.FOCUS_NONE
	_page = SubViewport.new()
	_page.name = "Page"
	tree.current_scene.add_child(_page)
	var control: Button = Button.new()
	control.name = "PageButton"
	_page.add_child(control)
	control.grab_focus()
GDEOF
focus_adapter() { # focus_adapter <lines run after start_run> [<body of focus_roots()>]
  replace_line "$work/saved-adapter" '\tawait wait_frames(1)' "\tawait wait_frames(1)\n\t$1" > tools/autoplay_adapter.gd
  cat "$work/focus-helpers.gd" >> tools/autoplay_adapter.gd
  if [ -n "${2:-}" ]; then printf '\n\nfunc focus_roots() -> Array[Node]:\n\t%s\n' "$2" >> tools/autoplay_adapter.gd; fi
}
sed '/_buy.grab_focus()/d' "$work/saved-shop" > scripts/ui/shop_screen.gd
focus_adapter '_make_hud()'
out="$(bash tools/autoplay.sh smoke --no-images 2>&1)"; expect_status "a focused control outside the view node, with the default hook, fails the run" 1 $? "$out"
expect_output "the no-focus finding names the view and the root it looked under" "FAIL: smoke step 0: no-focus: the view shop has no focused control under ShopScreen \(so a keyboard or controller player can't act\) · " "$out"
focus_adapter '_make_hud()' 'return [view_node() as Node, _hud]'
out="$(bash tools/autoplay.sh smoke --no-images 2>&1)"; expect_status "focus_roots() with the view and the HUD: the focus under the HUD counts" 0 $? "$out"
expect_no_output "and there is no no-focus finding" "no-focus" "$out"
focus_adapter '_make_hud()\n\ttree.root.gui_release_focus()' 'return [view_node() as Node, _hud]'
out="$(bash tools/autoplay.sh smoke --no-images 2>&1)"
expect_output "the finding names every root when the focus is under none" "FAIL: smoke step 0: no-focus: the view shop has no focused control under ShopScreen, HUD \(so a keyboard or controller player can't act\)" "$out"
focus_adapter '_make_page()'
out="$(bash tools/autoplay.sh smoke --no-images 2>&1)"
expect_output "a SubViewport page and a stand-in outside the roots: the default hook finds no focus" "FAIL: smoke step 0: no-focus: the view shop has no focused control under ShopScreen " "$out"
focus_adapter '_make_page()' 'return [_page, _hud]'
out="$(bash tools/autoplay.sh smoke --no-images 2>&1)"; expect_status "the page and the stand-in's HUD as roots: no finding" 0 $? "$out"
expect_no_output "the window's focus on the stand-in satisfies the check" "no-focus" "$out"
focus_adapter '_make_page()' 'return [_page]'
out="$(bash tools/autoplay.sh smoke --no-images 2>&1)"; expect_status "a SubViewport root alone: its own focus owner counts" 0 $? "$out"
expect_no_output "so the page's focused control satisfies the check" "no-focus" "$out"
replace_line "$work/saved-adapter" '\tawait wait_frames(1)' '\tawait wait_frames(1)' > tools/autoplay_adapter.gd
printf '\n\nfunc focus_roots() -> Array[Node]:\n\treturn []\n' >> tools/autoplay_adapter.gd
out="$(bash tools/autoplay.sh smoke --no-images 2>&1)"; expect_status "an empty focus_roots() skips the check, though the shop has no default focus" 0 $? "$out"
expect_no_output "and says nothing about focus" "no-focus" "$out"
cp "$work/saved-adapter" tools/autoplay_adapter.gd; cp "$work/saved-shop" scripts/ui/shop_screen.gd
# Every candidate at weight 0: the step picks nothing and smoke plays its turns with the progress action.
cp tools/autoplay_scenarios.gd "$work/saved-scenarios-w"
sed 's/"kind": "smoke", "turns": 3}/"kind": "smoke", "turns": 3, "weights": {"buy": 0, "sell": 0}}/' "$work/saved-scenarios-w" > tools/autoplay_scenarios.gd
out="$(bash tools/autoplay.sh smoke --no-images 2>&1)"; expect_status "smoke with every candidate at weight 0 still plays its turns" 0 $? "$out"
run="$(latest_run smoke-1)"
if [ "$(grep -c '"text":"step [0-9]*: Next day' "$run"/run-*.jsonl)" -ge 3 ] && ! grep -q '"text":"step [0-9]*: \(Buy\|Sell\) grain' "$run"/run-*.jsonl; then
  ok "the step picks nothing, and smoke carries on to the progress action"
else
  bad "weight 0 picks nothing" "$(grep -o '"text":"step [^"]*"' "$run"/run-*.jsonl | head -n 8)"
fi
cp "$work/saved-scenarios-w" tools/autoplay_scenarios.gd
# The other invariants: a freed view the shell still holds, the game's own invariant, a warning (a
# note, not a failure), orphan nodes growing every turn, and an empty action list.
cp tools/autoplay_invariants.gd "$work/saved-invariants"
# view_node() hands out a freed node and leaves an orphan node behind at every step.
printf '\n\nvar _made: bool = false\nvar _gone: Variant = null\n\n\nfunc view_node() -> Variant:\n\tNode.new()\n\tif not _made:\n\t\t_made = true\n\t\tvar node: Node = Node.new()\n\t\t_gone = node\n\t\tnode.free()\n\treturn _gone\n' >> tools/autoplay_adapter.gd
replace_line "$work/saved-invariants" '\treturn problems' '\tif int(state.get("gold", 0)) < 1000:\n\t\tproblems.append("gold is below 1000")\n\treturn problems' \
  > tools/autoplay_invariants.gd
after_line "$work/saved-shop" 'func _on_sell_pressed() -> void:' '\tpush_warning("selling at a loss")' > scripts/ui/shop_screen.gd
out="$(bash tools/autoplay.sh greedy_trader --no-images 2>&1)"; expect_status "the invariant fixtures fail the run" 1 $? "$out"
expect_output "a freed view" "FAIL: greedy_trader step 0: freed-view: the view the shell holds as current \(shop\) was freed" "$out"
expect_output "the game's own invariant" "FAIL: greedy_trader step 0: invariant: gold is below 1000" "$out"
expect_output "a warning, as a note" "autoplay: note: greedy_trader step [0-9]+: warning: selling at a loss \(at res://scripts/ui/shop_screen\.gd:[0-9]+ in _on_sell_pressed\(\)\)" "$out"
expect_output "orphan nodes growing every turn" "FAIL: greedy_trader step [0-9]+: orphans: the orphan-node count grew every turn for 3 turns" "$out"
cp "$work/saved-adapter" tools/autoplay_adapter.gd; cp "$work/saved-invariants" tools/autoplay_invariants.gd; cp "$work/saved-shop" scripts/ui/shop_screen.gd
replace_line "$work/saved-adapter" '\tif RunState.is_over():' '\tif RunState.is_over() or RunState.day >= 2:' > tools/autoplay_adapter.gd
out="$(bash tools/autoplay.sh smoke --no-images 2>&1)"
expect_output "no actions before the run is over" "FAIL: smoke step 3: no-actions: list_actions\(\) offers nothing, but the run isn't over \(view shop\)" "$out"
cp "$work/saved-adapter" tools/autoplay_adapter.gd
cp tools/autoplay_scenarios.gd "$work/saved-scenarios"
sed 's/{"do": "buy", "expect": {"grain": 2}}/{"do": "buy", "expect": {"grain": 3}}/' "$work/saved-scenarios" > tools/autoplay_scenarios.gd
out="$(bash tools/autoplay.sh trade_week --no-images --seed 42 2>&1)"
expect_output "a scripted expect that fails" "FAIL: trade_week step 2: expect: after buy: grain is 2, expected 3" "$out"
run="$(latest_run trade_week-42)"
grep -q '"boot_seed": 42,' "$run/repro.json" && ok "the repro keeps the seed the game booted with" || bad "the repro keeps the boot seed" "$(head -n 6 "$run/repro.json")"
out="$(bash tools/autoplay.sh --replay "$run" --no-images 2>&1)"; expect_status "--replay checks the expect again" 1 $? "$out"
expect_output "and fails at the same step" "FAIL: trade_week step 2: expect: after buy: grain is 2, expected 3 · .*-replay/" "$out"
replayed="$(ls -d "$runs"/trade_week-42-*-replay* | LC_ALL=C /usr/bin/sort | tail -n 1)"
grep -q '"boot_seed": 42,' "$replayed/repro.json" && ok "booting with the same seed" || bad "the replay boots with the same seed" "$(head -n 6 "$replayed/repro.json")"
sed 's/"kind": "smoke", "turns": 3}/"kind": "strategy", "strategy": "random"}/' "$work/saved-scenarios" > tools/autoplay_scenarios.gd
out="$(bash tools/autoplay.sh --list 2>&1)"; expect_status "refuses scenarios without a smoke scenario" 1 $? "$out"
expect_output "and says a smoke scenario is required" "a smoke scenario is required" "$out"
cp "$work/saved-scenarios" tools/autoplay_scenarios.gd
}

l_autoplay2_c() {
lane_game warm
user_data_init
cp scripts/ui/shop_screen.gd "$work/saved-shop"; cp tools/autoplay_adapter.gd "$work/saved-adapter"
# A second view in the catalog: smoke opens it through the action whose `opens` names it and backs
# out with the view's `back` action; without that action, the view smoke can't reach is a finding.
cp tools/ui_screens.gd "$work/saved-screens"
cat > scenes/ledger.tscn <<'EOF'
[gd_scene load_steps=2 format=3]

[ext_resource type="Script" path="res://scripts/ui/ledger_view.gd" id="1"]

[node name="LedgerView" type="VBoxContainer"]
anchors_preset = 15
anchor_right = 1.0
anchor_bottom = 1.0
script = ExtResource("1")

[node name="Close" type="Button" parent="."]
unique_name_in_owner = true
layout_mode = 2
text = "Close the ledger"
EOF
printf 'extends VBoxContainer\n\n\nfunc _ready() -> void:\n\tPlayLog.log_view("ledger")\n\t%%Close.pressed.connect(_on_close)\n\t%%Close.grab_focus()\n\n\nfunc _unhandled_input(event: InputEvent) -> void:\n\tif event.is_action_pressed("ui_cancel"):\n\t\t_on_close()\n\n\nfunc _on_close() -> void:\n\tget_tree().change_scene_to_file("res://scenes/shop_screen.tscn")\n' > scripts/ui/ledger_view.gd
after_line "$work/saved-screens" '\t\t\t"states": {"default": _shop, "closed": _shop_closed}},' '\t\t{"id": "ledger", "title": "Ledger", "scene": "res://scenes/ledger.tscn"},' > tools/ui_screens.gd
after_line "$work/saved-adapter" '\tvar actions: Array[Dictionary] = []' '\tif current_view() == "ledger":\n\t\tactions.append({"id": "close_ledger", "label": "Close", "kind": "ui", "node": "%Close", "back": true})\n\t\treturn actions\n\tactions.append({"id": "open_ledger", "label": "Ledger", "kind": "api", "opens": "ledger"})' \
  > "$work/adapter-ledger"
after_line "$work/adapter-ledger" '\tmatch str(action["id"]):' '\t\t"open_ledger":\n\t\t\ttree.change_scene_to_file("res://scenes/ledger.tscn")\n\t\t\treturn true' > tools/autoplay_adapter.gd
out="$(bash tools/autoplay.sh smoke --no-images 2>&1)"; expect_status "smoke opens a second catalog view and backs out of it" 0 $? "$out"
run="$(latest_run smoke-1)"
grep -q '"text":"step 1: Ledger (api)"' "$run"/run-*.jsonl && grep -q '"text":"step 2: Close (%Close)"' "$run"/run-*.jsonl \
  && grep -q '"screen": "ledger", "state": "view"' "$run/0001-view.elements.json" && [ -f "$run/0002-view.elements.json" ] \
  && ok "through the open action and the view's back action, with an element map at each view change" || bad "smoke's view opening" "$(ls "$run")"
grep -v '"id": "open_ledger"' tools/autoplay_adapter.gd > "$work/adapter-no-open" && cp "$work/adapter-no-open" tools/autoplay_adapter.gd
out="$(bash tools/autoplay.sh smoke --no-images 2>&1)"
expect_output "a catalog view no action opens is a finding" "FAIL: smoke step 0: smoke: no action opens the view ledger from the views smoke reached" "$out"
# Key routes: the ledger opens with Page Down (an `input` action the shop handles) and has no back
# action, so smoke backs out with ui_cancel (Escape); both presses must register as their actions.
after_line "$work/saved-adapter" '\tvar actions: Array[Dictionary] = []' '\tif current_view() == "ledger":\n\t\tactions.append({"id": "ledger_tab", "label": "Next entry (Tab)", "kind": "ui", "input": "ui_focus_next"})\n\t\treturn actions\n\tactions.append({"id": "open_ledger", "label": "Ledger (Page Down)", "kind": "ui", "input": "ui_page_down", "opens": "ledger"})' \
  > tools/autoplay_adapter.gd
printf '\n\nfunc _unhandled_input(event: InputEvent) -> void:\n\tif event.is_action_pressed("ui_page_down"):\n\t\tget_tree().change_scene_to_file("res://scenes/ledger.tscn")\n' >> scripts/ui/shop_screen.gd
out="$(bash tools/autoplay.sh smoke --no-images 2>&1)"; expect_status "smoke opens a view with a key and backs out with ui_cancel" 0 $? "$out"
run="$(latest_run smoke-1)"
grep -q '"text":"step 1: Ledger (Page Down) (input ui_page_down)"' "$run"/run-*.jsonl && grep -q '"text":"step 2: back (ui_cancel) (input ui_cancel)"' "$run"/run-*.jsonl \
  && grep -q '"event":"input.action","text":"ui_page_down"' "$run"/run-*.jsonl && grep -q '"event":"input.action","text":"ui_cancel"' "$run"/run-*.jsonl \
  && ok "both key presses register as their InputMap actions" || bad "the key routes" "$(grep -o '"text":"step [^"]*"' "$run"/run-*.jsonl | head -n 3)"
cp "$work/saved-screens" tools/ui_screens.gd; cp "$work/saved-adapter" tools/autoplay_adapter.gd; cp "$work/saved-shop" scripts/ui/shop_screen.gd
rm -f scenes/ledger.tscn scenes/ledger.tscn.uid scripts/ui/ledger_view.gd scripts/ui/ledger_view.gd.uid
# Controls in a SubViewport: the shop gets a page (a SubViewport with a button, %PageGo, that ends the
# day) on a flat face that shows it at twice its size and forwards the clicks into it, or a 2D
# SubViewportContainer. Only a SubViewport with a screen-rect provider is in the element map, so only
# then can a ui action click the button; the click must still reach it, and a disabled button is refused.
cat > "$work/page-helpers.gd" <<'GDEOF'


func _make_page(provided: bool, forwarded: bool, disabled: bool) -> void:
	var scene: Node = tree.current_scene
	var face: Control = Control.new()
	face.name = "Face"
	face.position = Vector2(10, 10)
	face.size = Vector2(160, 80)
	scene.add_child(face)
	var page: SubViewport = SubViewport.new()
	page.name = "Page"
	page.size = Vector2i(80, 40)
	face.add_child(page)
	_page_button(scene, page, disabled)
	if forwarded:
		face.gui_input.connect(_forward.bind(page))
	if provided:
		page.set_meta(&"godot_director_screen_rect", func(rect: Rect2) -> Rect2: return Rect2(face.get_global_rect().position + rect.position * 2.0, rect.size * 2.0))


func _make_box(provided: bool) -> void:
	var scene: Node = tree.current_scene
	var container: SubViewportContainer = SubViewportContainer.new()
	container.stretch = true
	container.position = Vector2(10, 10)
	container.size = Vector2(160, 80)
	scene.add_child(container)
	var page: SubViewport = SubViewport.new()
	page.name = "Page"
	container.add_child(page)
	_page_button(scene, page, false)
	if provided:
		page.set_meta(&"godot_director_screen_rect", func(rect: Rect2) -> Rect2: return container.get_global_transform_with_canvas() * rect)


## The page's button takes no focus, so a click leaves the window's focus where it is, as on a sheet view.
func _page_button(scene: Node, page: SubViewport, disabled: bool) -> void:
	var go: Button = Button.new()
	go.name = "PageGo"
	go.text = "Go"
	go.position = Vector2(10, 10)
	go.size = Vector2(50, 20)
	go.disabled = disabled
	go.focus_mode = Control.FOCUS_NONE
	page.add_child(go)
	go.owner = scene
	go.unique_name_in_owner = true
	go.pressed.connect(_page_pressed)


## What a sheet view does: the face turns a click at its place on screen into the page's own point.
func _forward(event: InputEvent, page: SubViewport) -> void:
	var mouse: InputEventMouse = event as InputEventMouse
	if mouse == null:
		return
	var local: InputEventMouse = mouse.duplicate() as InputEventMouse
	local.position = mouse.position / 2.0
	local.global_position = local.position
	page.push_input(local, true)


func _page_pressed() -> void:
	PlayLog.log_event("fixture", "page.go", "PageGo pressed")
	RunState.next_day()
GDEOF
page_adapter() { # page_adapter <the call run after start_run>: %PageGo is the progress action's node
  replace_line "$work/saved-adapter" '\tawait wait_frames(1)' "\tawait wait_frames(1)\n\t$1" > "$work/adapter-page"
  replace_line "$work/adapter-page" '\t\tactions.append({"id": "next_day", "label": "Next day", "kind": "ui", "node": "%NextDay", "progress": true})' \
    '\t\tactions.append({"id": "next_day", "label": "Next day", "kind": "ui", "node": "%PageGo", "progress": true})' > tools/autoplay_adapter.gd
  cat "$work/page-helpers.gd" >> tools/autoplay_adapter.gd
}
page_adapter '_make_page(true, true, false)'
out="$(bash tools/autoplay.sh smoke --no-images 2>&1)"; expect_status "a button in a SubViewport with a screen-rect provider is clicked as any ui action" 0 $? "$out"
run="$(latest_run smoke-1)"
if [ "$(grep -c '"event":"page.go"' "$run"/run-*.jsonl)" = "3" ] && grep -q '"route":"%PageGo"' "$run"/run-*.jsonl \
    && grep -qE '"id":"PageGo","stable":true,"path":"ShopScreen/Face/Page/PageGo",[^}]*"rect":\[30,30,100,' "$run/0000-start.elements.json"; then
  ok "it is in the element map at its place on screen, and the click the game forwards reaches it, three turns long"
else
  bad "the page's button is in the element map and its click reaches it" "$(grep -o '"id":"PageGo"[^}]*' "$run/0000-start.elements.json" 2>&1)"
fi
page_adapter '_make_page(true, false, false)'
out="$(bash tools/autoplay.sh smoke --no-images --steps 3 2>&1)"; expect_status "a click the game doesn't forward into the SubViewport fails the run" 1 $? "$out"
expect_output "as a drive finding that names the provider" "FAIL: smoke step [0-9]+: drive: the click on %PageGo \(next_day\) didn't reach it: .*SubViewport \(check the SubViewport's screen-rect provider\)" "$out"
page_adapter '_make_page(false, true, false)'
out="$(bash tools/autoplay.sh smoke --no-images --steps 3 2>&1)"; expect_status "a SubViewport with no provider stays out of the map, so its button can't be clicked" 1 $? "$out"
expect_output "and the action's control is not on screen" "FAIL: smoke step [0-9]+: drive: the control %PageGo, next_day's route, isn't on screen" "$out"
page_adapter '_make_page(true, true, true)'
out="$(bash tools/autoplay.sh smoke --no-images --steps 3 2>&1)"
expect_output "a disabled button in a provided SubViewport is refused as any ui action's" "FAIL: smoke step [0-9]+: drive: %PageGo is disabled, but list_actions\(\) offers next_day" "$out"
page_adapter '_make_box(true)'
out="$(bash tools/autoplay.sh smoke --no-images 2>&1)"; expect_status "a button in a 2D SubViewportContainer is clicked through the same provider, the container forwarding the click" 0 $? "$out"
run="$(latest_run smoke-1)"
[ "$(grep -c '"event":"page.go"' "$run"/run-*.jsonl)" = "3" ] && ok "and every turn's click reached it" || bad "every turn's click through the container reached the button" "$(grep -c '"event":"page.go"' "$run"/run-*.jsonl)"
cp "$work/saved-adapter" tools/autoplay_adapter.gd
# With a display: screenshots and map images at the requested size, and the planted error's screenshot.
out="$(bash tools/autoplay.sh smoke --size 1280x720 2>&1)"; status=$?
if [ "$status" -eq 3 ]; then
  echo "  skip  autoplay with a display: $(printf '%s' "$out" | tail -n 1)"
else
  expect_status "smoke with a display" 0 "$status" "$out"
  run="$(latest_run smoke-1)"
  [ -f "$run/0000-start.png" ] && [ -f "$run/0000-start.map.png" ] && [ -f "$run/0003-snapshot.png" ] && [ -f "$run/0009-end.png" ] \
    && [ "$(od -An -tu1 -j16 -N8 "$run/0000-start.png" | tr -s ' ' | sed 's/^ //')" = "0 0 5 0 0 0 2 208" ] \
    && grep -q '"size": \[1280, 720\]' "$run/0000-start.elements.json" \
    && ok "writes a screenshot, an element map and a map image at each moment, at the requested size (1280x720)" \
    || bad "writes a screenshot, an element map and a map image at each moment, at the requested size" "$(ls "$run")"
  after_line "$work/saved-shop" 'func _on_buy_pressed() -> void:' '\tvar receipt: Node = null\n\treceipt.queue_free()' > scripts/ui/shop_screen.gd
  out="$(bash tools/autoplay.sh smoke 2>&1)"
  expect_output "the planted error's finding names its screenshot" "FAIL: smoke step 1: error: .* · screenshot playtesting/autoplay/smoke-1-[0-9-]+/0001-error\.png · repro " "$out"
  run="$(latest_run smoke-1)"
  [ -f "$run/0001-error.png" ] && [ -f "$run/0001-error.map.png" ] && grep -q '"screenshot":"0001-error.png"' "$run/repro.json" \
    && ok "and writes it" || bad "the planted error's screenshot" "$(ls "$run")"
  cp "$work/saved-shop" scripts/ui/shop_screen.gd
fi
rm -rf "$runs"
out="$(bash tools/log_review.sh --latest 2>&1)"; expect_status "log review with no autoplay run says so (exit 3)" 3 $? "$out"
expect_output "and names where runs come from" "no autoplay run with a play log in playtesting/autoplay" "$out"


}

l_autoplay_check_a() {
lane_game warm
# --- autoplay in the check -----------------------------------------------------------------------
# tools/check.cfg > [autoplay]: smoke played headless once the rest passed. A finding fails the check
# only for a scenario under enforce; with the keys missing or check_in_check=false the check is what it
# was. A game made from the seeds is played or skipped cleanly, whatever it has registered.
echo "autoplay in the check"
cp tools/check.cfg "$work/saved-check-cfg"; cp scripts/ui/shop_screen.gd "$work/saved-shop"
set_autoplay() { # set_autoplay <check_in_check> <enforce as JSON>
  sed -e "s/^check_in_check=.*/check_in_check=$1/" -e "s/^enforce=.*/enforce=$2/" "$work/saved-check-cfg" > tools/check.cfg
}
rm -rf "$runs"
set_autoplay true '["smoke"]'
out="$(bash tools/check.sh 2>&1)"; expect_status "check_in_check with smoke under enforce passes on the clean example" 0 $? "$out"
expect_output "and says what smoke played" "check: note: autoplay: smoke · seed 1 · [0-9]+ steps · [0-9]+ turns · 0 findings$" "$out"
[ -z "$(ls "$runs" 2>/dev/null)" ] && ok "and keeps no run folder for a clean run" || bad "and keeps no run folder for a clean run" "$(ls "$runs")"
after_line "$work/saved-shop" 'func _on_buy_pressed() -> void:' '\tvar receipt: Node = null\n\treceipt.queue_free()' > scripts/ui/shop_screen.gd
out="$(bash tools/check.sh 2>&1)"; expect_status "a finding in smoke under enforce fails the check" 1 $? "$out"
expect_output "as GDIR-FAIL: autoplay, with the scenario, step, kind and summary" "GDIR-FAIL: autoplay: smoke step 1: error: Cannot call method 'queue_free' on a null value\." "$out"
expect_output "and names the element map and the repro folder" "0001-error\.elements\.json · repro playtesting/autoplay/smoke-1-" "$out"
expect_output "and says how to read and replay it" "log_review\.sh --latest.*autoplay\.sh --replay" "$out"
[ -f "$(latest_run smoke-1)/repro.json" ] && ok "the run with the finding keeps its folder, with the repro" || bad "the run with the finding keeps its folder" "$(ls "$runs" 2>&1)"
set_autoplay true '[]'
out="$(bash tools/check.sh 2>&1)"; expect_status "with enforce empty the same finding doesn't fail the check" 0 $? "$out"
expect_output "and is a note, marked as not enforced" "check: note: \(not enforced\) autoplay: smoke step 1: error: Cannot call method 'queue_free'" "$out"
grep -v '^enforce=' "$work/saved-check-cfg" > tools/check.cfg
out="$(bash tools/check.sh 2>&1)"; expect_status "with check_in_check on and enforce missing, smoke is a note too" 0 $? "$out"
}

l_autoplay_check_b() {
lane_game warm
cp tools/check.cfg "$work/saved-check-cfg"; cp scripts/ui/shop_screen.gd "$work/saved-shop"
set_autoplay() { # set_autoplay <check_in_check> <enforce as JSON>
  sed -e "s/^check_in_check=.*/check_in_check=$1/" -e "s/^enforce=.*/enforce=$2/" "$work/saved-check-cfg" > tools/check.cfg
}
rm -rf "$runs"
set_autoplay true '["*"]'
cp "$work/saved-shop" scripts/ui/shop_screen.gd
out="$(bash tools/check.sh 2>&1)"; expect_status "enforce [\"*\"] plays every scenario, clean" 0 $? "$out"
[ "$(printf '%s\n' "$out" | grep -c '^check: note: autoplay: .* · 0 findings$')" = "3" ] && ok "one note per scenario" || bad "one note per scenario" "$out"
after_line "$work/saved-shop" 'func _on_buy_pressed() -> void:' '\tvar receipt: Node = null\n\treceipt.queue_free()' > scripts/ui/shop_screen.gd
set_autoplay false '["smoke"]'
rm -f .godot/godot-director/autoplay_check-*; rm -rf "$runs"
out="$(bash tools/check.sh 2>&1)"; expect_status "with check_in_check=false the same finding doesn't fail the check" 0 $? "$out"
if ! printf '%s' "$out" | grep -qi 'autoplay' && [ -z "$(ls .godot/godot-director/autoplay_check-* 2>/dev/null)" ] && [ ! -e "$runs" ]; then
  ok "and the check plays nothing: no mention, no autoplay log, no run folder"
else
  bad "and the check plays nothing: no mention, no autoplay log, no run folder" "$out"
fi
grep -v -e '^check_in_check=' -e '^enforce=' "$work/saved-check-cfg" > tools/check.cfg
out="$(bash tools/check.sh 2>&1)"; expect_status "with both keys missing the check reads autoplay as off" 0 $? "$out"
expect_no_output "and says nothing about it" "autoplay" "$out"
awk '/^\[autoplay\]$/ { skip = 1; next } /^\[/ { skip = 0 } !skip' "$work/saved-check-cfg" > tools/check.cfg
out="$(bash tools/check.sh 2>&1)"; expect_status "with no [autoplay] section at all the check is what it was" 0 $? "$out"
expect_no_output "and says nothing about it either" "autoplay" "$out"
fp_before="$(bash tools/check.sh --fingerprint)"
set_autoplay false '[]'
[ "$fp_before" != "$(bash tools/check.sh --fingerprint)" ] && ok "the check's fingerprint covers tools/check.cfg" || bad "the check's fingerprint covers tools/check.cfg"
cp "$work/saved-check-cfg" tools/check.cfg; cp "$work/saved-shop" scripts/ui/shop_screen.gd
rm -rf "$runs"

}

l_autoplay_beside_a() {
lane_game warm
cp tools/check.cfg "$work/saved-check-cfg"; cp scripts/ui/shop_screen.gd "$work/saved-shop"
# In a parallel run autoplay starts as soon as the import and the load pass are clean, in its own process
# beside the test jobs (one fewer, so the CPU count holds); its result joins the report, with the exit
# codes as they were. A serial run (--jobs 1) plays it after the tests.
echo "autoplay beside the tests"
logs=".godot/godot-director"
out="$(bash tools/check.sh --jobs 3 2>&1)"; expect_status "--jobs 3 with smoke in the check passes" 0 $? "$out"
expect_output "and runs the tests in 2 processes: autoplay has the third" "running the tests in 2 processes" "$out"
expect_output "and says autoplay plays beside them" "check: playing the autoplay scenarios beside the tests" "$out"
expect_output "and the tests all ran" "12 tests passed" "$out"
expect_output "and smoke's note joins the report" "check: note: autoplay: smoke · seed 1 · [0-9]+ steps · [0-9]+ turns · 0 findings$" "$out"
[ -f "$logs/tests-2.log" ] && [ ! -e "$logs/tests-3.log" ] && [ -f "$logs/autoplay_check-smoke.log" ] \
  && ok "two test logs and autoplay's own" || bad "two test logs and autoplay's own" "$(ls "$logs")"
[ -z "$(ls "$runs" 2>/dev/null)" ] && ok "and a clean run keeps no run folder" || bad "and a clean run keeps no run folder" "$(ls "$runs")"
out="$(bash tools/check.sh --jobs 2 2>&1)"; expect_status "--jobs 2 gives the tests one process and autoplay one" 0 $? "$out"
expect_output "which is said in the singular" "running the tests in 1 process$" "$out"
expect_output "and runs all the tests" "12 tests passed" "$out"
expect_output "and plays smoke" "check: note: autoplay: smoke · seed 1 · " "$out"
out="$(bash tools/check.sh --jobs 1 2>&1)"; expect_status "--jobs 1 plays smoke after the tests" 0 $? "$out"
expect_no_output "with no processes beside each other" "beside the tests|running the tests in" "$out"
expect_output "and smoke's note in the report" "check: note: autoplay: smoke · seed 1 · " "$out"
# The proof that it plays beside the tests: a test that waits for autoplay's log, which exists only once
# autoplay has started, and passes only if that happens while the tests are running.
printf 'extends "res://tools/test_case.gd"\n\nfunc test_autoplay_plays_beside_the_tests() -> void:\n\tvar path: String = ProjectSettings.globalize_path("res://.godot/godot-director/autoplay_check-smoke.log")\n\tvar deadline: int = Time.get_ticks_msec() + 90000\n\twhile not FileAccess.file_exists(path) and Time.get_ticks_msec() < deadline:\n\t\tOS.delay_msec(100)\n\texpect(FileAccess.file_exists(path))\n' > tests/test_zz_beside.gd
out="$(bash tools/check.sh --jobs 3 2>&1)"; expect_status "a test that waits for autoplay's log passes: autoplay started while the tests ran" 0 $? "$out"
expect_output "and counts as one more test" "13 tests passed" "$out"
rm -f tests/test_zz_beside.gd tests/test_zz_beside.gd.uid
}

l_autoplay_beside_b() {
lane_game warm
cp scripts/ui/shop_screen.gd "$work/saved-shop"
logs=".godot/godot-director"
# A finding beside the tests fails the check as it does after them.
after_line "$work/saved-shop" 'func _on_buy_pressed() -> void:' '\tvar receipt: Node = null\n\treceipt.queue_free()' > scripts/ui/shop_screen.gd
out="$(bash tools/check.sh --jobs 3 2>&1)"; expect_status "a finding in smoke beside the tests fails the check" 1 $? "$out"
expect_output "as GDIR-FAIL: autoplay, with the scenario, step, kind and summary" "GDIR-FAIL: autoplay: smoke step 1: error: Cannot call method 'queue_free' on a null value\." "$out"
expect_output "and says how to read and replay it" "log_review\.sh --latest.*autoplay\.sh --replay" "$out"
expect_output "with the tests' own result beside it" "12 tests passed" "$out"
[ -f "$(latest_run smoke-1)/repro.json" ] && ok "the run with the finding keeps its folder, with the repro" || bad "the run with the finding keeps its folder" "$(ls "$runs" 2>&1)"
rm -rf "$runs"
out="$(bash tools/check.sh --jobs 1 2>&1)"; expect_status "the same finding after the tests in a serial run fails it too" 1 $? "$out"
expect_output "with the same line" "GDIR-FAIL: autoplay: smoke step 1: error: Cannot call method 'queue_free' on a null value\." "$out"
rm -rf "$runs"
if timeout --version 2>/dev/null | grep -qi coreutils || gtimeout --version 2>/dev/null | grep -qi coreutils; then
  printf 'extends "res://tools/test_case.gd"\n\nfunc test_hang() -> void:\n\tOS.delay_msec(120000)\n\texpect(true)\n' > tests/test_zz_hang.gd
  out="$(CHECK_TIMEOUT=40 bash tools/check.sh --jobs 3 2>&1)"; expect_status "a finding beside a timed-out test group exits 1, not 3" 1 $? "$out"
  expect_output "and names the finding" "GDIR-FAIL: autoplay: smoke step 1: error: Cannot call method 'queue_free' on a null value\." "$out"
  expect_output "and the timeout" "test group 2 of 2 timed out after 40 s" "$out"
  rm -f tests/test_zz_hang.gd tests/test_zz_hang.gd.uid; rm -rf "$runs"
fi
cp "$work/saved-shop" scripts/ui/shop_screen.gd
# Nothing starts while the game doesn't load: a script that doesn't parse stops autoplay from starting.
cp scripts/systems/market.gd "$work/saved"; printf 'func broken( -> void:\n' >> scripts/systems/market.gd
out="$(bash tools/check.sh --jobs 3 2>&1)"; expect_status "a script that doesn't parse fails the parallel check" 1 $? "$out"
expect_no_output "and autoplay is not started" "beside the tests" "$out"
[ -z "$(ls "$logs"/autoplay_check-* 2>/dev/null)" ] && [ ! -e "$runs" ] && ok "and plays nothing: no autoplay log, no run folder" || bad "and plays nothing: no autoplay log, no run folder" "$(ls "$logs" "$runs" 2>&1)"
cp "$work/saved" scripts/systems/market.gd
out="$(bash tools/check.sh 2>&1)"; expect_status "the check passes again after the beside-the-tests cases" 0 $? "$out"
rm -rf "$runs"

}

l_autoplay_fresh() {
cd "$work" || exit 1
# A game made from the seeds, with nothing wired yet: the new project's seed has autoplay in the check
# on, smoke exits 0 and says what to wire at each stage, the check passes, and nothing is written.
fresh="$work/fresh-game"; mkdir -p "$fresh"
printf 'config_version=5\n\n[application]\nconfig/name="Fresh"\nconfig/features=PackedStringArray("4.5")\n' > "$fresh/project.godot"
printf '[gd_scene format=3]\n\n[node name="Main" type="Control"]\n' > "$fresh/main.tscn"
(cd "$fresh" && git init -q && git config core.autocrlf false && git add -A && git_q commit -qm init) || exit 1
out="$(bash "$src/install.sh" "$fresh" 2>&1)"; expect_status "installs into a fresh game" 0 $? "$out"
if cmp -s "$fresh/.gitleaks.toml" "$src/project/.gitleaks.toml" && grep -q '^min-version="8\.18\.0"$' "$fresh/tools/check.cfg"; then
  ok "a new project gets the .gitleaks.toml seed and [gitleaks] min-version in tools/check.cfg"
else
  bad "a new project gets the .gitleaks.toml seed and [gitleaks] min-version in tools/check.cfg" "$out"
fi
if grep -q '^\[autoplay\]$' "$fresh/tools/check.cfg" && grep -q '^check_in_check=true$' "$fresh/tools/check.cfg" && grep -q '^enforce=\["smoke"\]$' "$fresh/tools/check.cfg" \
    && ! printf '%s' "$out" | grep -q 'autoplay in the check off'; then
  ok "a new project's tools/check.cfg has autoplay in the check on, with smoke enforced"
else
  bad "a new project's tools/check.cfg has autoplay in the check on, with smoke enforced" "$out"
fi
fresh_play() { (cd "$fresh" && GODOT_BIN="$godot" bash tools/autoplay.sh smoke --no-images 2>&1); }
out="$(fresh_play)"; expect_status "smoke in a fresh game with no PlayLog and no main scene exits 0" 0 $? "$out"
expect_output "and says to register the PlayLog" "autoplay: smoke · seed 1 · skipped: the game has no PlayLog autoload built on tools/play_log_base\.gd yet" "$out"
printf '\n[autoload]\n\nPlayLog="*res://tools/play_log.gd"\n' >> "$fresh/project.godot"
out="$(fresh_play)"; expect_status "with the PlayLog registered and no main scene it exits 0" 0 $? "$out"
expect_output "and says to set a main scene" "skipped: the project has no main scene yet" "$out"
after_line "$fresh/project.godot" 'config/name="Fresh"' 'run/main_scene="res://main.tscn"' > "$work/fresh-project" && cp "$work/fresh-project" "$fresh/project.godot"
out="$(fresh_play)"; expect_status "with a main scene and the seed's adapter it exits 0" 0 $? "$out"
expect_output "and says to fill in the adapter" "skipped: tools/autoplay_adapter\.gd isn't filled in yet, so there is no run to play" "$out"
out="$(cd "$fresh" && GODOT_BIN="$godot" bash tools/autoplay.sh --all --no-images 2>&1)"; expect_status "--all in the fresh game exits 0 too" 0 $? "$out"
[ -z "$(ls "$fresh/playtesting/autoplay" 2>/dev/null)" ] && ok "a skip writes no run folder and no boot log" || bad "a skip writes no run folder and no boot log" "$(ls -R "$fresh/playtesting/autoplay")"
out="$(cd "$fresh" && GODOT_BIN="$godot" bash tools/check.sh 2>&1)"; expect_status "the check passes in the fresh game with autoplay on and smoke enforced" 0 $? "$out"
expect_output "and notes that smoke was skipped, naming the adapter" "check: note: autoplay: smoke · seed 1 · skipped: tools/autoplay_adapter\.gd isn't filled in yet" "$out"
# An upgrade that gets a new tools/check.cfg gets it with autoplay in the check off.
rm -f "$fresh/tools/check.cfg"
out="$(bash "$src/install.sh" "$fresh" 2>&1)"; expect_status "upgrades the fresh game" 0 $? "$out"
if grep -q '^check_in_check=false$' "$fresh/tools/check.cfg" && grep -q '^enforce=\[\]$' "$fresh/tools/check.cfg" \
    && printf '%s' "$out" | grep -q 'with autoplay in the check off: \[autoplay\] check_in_check=false, enforce=\[\]'; then
  ok "an upgrade writes a new tools/check.cfg with autoplay in the check off, and says so"
else
  bad "an upgrade writes a new tools/check.cfg with autoplay in the check off" "$out"
fi
grep -q 'Wire autoplay' "$src/CHANGELOG.md" && grep -q 'enforce=\["smoke"\]' "$src/CHANGELOG.md" && grep -q 'a missing section reads as off' "$src/CHANGELOG.md" \
  && ok "and the changelog's upgrade step adds the \"Wire autoplay\" item and says how to turn the check on" || bad "the changelog's upgrade step for autoplay"


}


# --- the run ------------------------------------------------------------------------------------
# The guard's time on a long file body is measured first, with nothing else of ours running. Then the
# lanes start, the lanes that need no game first and then the longest of the rest; a lane that needs a
# game waits for it to be made (prepare, above), and when every place is taken the next one waits for a
# free place. The names after lane_start are the lanes' names (SELFTEST_ONLY); the order of lanes_print
# is the order of the sections.
cd "$work" || exit 1
guard_slow_measure
if [ -n "$godot" ]; then
  lane_start prototype           l_prototype
fi
lane_start installer-c         l_installer_c
lane_start stop-hook-session   l_stop_hook_session
lane_start release-check       l_release_check
lane_start orphan-report       l_orphan_report
lane_start framework           l_framework
[ -z "$godot" ] || lane_start autoplay-fresh l_autoplay_fresh
lane_start installer-a         l_installer_a
lane_start installer-b         l_installer_b
lane_start guard               l_guard               base
lane_start guard2              l_guard2              base
if [ -n "$godot" ]; then
  lane_start setup               l_setup               base
  lane_start check-import-a      l_check_import_a      ready
  lane_start autoplay            l_autoplay            warm
  lane_start stop-hook           l_stop_hook           warm
  lane_start check-import-b      l_check_import_b      warm
  lane_start autoplay-beside-b   l_autoplay_beside_b   warm
  lane_start check-faults-b      l_check_faults_b      warm
  lane_start autoplay2-b         l_autoplay2_b         warm
  lane_start par-c2              l_par_c2              warm
  lane_start secrets-b           l_secrets_b           warm
  lane_start capture-a2          l_capture_a2          warm
  lane_start autoplay-check-a    l_autoplay_check_a    warm
  lane_start autoplay-check-b    l_autoplay_check_b    warm
  lane_start check-faults-a      l_check_faults_a      warm
  lane_start autoplay-beside-a   l_autoplay_beside_a   warm
  lane_start autoplay2-a         l_autoplay2_a         warm
  lane_start par-d               l_par_d               warm
  lane_start check-misc-a        l_check_misc_a        warm
  lane_start pre-commit          l_precommit           warm
  lane_start capture-a1          l_capture_a1          warm
  lane_start capture-b           l_capture_b           warm
  lane_start capture-a3          l_capture_a3          warm
  lane_start par-b2              l_par_b2              warm
  lane_start fail-reason         l_fail_reason         warm
  lane_start par-b1              l_par_b1              warm
  lane_start check-misc-b        l_check_misc_b        warm
  lane_start autoplay2-c         l_autoplay2_c         warm
  lane_start par-c1              l_par_c1              warm
  lane_start secrets-a           l_secrets_a           warm
  lane_start par-a               l_par_a               warm
  lane_start secrets-c           l_secrets_c           warm
  lane_start playlog             l_playlog             warm
fi

lanes_print framework installer-a installer-b installer-c guard guard2 stop-hook-session release-check orphan-report
if [ -z "$godot" ]; then
  echo "check and hooks: skipped (pass the path to Godot 4.5+ to test them)"
  lanes_times
  finish
fi
lanes_print setup check-import-a check-import-b check-faults-a check-faults-b check-misc-a check-misc-b par-a par-b1 par-b2 fail-reason par-c1 par-c2 par-d \
  playlog stop-hook pre-commit secrets-a secrets-b secrets-c prototype capture-a1 capture-a2 capture-a3 capture-b autoplay \
  autoplay2-a autoplay2-b autoplay2-c autoplay-check-a autoplay-check-b autoplay-beside-a autoplay-beside-b autoplay-fresh
lanes_times
finish
