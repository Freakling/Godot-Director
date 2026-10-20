#!/usr/bin/env bash
# Godot Director self-test. It installs the framework into temporary copies of examples/market-day
# and tests the installer, the project check, the per-clone setup, the Claude Code hooks and the
# pre-commit hook. Run it after every change to the framework.
#
#   bash selftest.sh [path to Godot 4.5+]      (or set GODOT_BIN)
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
[ "$(cat "$src/project/playtesting/signatures.tsv")" = "$(printf 'id\tkind\ttext\tfirst_seen_build\tlast_seen_build')" ] \
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
# The minimum Godot is 4.5 (the engine Logger) everywhere it's stated and checked.
stale="$(cd "$src" && grep -nE '4\.3([^0-9]|$)|-lt [0-4] \]; \}|-ge [0-4] \]; \}' README.md ONBOARDING.md CLAUDE.md \
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
    && [ "$(cat playtesting/signatures.tsv)" = "$(printf 'id\tkind\ttext\tfirst_seen_build\tlast_seen_build')" ] \
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

# --- protected-space guard (Claude Code PreToolUse hook) ----------------------------------------
# Claude Code sends the path as given: relative, absolute POSIX, or Windows (JSON-escaped). The
# project root is $CLAUDE_PROJECT_DIR (the Windows cases pass a made-up root; the hook only reads text).
echo "protected-space guard"
guard_write() { # guard_write <expected exit> <what> <file_path as sent (JSON-escaped)> [project dir]
  local out got
  out="$(printf '{"session_id":"s","tool_name":"Write","tool_input":{"file_path":"%s","content":"x"}}' "$3" \
    | CLAUDE_PROJECT_DIR="${4:-$game}" bash .claude/hooks/guard-protected.sh 2>&1)"
  got=$?
  if [ "$got" -eq "$1" ]; then ok "$([ "$1" -eq 2 ] && echo blocks || echo allows): $2"; else bad "guard-protected exit $got, expected $1: $2" "$out"; fi
}
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

if [ -z "$godot" ]; then
  echo "check and hooks: skipped (pass the path to Godot 4.5+ to test them)"
  finish
fi

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

# --- the check ----------------------------------------------------------------------------------
echo "check"
out="$(bash tools/check.sh 2>&1)"; status=$?
expect_status "passes on a fresh clone of the example (Godot path with BOM and spaces)" 0 "$status" "$out"
expect_output "runs the example's tests" "12 tests passed" "$out"
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

out="$(bash tools/check.sh 2>&1)"; expect_status "passes again after the faults are removed" 0 $? "$out"

# --- parallel tests, per-file times, timeout ----------------------------------------------------
echo "parallel tests"
logs=".godot/godot-director"
test_order() { for f in "$@"; do tr -d '\r' < "$f"; done | sed -n 's/^GDIR-TEST: \(.*\)::.*$/\1/p' | uniq; }
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
cp "$work/saved" tests/test_market.gd
# The cfg keys: the seed has them with their defaults, the example has none (the defaults apply).
grep -q '^jobs="auto"$' "$src/project/tools/check.cfg" && grep -q '^timeout=600$' "$src/project/tools/check.cfg" \
  && grep -q 'case "$limit" in .*limit=600' tools/check.sh && ok "the seed's [tests] jobs and timeout have their defaults" \
  || bad "the seed's [tests] jobs and timeout have their defaults"
cp tools/check.cfg "$work/saved-cfg"
printf '\n[tests]\njobs=1\n' >> tools/check.cfg
out="$(bash tools/check.sh 2>&1)"; expect_status "[tests] jobs=1 in check.cfg runs one process" 0 $? "$out"
expect_no_output "with no group processes" "running the tests in" "$out"
cp "$work/saved-cfg" tools/check.cfg; printf '\n[tests]\njobs="2"\n' >> tools/check.cfg
out="$(bash tools/check.sh 2>&1)"; expect_output "[tests] jobs=\"2\" in check.cfg runs two" "running the tests in 2 processes" "$out"
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
cp "$work/saved-cfg" tools/check.cfg

# --- play log -----------------------------------------------------------------------------------
# The example's PlayLog runs under the check and writes nothing; tests/play-log/selftest_play_log.gd
# runs the base outside the check, into a folder of its own, and checks the files it writes.
echo "play log"
# The example's real user:// folder.
case "$(uname -s)" in
  MINGW*|MSYS*|CYGWIN*) user_data="$(cygpath -u "$APPDATA")/Godot/app_userdata/Market Day" ;;
  Darwin) user_data="$HOME/Library/Application Support/Godot/app_userdata/Market Day" ;;
  *) user_data="${XDG_DATA_HOME:-$HOME/.local/share}/godot/app_userdata/Market Day" ;;
