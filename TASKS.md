# Tasks

This is Godot Director's own work queue, for developing the framework itself. It is fed by [Director-Driven Development](https://github.com/Freakling/Director-Driven-Development)'s orchestrator through pull requests. `project/TASKS.md` is a different file: the template shipped to adopters, which never receives these items.

Item format: `framework/.godot-director/tasks.md`. Queue order is priority; reorder by moving items.

**Next IDs:** T6 · B2

## Queue

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
