# Tasks

This is Godot Director's own work queue, for developing the framework itself. It is fed by [Director-Driven Development](https://github.com/Freakling/Director-Driven-Development)'s orchestrator through pull requests. `project/TASKS.md` is a different file: the template shipped to adopters, which never receives these items.

Item format: `framework/.godot-director/tasks.md`. Queue order is priority; reorder by moving items.

**Next IDs:** T13 · B3 · R1

## Queue

### T12 · The repository's own queue has a research counter · done · XS · agent
- Touches: TASKS.md
- Done when: `Next IDs` carries the `R` counter that `align.md` asks for, `· R1` (check)
- GDD: (none)
- Source: Director-Driven-Development T119

### T10 · The repository ignores OS metadata files · done · XS · agent
- Touches: .gitignore, CHANGELOG.md
- Done when: `.gitignore` lists `.DS_Store`, `Thumbs.db`, `desktop.ini` and `__MACOSX/` (check)
- GDD: (none)
- Source: Director-Driven-Development T100

### B2 · The protected-space guard blocks absolute paths · done · S · agent · high
- Touches: framework/.claude/hooks/guard-protected.sh, selftest.sh
- Repro: with the project at `<root>`, Claude Code writes to `<root>/director/x` (absolute), or `C:\\...\\director\\x` on Windows → expected: the hook blocks it / actual: the hook allows it, because it matched `director/*` only against the path as written
- Found in: Director-Driven-Development T85
- GDD: (none)

### T11 · /ui-design says how to open and save the starter drawing · done · S · agent
- Touches: framework/.godot-director/procedures/ui-design.md, project/design/ui/README.md, examples/market-day/design/ui/README.md, CHANGELOG.md
- Done when: the capture step gives the one message (nothing to install, excalidraw.com with no account, open, save to `director/ui/<screen>.excalidraw` with the browser difference, privacy, "tell me when it's saved") (check) · the drawing guide seed and the example's copy have the same "Using Excalidraw" section, and the two files are identical (check) · the CHANGELOG entry says existing projects keep their own guide and gets the message on the next capture (check)
- GDD: (none)
- Source: Director-Driven-Development T103 (product/anchors/ui-design.md)

### T9 · /ui-design: verify and the workflow hooks · done · M · agent
- Depends on: T8
- Touches: framework/tools/ui_verify.gd (new), framework/tools/ui_overlay.gd, framework/tools/ui_drawing.gd, framework/tools/ui_capture.gd, framework/tools/ui_capture.sh, framework/tools/ui_catalog.gd, framework/tools/check.sh, framework/.godot-director/procedures/ui-design.md, framework/.godot-director/procedures/build.md, framework/.godot-director/procedures/review.md, framework/.godot-director/procedures/function-check.md, framework/.godot-director/procedures/align.md, framework/.godot-director/rules.md, framework/.claude/skills/ui-design/SKILL.md, project/tools/ui_capture.cfg, project/AGENTS.md, examples/market-day/tools/ui_capture.cfg, examples/market-day/AGENTS.md, examples/market-day/.gitignore, install.sh, README.md, ONBOARDING.md, selftest.sh, CHANGELOG.md
- Done when: `/ui-design verify` captures a screen, lists its deviations from the spec in a table and writes compare images, and on a fixture built as its spec says reports none, while moving one node 10% reports exactly that element (test) · the build, review, function check and align procedures use the screen spec, and align lists screens missing from the catalog without failing (check) · `check.sh` with `check_in_check=true` and a screen under `enforce` fails on a lint finding and passes otherwise, and with the defaults the check is unchanged (test) · a project upgraded from v3.10.0 gets the stubs, the `.gitignore` line and the manifest entries, keeps its own AGENTS.md and check.cfg, and ends with the lint off (test) · a catalog entry's `overlays` put a HUD an autoload draws into the capture (test) · every step of the procedure has a text path for a tool that can't view images (check)
- GDD: (none)
- Source: Director-Driven-Development T83