esac
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
			if str(e.get("id")).begins_with("ddd-existing") and (e.get("locked") != true or float(e["opacity"]) != 25.0 or e.get("groupIds") != ["ddd-existing"]):
				problems.append(id + ": the existing group is locked, at 25% opacity")
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

# --- autoplay -----------------------------------------------------------------------------------
cp "$work/saved-check-cfg-ui" tools/check.cfg
# The example plays itself through its adapter: the real main scene, ui actions by real input and an
# api action, screenshots and element maps, the invariants, repros and replays, and the same log
# from the same seed. The planted bugs are the spec's three: a script error in a view's button
# handler, a progress block that never clears, a view with no default focus.
echo "autoplay"
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
grep -q "^$index_sig${tab}error${tab}Index <n> is out of bounds (size <n>)\. (at res://scripts/roster\.gd:<n> in pick())${tab}0\.3\.0${tab}0\.3\.0\$" playtesting/signatures.tsv \
  && ok "the signatures file gets the signature, its kind, text and the build it was first and last seen in" || bad "the signatures file gets the signature" "$(cat playtesting/signatures.tsv)"
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
grep -q "^$index_sig${tab}error${tab}.*${tab}0\.3\.0${tab}0\.3\.1\$" playtesting/signatures.tsv && grep -q "^$cart_sig${tab}blocked${tab}the grain cart is late, grain <n>${tab}0\.3\.1${tab}0\.3\.1\$" playtesting/signatures.tsv \
  && [ "$(grep -c "^$index_sig${tab}" playtesting/signatures.tsv)" = "1" ] \
  && ok "the signatures file moves a known signature's last seen build and adds the new ones" || bad "the signatures file after the second log" "$(cat playtesting/signatures.tsv)"
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
grep -q "^$sig${tab}error${tab}Cannot call method 'queue_free' on a null value\. (at res://scripts/ui/shop_screen\.gd:<n> in _on_buy_pressed())${tab}unversioned${tab}unversioned\$" playtesting/signatures.tsv \
  && ok "the signatures file has it, with the build named unversioned when the game sets no version" || bad "the signatures file has the planted error" "$(tail -n 3 playtesting/signatures.tsv)"
# The same error two lines lower has the same signature, and is still present.
after_line "$work/saved-shop" 'func _on_buy_pressed() -> void:' '\t# the same error, two lines lower:\n\t# the signature has no line number\n\tvar receipt: Node = null\n\treceipt.queue_free()' > scripts/ui/shop_screen.gd
out="$(bash tools/autoplay.sh smoke --no-images 2>&1)"; lower="$(latest_run smoke-1)"
out="$(bash tools/log_review.sh "$lower" 2>&1)"; expect_status "reviews the next run" 0 $? "$out"
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
set_autoplay true '["*"]'
cp "$work/saved-shop" scripts/ui/shop_screen.gd
out="$(bash tools/check.sh 2>&1)"; expect_status "enforce [\"*\"] plays every scenario, clean" 0 $? "$out"
[ "$(printf '%s\n' "$out" | grep -c '^check: note: autoplay: .* · 0 findings$')" = "3" ] && ok "one note per scenario" || bad "one note per scenario" "$out"
after_line "$work/saved-shop" 'func _on_buy_pressed() -> void:' '\tvar receipt: Node = null\n\treceipt.queue_free()' > scripts/ui/shop_screen.gd
set_autoplay false '["smoke"]'
rm -f .godot/godot-director/autoplay_check.log; rm -rf "$runs"
out="$(bash tools/check.sh 2>&1)"; expect_status "with check_in_check=false the same finding doesn't fail the check" 0 $? "$out"
if ! printf '%s' "$out" | grep -qi 'autoplay' && [ ! -e .godot/godot-director/autoplay_check.log ] && [ ! -e "$runs" ]; then
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

# A game made from the seeds, with nothing wired yet: the new project's seed has autoplay in the check
# on, smoke exits 0 and says what to wire at each stage, the check passes, and nothing is written.
fresh="$work/fresh-game"; mkdir -p "$fresh"
printf 'config_version=5\n\n[application]\nconfig/name="Fresh"\nconfig/features=PackedStringArray("4.5")\n' > "$fresh/project.godot"
printf '[gd_scene format=3]\n\n[node name="Main" type="Control"]\n' > "$fresh/main.tscn"
(cd "$fresh" && git init -q && git config core.autocrlf false && git add -A && git_q commit -qm init) || exit 1
out="$(bash "$src/install.sh" "$fresh" 2>&1)"; expect_status "installs into a fresh game" 0 $? "$out"
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


finish
