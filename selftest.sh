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
      next-task.md|build.md|design.md|research.md|playtest.md|function-check.md|align.md|drift-reset.md|prune.md|review.md|refresh-model-sizing.md|ui-design.md)
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
settings="$src/framework/.claude/settings.json"
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
    framework/tools/ui_overlay.gd project/tools/ui_screens.gd project/tools/ui_capture.cfg \
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
grep -q '"Bash(bash tools/ui_capture.sh \*)"' "$settings" || wired="$wired settings.json"
grep -q '"/design/ui/captures/"' "$src/install.sh" && grep -q '^/design/ui/captures/$' "$src/examples/market-day/.gitignore" || wired="$wired captures gitignore line"
grep -q '"/tools/ui_\*\.gd text eol=lf"' "$src/install.sh" || wired="$wired .gitattributes line"
grep -q '^extends "res://tools/ui_catalog\.gd"$' "$src/project/tools/ui_screens.gd" || wired="$wired ui_screens.gd seed"
[ -z "$wired" ] && ok "ui-design is wired into the rules, the skill, the settings, the lint and the installer's lines" \
  || bad "ui-design isn't wired into:$wired"
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
if [ -x tools/ui_capture.sh ] && [ -f tools/ui_capture.gd ] && [ -f tools/ui_lint.gd ] && [ -f .claude/skills/ui-design/SKILL.md ] \
    && grep -q '^/design/ui/captures/$' .gitignore && grep -q '"shop"' tools/ui_screens.gd; then
  ok "installs /ui-design: procedure, skill, capture tools and the captures gitignore line, keeping the game's catalog"
else
  bad "installs /ui-design: procedure, skill, capture tools and the captures gitignore line, keeping the game's catalog" "$out"
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
if [ -f "$core_only/.godot-director/procedures/research.md" ] && [ -f "$core_only/.godot-director/research-domain.md" ] \
    && [ -f "$core_only/design/research/README.md" ] && [ -f "$core_only/tools/ui_screens.gd" ] && [ -f "$core_only/tools/ui_capture.cfg" ] && grep -q '^\*\*Next IDs:\*\* T[0-9]* · B[0-9]* · R[0-9]*$' "$core_only/TASKS.md"; then
  ok "a new game gets the research procedure and domain file, the note folder, the screen catalog and capture settings, and an R counter in TASKS.md, even with --tools none"
else
  bad "a new game gets the research procedure and domain file, the note folder, the screen catalog and capture settings, and an R counter in TASKS.md" "$out"
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

# --- screen capture (/ui-design) ----------------------------------------------------------------
echo "ui capture"
captures=design/ui/captures
out="$(GODOT_BIN=/nonexistent/godot bash tools/ui_capture.sh --all 2>&1)"; expect_status "capture exits 3 without Godot" 3 $? "$out"
[ ! -e "$captures" ] && ok "and writes nothing" || bad "capture without Godot wrote $captures"
out="$(bash tools/ui_capture.sh --list 2>&1)"; expect_status "lists the catalog" 0 $? "$out"
expect_output "lists each screen with its states and scene" "^shop · Shop screen · states: default, closed · opens res://scenes/shop_screen\.tscn · drawing: no · spec: no$" "$out"

# Lint fixtures: a screen built to break each rule, and a clean one. Headless, so no display needed.
cp tools/ui_screens.gd "$work/saved-catalog"
write_fixtures() {
  mkdir -p ui_fixtures
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
EOF
}
write_fixtures
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
out="$(bash tools/ui_capture.sh --all --no-images --size 1280x720 2>&1)"; expect_status "--no-images maps and lints the fixtures headless" 0 $? "$out"
lint_fixtures "headless"
grep -q '"id":"Chest","path":"Node3D#[0-9]*/Chest","kind":"Area3D"' "$captures/pickable@1280x720.elements.json" 2>/dev/null \
  && ok "maps a clickable 3D object through the camera" || bad "maps a clickable 3D object through the camera" "$(cat "$captures/pickable@1280x720.elements.json" 2>&1)"
[ ! -e "$captures/clean@1280x720.png" ] && ok "--no-images writes no images" || bad "--no-images writes no images"
grep -q '"id":"Label#1","stable":false,"path":"Control#[0-9]*/CenterContainer#0/VBoxContainer#0/Label#1"' "$captures/rows@1280x720.elements.json" 2>/dev/null \
  && ok "names a node Godot named by its class and place" || bad "names a node Godot named by its class and place" "$(head -n 8 "$captures/rows@1280x720.elements.json" 2>&1)"
cp "$captures/rows@1280x720.elements.json" "$work/rows-all"
out="$(bash tools/ui_capture.sh rows --no-images --size 1280x720 2>&1)"
cmp -s "$captures/rows@1280x720.elements.json" "$work/rows-all" && ok "a screen built in code maps the same alone as in --all" \
  || bad "a screen built in code maps the same alone as in --all" "$(diff "$work/rows-all" "$captures/rows@1280x720.elements.json")"

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
expect_output "fails a setup that doesn't finish" "FAIL: stuck@1280x720: the setup didn't finish within 2 seconds" "$out"
grep -q "^error: the setup didn't finish" "$captures/stuck@1280x720.lint.txt" 2>/dev/null && [ -f "$captures/after@1280x720.elements.json" ] \
  && ok "writes that to its lint file and goes on" || bad "writes that to its lint file and goes on" "$out"
cp "$work/saved-capture-cfg" tools/ui_capture.cfg
out="$(bash tools/ui_capture.sh nowhere --no-images 2>&1)"; expect_output "refuses an unknown screen" "no screen 'nowhere'" "$out"
cp "$work/saved-catalog" tools/ui_screens.gd; rm -rf ui_fixtures "$captures"

# The example's screens with a display: every state and size, nothing in user://, repeatable.
case "$(uname -s)" in
  MINGW*|MSYS*|CYGWIN*) user_data="$(cygpath -u "$APPDATA")/Godot/app_userdata/Market Day" ;;
  Darwin) user_data="$HOME/Library/Application Support/Godot/app_userdata/Market Day" ;;
  *) user_data="${XDG_DATA_HOME:-$HOME/.local/share}/godot/app_userdata/Market Day" ;;
esac
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
  write_fixtures; rm -rf "$captures"
  out="$(bash tools/ui_capture.sh --all --size 1280x720 2>&1)"; expect_status "captures the lint fixtures with a display" 0 $? "$out"
  lint_fixtures "with a display"
  cp "$work/saved-catalog" tools/ui_screens.gd; rm -rf ui_fixtures "$captures"
fi

finish