### T8 · /ui-design: drawings and screen specs · done · M · agent
- Depends on: T7
- Touches: framework/tools/ui_drawing.gd (new), framework/tools/ui_capture.gd, framework/.godot-director/procedures/ui-design.md, framework/.godot-director/procedures/design.md, framework/.godot-director/tasks.md, framework/.godot-director/rules.md, framework/.claude/skills/ui-design/SKILL.md, project/design/ui/README.md (new), examples/market-day/design/ui/README.md (new), ONBOARDING.md, tests/ui-drawing/ (new), selftest.sh, CHANGELOG.md
- Done when: `capture` writes a starter drawing, a valid Excalidraw file with the screenshot locked in a frame named after the screen, which saved unchanged and read back gives no boxes and nothing unparsed (test) · the reader gives exactly the expected `drawing.json` for a fixture drawing (a green box with bound text and `click:`, a blue box over an existing element, a red X, an arrowed comment, a nested box, a note outside the frame, a freehand squiggle), and the same percentages when the background image is moved and scaled 50% (test) · `/ui-design process` reads a drawing through `drawing.json`, confirms its reading, settles open points and records the screen spec, decisions and items with the `UI:` field (check)
- GDD: (none)
- Source: Director-Driven-Development T82

### T7 · /ui-design: screen capture, catalog and lint · done · L · agent
- Touches: framework/tools/ui_capture.sh (new), framework/tools/ui_capture.gd (new), framework/tools/ui_catalog.gd (new), framework/tools/ui_lint.gd (new), framework/tools/ui_overlay.gd (new), project/tools/ui_screens.gd (new), project/tools/ui_capture.cfg (new), framework/.godot-director/procedures/ui-design.md (new), framework/.claude/skills/ui-design/SKILL.md (new), framework/.godot-director/rules.md, framework/.claude/settings.json, install.sh, examples/market-day/tools/ui_screens.gd (new), examples/market-day/tools/ui_capture.cfg (new), examples/market-day/.gitignore, examples/market-day/.gitattributes, examples/market-day/scripts/ui/shop_screen.gd, selftest.sh, CHANGELOG.md
- Done when: `/ui-design list` prints the catalog and `capture` writes a PNG, element map, map image and lint file per catalog screen, state and size, exit 0, with nothing in `user://`, at any size whatever the monitor (check) · the lint catches each of its seven rules on a fixture screen built to break it and reports nothing on a clean one (test) · a screen whose setup errors fails with exit 1 while the others are captured, and capture exits 3 when it can't run (test) · the selftest checks the wiring and the install (test)
- GDD: (none)
- Source: Director-Driven-Development T81

### T6 · CI export and CD release · done · M · agent
- Touches: framework/.godot-director/procedures/release.md (new), framework/.claude/skills/release/SKILL.md (new), framework/.godot-director/templates/release-workflow.yml (new), framework/tools/release.sh (new), framework/.godot-director/rules.md, ONBOARDING.md, README.md, examples/scenarios.md, examples/market-day/.gitignore, framework/tools/release.sh (new), selftest.sh, CHANGELOG.md
- Done when: a GitHub Actions workflow template exports every preset on every change, uploads to UAT from main, and runs an optional production job behind a protected Environment (check) · `/release` runs the director's own upload command per export preset to UAT, and to production only when asked with the check passing (check) · `tools/release.sh` runs the commands `release.cfg` names, after checking the named secrets are set, and the selftest proves it without network, export templates or credentials (test) · onboarding asks for the commands and the secret names, and a skipped step adds a GDD open question and a gated setup item (check)
- GDD: (none)
- Source: Director-Driven-Development T31

### T5 · Export onboarding and /export · done · M · agent
- Touches: framework/.godot-director/procedures/export.md (new), framework/.claude/skills/export/SKILL.md (new), framework/.godot-director/rules.md, framework/.godot-director/tasks.md, framework/.godot-director/procedures/next-task.md, ONBOARDING.md, README.md, install.sh, examples/market-day/.gitignore, examples/scenarios.md, selftest.sh, CHANGELOG.md
- Done when: onboarding asks for the target platforms and where exports run (this machine, a build container, or a hosted service such as GitHub Actions), and a skipped step adds a GDD open question and a setup item that depends on it (check) · `/export` exports the presets headless into the gitignored `builds/` folder after checking the export templates (check) · the selftest checks the wiring and needs no export templates (test)
- GDD: (none)
- Source: Director-Driven-Development T19

