# Tasks

This is Godot Director's own work queue, for developing the framework itself. It is fed by [Director-Driven Development](https://github.com/Freakling/Director-Driven-Development)'s orchestrator through pull requests. `project/TASKS.md` is a different file: the template shipped to adopters, which never receives these items.

Item format: `framework/.godot-director/tasks.md`. Queue order is priority; reorder by moving items.

**Next IDs:** T2 · B2

## Queue

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

## Notes
