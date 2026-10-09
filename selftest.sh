#!/usr/bin/env bash
# Godot Director self-test. It installs the framework into temporary copies of examples/market-day
# and tests the installer, the project check, the per-clone setup, the Claude Code hooks and the
# pre-commit hook. Run it after every change to the framework.
#
#   bash selftest.sh [path to Godot 4.3+]      (or set GODOT_BIN)
#
# Without Godot, only the parts that don't need it are tested. KEEP=1 keeps the temporary folder.

set -u
src="$(cd "$(dirname "$0")" && pwd)"
godot="${1:-${GODOT_BIN:-}}"
work="$(mktemp -d)"
if [ "${KEEP:-0}" = "1" ]; then echo "keeping $work"; else trap 'rm -rf "$work"' EXIT; fi

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

# --- framework files ----------------------------------------------------------------------------
echo "framework"
plugin_version="$(sed -n 's/.*"version"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$src/.claude-plugin/plugin.json")"
[ "$plugin_version" = "$(tr -d '\r\n' < "$src/VERSION")" ] && ok "plugin.json version matches VERSION" \
  || bad "plugin.json version ($plugin_version) matches VERSION ($(cat "$src/VERSION"))"
installer="$src/skills/godot-director/SKILL.md"
if [ -f "$installer" ] && grep -q '^name: godot-director$' "$installer" && grep -q '^description: ' "$installer"     && grep -q 'ONBOARDING.md' "$installer" && grep -q 'git clone' "$installer"     && [ "$(find "$src" -name SKILL.md -not -path "*/.git/*" -mindepth 2 -maxdepth 4 | wc -l)" -eq 1 ]; then
  ok "the installer skill is the only one the skills CLI finds, and fetches Godot Director on its own"
else
  bad "skills/godot-director/SKILL.md (name, description, self-contained fetch, only skill found by npx skills add)"
fi
cmp -s "$src/LICENSE" "$src/framework/.godot-director/LICENSE" && ok "the installed LICENSE copy matches LICENSE" \
  || bad "framework/.godot-director/LICENSE differs from LICENSE"
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
      rules.md|tasks.md) [ -f "$src/framework/.godot-director/$ref" ] || missing="$missing $(basename "$doc")→$ref" ;;
      next-task.md|build.md|design.md|playtest.md|function-check.md|align.md|drift-reset.md|prune.md|review.md|refresh-model-sizing.md)
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
if [ ! -e .claude4godot ] && [ -f .godot-director/manifest ] && grep -q "^# godot-director $(tr -d '\r\n' < "$src/VERSION")$" .godot-director/manifest \
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

core_only="$work/core-only"; new_repo "$core_only"
out="$(bash "$src/install.sh" --tools none "$core_only" 2>&1)"
if [ ! -e "$core_only/.claude" ] && [ ! -e "$core_only/CLAUDE.md" ] && [ -f "$core_only/AGENTS.md" ] && [ -f "$core_only/.godot-director/rules.md" ]; then
  ok "--tools none installs the tool-neutral core only"
else
  bad "--tools none installs the tool-neutral core only" "$out"
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
cd "$game" || exit 1

# --- git guard (Claude Code PreToolUse hook) ----------------------------------------------------
echo "git guard"
guard() { # guard <expected exit> <command>
  local escaped="${2//\\/\\\\}"
  escaped="${escaped//\"/\\\"}"
  printf '{"session_id":"s","tool_name":"Bash","tool_input":{"command":"%s","description":"run"}}' "$escaped" \
    | bash .claude/hooks/guard-git.sh >/dev/null 2>&1
  local got=$?
  if [ "$got" -eq "$1" ]; then ok "$([ "$1" -eq 2 ] && echo blocks || echo allows): $2"; else bad "guard exit $got, expected $1: $2"; fi
}
for cmd in 'git commit -m x --no-verify' 'git commit -nm "x"' 'git push origin main --force' \
    'git push --force-with-lease=main origin' 'git push origin +main' 'git reset HEAD --hard' \
    'git -c core.hooksPath=/dev/null commit -m x' 'git config core.hooksPath ""' 'cd x && git clean -fd' \
    'git checkout -- .' 'git restore .' 'git stash drop' 'git branch -D topic' 'git reset --har HEAD' \
    'git -c core.hookspath=/dev/null commit -m x' 'git commit --no-veri -m x' 'git clean --force -d' \
    'git checkout -f main' 'git switch --discard-changes main'; do
  guard 2 "$cmd"
done
for cmd in 'git status --short' 'git commit -m "feat: x (T12)" -- a.gd' 'git commit --amend --no-edit' \
    'git push origin feature-flag' 'git restore --staged a.gd' 'git checkout -b topic' 'bash tools/check.sh' \
    'git commit -m "docs: grep -n usage" -- a.md' "git commit -m 'fix: handle -f flag' -- a.gd" \
    'git reset --soft HEAD~1' 'git switch main'; do
  guard 0 "$cmd"
done

if [ -z "$godot" ]; then
  echo "check and hooks: skipped (pass the path to Godot 4.3+ to test them)"
  finish
fi

# --- per-clone setup ----------------------------------------------------------------------------
echo "setup-clone"
out="$(GODOT_BIN=/nonexistent/godot bash tools/check.sh 2>&1)"; expect_status "the check exits 3 without Godot" 3 $? "$out"
out="$(bash tools/setup-clone.sh "$godot" 2>&1)"; expect_status "setup-clone succeeds" 0 $? "$out"
grep -qs "Godot Director" "$(git rev-parse --git-path hooks)/pre-commit" && ok "installs the pre-commit hook" || bad "installs the pre-commit hook" "$out"
[ -z "$(git config --get core.hooksPath)" ] && ok "leaves core.hooksPath alone (Git LFS keeps working)" || bad "leaves core.hooksPath alone"
# A path saved by PowerShell: UTF-8 BOM, trailing spaces, CRLF.
printf '\357\273\277%s  \r\n' "$godot" > tools/godot_bin.local

# --- the check ----------------------------------------------------------------------------------
echo "check"
out="$(bash tools/check.sh 2>&1)"; status=$?
expect_status "passes on a fresh clone of the example (Godot path with BOM and spaces)" 0 "$status" "$out"
expect_output "runs the example's tests" "6 tests passed" "$out"
expect_output "scans the screen scripts" "1 screen script scanned" "$out"
expect_no_output "reports no missing hook" "no Godot Director pre-commit hook" "$out"
out="$(bash tools/check.sh --if-changed 2>&1)"; expect_output "--if-changed reuses the last pass" "nothing changed since the last passing run" "$out"

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
fault "a failing test" tests/test_market.gd "$(printf '\nfunc test_selftest_failure() -> void:\n\texpect_eq(1, 2)')" 'expected 2, got 1'
fault "an async test" tests/test_market.gd "$(printf '\nfunc test_selftest_async() -> void:\n\tawait Engine.get_main_loop().process_frame\n\texpect(true)')" 'must be synchronous'
fault "a runtime error in a test" tests/test_market.gd "$(printf '\nfunc test_selftest_crash() -> void:\n\tvar node: Node = null\n\tnode.get_name()')" 'SCRIPT ERROR'
cp data/market_config.tres "$work/saved"
sed 's|scripts/resources/market_config\.gd|scripts/resources/renamed.gd|' "$work/saved" > data/market_config.tres
out="$(bash tools/check.sh 2>&1)"; expect_status "fails on a resource whose script was renamed" 1 $? "$out"
cp "$work/saved" data/market_config.tres

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
expect_output "sets the check meta under the new and the deprecated 2.x name" "8 tests passed" "$out"
rm -f tests/test_selftest_meta.gd tests/test_selftest_meta.gd.uid

out="$(bash tools/check.sh 2>&1)"; expect_status "passes again after the faults are removed" 0 $? "$out"

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
cp scenes/shop_screen.tscn "scenes/þorp.tscn" && git add "scenes/þorp.tscn"
out="$(git_q commit -qm "non-ASCII scene" 2>&1)"; status=$?
expect_output "runs the check for a non-ASCII file name" "running the project check" "$out"
expect_status "commits it" 0 "$status" "$out"
printf 'x\n' > tools/check.sh.gdir-new
printf '\n# another change\n' >> scripts/systems/market.gd && git add scripts/systems/market.gd
out="$(git_q commit -qm "with gdir-new" 2>&1)"; expect_status "refuses while a .gdir-new file is unmerged" 1 $? "$out"
rm -f tools/check.sh.gdir-new
no_project="$work/no-project"; new_repo "$no_project"
bash "$src/install.sh" "$no_project" >/dev/null 2>&1
(cd "$no_project" && printf '%s\n' "$godot" > tools/godot_bin.local && bash tools/setup-clone.sh >/dev/null 2>&1 \
  && git add -A && git_q commit -qm "install" >/dev/null 2>&1)
expect_status "commits in a repository without project.godot yet" 0 $?

finish