### T4 · The manual install clones the latest release · done · XS · agent
- Touches: README.md, CHANGELOG.md
- Done when: the manual install option in README.md clones the release tag `v<version>` (or takes that release's source zip) instead of `main`, with the tag left as a placeholder found on the Releases page (check) · the manual upgrade wording still holds (check)
- GDD: (none)
- Source: Director-Driven-Development T65

### T3 · The install paths get the latest release · done · M · agent
- Touches: skills/godot-director/SKILL.md, .claude-plugin/marketplace.json, CLAUDE.md, README.md, selftest.sh, CHANGELOG.md
- Done when: the installer skill clones the release tag `v<version>` and the marketplace's plugin entry pins `v<version>`, and the skill's `metadata.version` agrees with `VERSION` (check) · `CLAUDE.md` › After any change lists every file that carries the version and says each release is tagged `v<version>` (check) · the selftest fails when the skill's version, the tag it clones or the marketplace's `ref` disagrees with `VERSION` (test)
- GDD: (none)
- Source: Director-Driven-Development T39

### B1 · The upgrade-file check ignores nested clones · done · S · agent · med
- Touches: framework/.githooks/pre-commit, framework/.godot-director/procedures/align.md, ONBOARDING.md, selftest.sh
- Repro: clone a repository into an ignored folder (such as `work/`), with no upgrade file present, then commit → expected: the commit goes ahead / actual: "unmerged Godot Director upgrade files (*.gdir-new) exist", listing the clone's folder, because `git ls-files` lists a nested repository in an ignored folder as a directory
- Found in: Director-Driven-Development B2
- GDD: (none)

### T1 · One commit model: a single task pauses for approval, a run commits without pausing · done · M · agent
- Touches: framework/.godot-director/procedures/next-task.md, framework/.godot-director/rules.md, framework/.claude/settings.json, framework/.claude/skills/next-task/SKILL.md, README.md, examples/scenarios.md, CHANGELOG.md
- Done when: `next-task.md` step 7 pauses for approval unless the human asked for a run ("grab tasks until you're blocked", "work through the queue", "the next N tasks"), and Several items also stops when the human declines a commit (check) · `git commit` is in `permissions.allow` and not in `permissions.ask` of `.claude/settings.json`, while `git push` still asks (check) · `rules.md`, the skill description, the README and the scenarios agree (check)
- GDD: (none)
- Source: Director-Driven-Development T35 (the shared commit model)

### T2 · The research assistant · done · M · agent
- Touches: framework/.godot-director/procedures/research.md (new), framework/.godot-director/research-domain.md (new), framework/.claude/agents/researcher.md (new), framework/.claude/skills/research/SKILL.md (new), framework/.claude/settings.json, framework/.godot-director/tasks.md, framework/.godot-director/rules.md, framework/.godot-director/procedures/next-task.md, framework/.godot-director/procedures/design.md, framework/.godot-director/procedures/align.md, project/TASKS.md (+R counter), project/design/research/README.md (new), examples/market-day/TASKS.md, examples/market-day/design/research/README.md (new), examples/scenarios.md, README.md, ONBOARDING.md, selftest.sh, CHANGELOG.md
- Done when: `research.md`, `research-domain.md`, the `researcher` subagent and the `/research` skill exist, and `rules.md`, `next-task.md`, `design.md`, `tasks.md`, the README and ONBOARDING.md name or use them (check) · the `researcher` has `Read, Grep, Glob, WebSearch, WebFetch` and no edit, write or shell tool, and `settings.json` allows web search and fetch (check) · `project/TASKS.md` carries an `R` counter on its `Next IDs` line, and the installer ships the procedure, the domain file, the note folder and the Claude adapter files, with `--tools none` too (check) · a commit with only a research note doesn't run the project check (check)
- GDD: (none)
- Source: Director-Driven-Development T42 (product/anchors/research.md)

## Notes
