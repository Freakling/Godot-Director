# Tasks

This is Godot Director's own work queue, for developing the framework itself. It is fed by [Director-Driven Development](https://github.com/Freakling/Director-Driven-Development)'s orchestrator through pull requests. `project/TASKS.md` is a different file: the template shipped to adopters, which never receives these items.

Item format: `framework/.godot-director/tasks.md`. Queue order is priority; reorder by moving items.

**Next IDs:** T36 · B3 · R1

## Queue

### T35 · The check and the pre-commit hook scan for secrets when gitleaks is installed · done · M · agent
- Touches: framework/tools/check.sh, framework/.githooks/pre-commit, project/.gitleaks.toml (new), project/tools/check.cfg (+[gitleaks] min-version), examples/market-day/.gitleaks.toml (new), ONBOARDING.md, README.md, selftest.sh, CHANGELOG.md
- Done when: with gitleaks installed, a credential in a game (a store upload key, an API token in a script or a config file) fails the check, which lists it as file:line with the value redacted, and is blocked by the pre-commit hook on every commit, whatever is staged (check) · without gitleaks both print a note that names the install and go on, and a gitleaks that is installed but too old or can't scan makes the check exit 3 (check) · `selftest.sh` proves the check and the hook with a secret assembled at run time, with a stand-in gitleaks and, when it is installed, the real one (check)
- GDD: (none)
- Source: Director-Driven-Development T247

### T34 · The guard and the Read rules keep the agent out of the gh, git credential and SSH stores · done · S · agent
- Touches: framework/.claude/hooks/guard-git.sh, framework/.claude/settings.json, selftest.sh, CHANGELOG.md
- Done when: the settings template denies the Read tool `~/.ssh/**`, `~/.git-credentials`, `~/.config/git/credentials`, `~/.config/gh/**` and `~/AppData/Roaming/GitHub CLI/**` (check) · the guard hook blocks shell reads of those stores (`cat`, `head`, `tail`, `less`, `more` and `strings`, however the path is written) and the commands that print a stored credential (`gh auth token`, `gh auth status -t`, `git credential fill` or `get`), for every Bash command, not only git ones (check) · `selftest.sh` covers each block and each pass case through the guard, and checks the five Read rules (check)
- GDD: (none)
- Source: Director-Driven-Development T241

### T33 · The guard blocks the git flags that write or read any file · done · M · agent
- Touches: framework/.claude/hooks/guard-git.sh, framework/.claude/settings.json, selftest.sh, CHANGELOG.md
- Done when: the guard hook blocks the git flags that write a file (`--output`), read a file outside the repository (`--no-index`, `commit -F` and `--file`, a `git diff` of a path outside it) or run a configured command (`--ext-diff`), and passes the plain forms the procedures use (`git commit -F -`, `git commit -m "..."`) (check) · the settings template denies `Bash(git *--output*)`, `Bash(git *--no-index*)`, `Bash(git *--ext-diff*)` and `Bash(git commit *--file*)` (check) · `selftest.sh` feeds the hook each case, and fails when the template allows a wildcard git rule (`git diff *`, `git log *`, `git show *`, `git stash *`, `git commit *`) without all four deny rules (check)
- GDD: (none)
- Source: Director-Driven-Development T234

### T32 · The check names a Godot process that exits without an error line · done · S · agent
- Touches: framework/tools/check.sh, selftest.sh, CHANGELOG.md
- Done when: when the import pass, the load pass, a test group or the layout lint exits non-zero (a crash such as a segmentation fault included) and its log has no error line the scan reports, the check prints one line naming that process, its exit status and its log before the FAIL, instead of a FAIL with no reason; the selftest covers a load pass and a test group that exit non-zero with a clean log (test)
- GDD: (none)
- Source: Director-Driven-Development T218
- Found in T190: the load pass's Godot process crashed after its report once in 12 runs on The Guildkeeper, and the check failed with no error line.

### T31 · The check plays its autoplay scenarios beside the tests · done · M · agent
- Touches: framework/tools/check.sh, framework/tools/autoplay.sh, project/tools/check.cfg, selftest.sh, CHANGELOG.md
- Done when: with `[autoplay] check_in_check` on, a parallel run starts the autoplay scenarios (smoke and those `enforce` names) as soon as the import and load pass are clean, in their own process beside the test jobs (one fewer test job, so the CPU count isn't exceeded), and their result joins the report with exit codes unchanged; a serial run plays them after the tests as before (test) · measured on The Guildkeeper's scratch copy before and after (check)
- GDD: (none)
- Source: Director-Driven-Development T190
- Measured on The Guildkeeper (12 CPUs, 394 test files, smoke enforced, alternating runs): 161, 166 and 170 s with the scenarios after the tests (12 test processes plus the load pass, then autoplay alone for about 22 s); 141 and 142 s beside them (11 test processes plus the load pass, autoplay from about 112 s to 134 s). A third run beside them ended FAIL at 142 s when the load pass's Godot process crashed (a segmentation fault) after its report, so autoplay was not played.

### T30 · A sweep of autoplay scenarios plays side by side, and the builder doesn't play smoke twice · done · M · agent
- Touches: framework/tools/autoplay.sh, framework/.godot-director/procedures/build.md, framework/.godot-director/procedures/autoplay.md, selftest.sh, CHANGELOG.md
- Done when: `bash tools/autoplay.sh <scenario> <scenario> ...` (and `--all`) runs the scenarios in separate Godot processes at the same time under the one lock and one import check, each with its own user dir, log and run folder, capped at the CPU count, and reports each scenario's result with exit codes unchanged; one scenario behaves as today (test) · `build.md` has the builder play the scenarios the item names once, after the tests pass, in one call, and leave out `smoke` when `tools/check.cfg` › `[autoplay]` has the check play it (check) · measured on The Guildkeeper's scratch copy: a sweep of quest_job, quest_hold, quest_controls and smoke (check)
- GDD: (none)
- Source: Director-Driven-Development T197
- Measured on The Guildkeeper (12 CPUs, windowed runs): the sweep of quest_job, quest_hold, quest_controls and smoke took 462 s as four calls and 124 s as one call.

### T29 · The check can balance its jobs by last run's timings and split a slow test file by test method, opt-in · done · L · agent
- Touches: framework/tools/check.sh, framework/tools/check.gd, project/tools/check.cfg, framework/.godot-director/rules.md, README.md, selftest.sh, CHANGELOG.md
- Done when: the parallel run deals test files longest first by each file's time from the last run (kept in .godot/godot-director/test-times.tsv, unknown files first), sized from its whole-run time so the split count stays stable, opt-in by `[tests] balance` (file order stays the default), each to the job with the least total; a file whose last time is over `[tests] split_over` seconds (default 0, off) runs as shards of its test methods across the jobs, each shard in its own process, its results merged as one; a file with `# gdir: no-split` in its first ten lines runs whole, and `split_over = 0` turns splitting off (test) · on The Guildkeeper's scratch copy the full run's wall time and its slowest job are recorded before and after (check)
- GDD: (none)
- Source: Director-Driven-Development T189
- Measured on The Guildkeeper (254 test files, 12 jobs): 376 s with file order; 411 s and 284 s with balanced dealing and splitting, before the opt-in decision. The second balanced run also failed on engine errors from tests that depend on run order, and with the heavy files started together each ran slower. So file order stays the default and balancing is opt-in, to be measured per machine.

### T28 · The check skips the import pass when no imported file changed · done · S · agent
- Touches: framework/tools/check.sh, framework/tools/autoplay.sh, framework/tools/ui_capture.sh, selftest.sh, CHANGELOG.md
- Done when: the check, autoplay and capture skip the import pass, saying so in one line, when the fingerprint matches the one stored after the last pass that exited 0 and .godot/imported exists; the fingerprint covers the files Godot imports (everything but scripts, scenes, resources read directly, .cfg, .md, .uid and .godot/, plus project.godot), the path and class_name, extends and @icon lines of every script (so a body-only edit skips), and the scene and shader paths; a changed or new asset, a new or changed class declaration, a fresh clone or `check.sh --import` runs it; the shared lines agree across the three scripts, and the selftest covers the skip, the forced pass and a new asset (test) · CHANGELOG carries the entry (check)
- GDD: (none)
- Source: Director-Driven-Development T191

### T27 · The Bash guard blocks hangs: empty Python heredocs, unbounded waits and Godot runs without a time limit · done · M · agent
- Touches: framework/.claude/hooks/guard-git.sh, framework/.claude/settings.json, framework/.godot-director/rules.md, selftest.sh, CHANGELOG.md
- Done when: the guard, also run for Monitor, blocks an empty Python heredoc, an until or while loop with sleep without `timeout` of 280 seconds or less, a loop reading a background command's output without its end marker, a direct Godot run without such a `timeout`, and a sleep over 280 seconds, and passes the forms that work (check) · `rules.md` says to give long commands a time limit, run long checks in the background and never probe with an empty heredoc (check) · a CHANGELOG entry under Unreleased (check)
- GDD: (none)
- Source: Director-Driven-Development T163

### T26 · A grey box can be dragged to re-arrange a screen · done · M · agent
- Touches: framework/tools/ui_drawing.gd, framework/.godot-director/procedures/ui-design.md, project/design/ui/README.md, examples/market-day/design/ui/README.md, tests/ui-drawing, selftest.sh, CHANGELOG.md
- Done when: the starter's grey boxes are unlocked; the reader reads one moved or resized by more than 2 px as a `keep` box named after its element, with `from` and `n`, and skips untouched, hidden and deleted ones (test) · the README says to drag the grey box (check)
- GDD: (none)
- Source: Director-Driven-Development T180

### T25 · The screen-design README is organised by feature · done · M · agent
- Touches: project/design/ui/README.md, examples/market-day/design/ui/README.md, CHANGELOG.md
- Done when: `design/ui/README.md` has one section per feature (workflow, what a capture gives you, boxes, colours, containment arrows and notes, patch or replace, re-arranging, other states and sizes, processing and verifying, Excalidraw, files), says only what the tools do, and the example's copy is identical (check)
- GDD: (none)
- Source: Director-Driven-Development T177

### T24 · Every subagent launch passes its model explicitly · done · S · agent
- Touches: framework/.godot-director/procedures/next-task.md, framework/.godot-director/rules.md, selftest.sh, CHANGELOG.md
- Done when: next-task.md sets the model explicitly on every subagent launch (the builder, the reviewer, the researcher and an escalated retry), from the sizing mapping for the item's size, and passes the session model where the mapping has no entry or model sizing is off, so no launch inherits the session's model; rules.md states the rule (test) · the selftest checks that wording (test) · following AGENTS.md › Project rules for framework work; VERSION untouched (check)
- GDD: (none)
- Source: Director-Driven-Development T150

### T23 · The check times every test file and runs the suite in parallel · done · L · agent
- Touches: framework/tools/check.gd, framework/tools/check.sh, project/tools/check.cfg, README.md, framework/.godot-director/rules.md, selftest.sh, CHANGELOG.md
- Done when: every run logs each test file's time and ends with a slowest-files summary; `--jobs N` (default from the CPU count, settable in check.cfg) splits the test files across N headless Godot processes, each in file order with its own log and its own timeout, and merges the results into one report with exit codes 0/1/3 unchanged; `--if-changed` and `--fingerprint` keep working; a run that hits the timeout says so and exits 3; new check.cfg keys have defaults and an upgrade keeps existing settings; the docs say tests must isolate their autoload and user:// state and recommend one git worktree per parallel building session; CHANGELOG carries the upgrade notes (check) · the selftest covers the times and summary, the split, the timeout path and the cfg defaults (test) · following AGENTS.md › Project rules for framework work; VERSION untouched (check)
- GDD: (none)
- Source: Director-Driven-Development T157

### T22 · The README starts with writing your own game design document · done · S · agent
- Touches: README.md, project/design/director-gdd.md, examples/market-day/design/director-gdd.md, selftest.sh, CHANGELOG.md
- Done when: the README's how-to-use section opens with a Start here step before Install, linking the template at the raw `v<version>` URL (check) · the template's header carries the same link (check) · the selftest checks both links against VERSION (test) · following AGENTS.md › Project rules for framework work; VERSION untouched (check)
- GDD: (none)
- Source: Director-Driven-Development T154

### T21 · An install from a non-release source marks itself unreleased · done · S · agent
- Touches: install.sh, selftest.sh, CHANGELOG.md
- Done when: the manifest records the source commit, and an install from a source whose CHANGELOG.md has entries under Unreleased records `<version> + unreleased (<commit>)` and says so in its closing lines (test) · an install from a release records the plain version (test) · an upgrade from an unreleased install reads the old version without the suffix (test) · `bash selftest.sh <Godot 4.5+>` passes (check) · following AGENTS.md › Project rules for framework work; VERSION untouched (check)
- GDD: (none)
- Source: Director-Driven-Development T136

### T20 · Autoplay's no-focus invariant looks under the adapter's focus roots · done · M · agent
- Touches: framework/tools/autoplay_adapter_base.gd, framework/tools/autoplay.gd, framework/tools/autoplay_catalog.gd, project/tools/autoplay_adapter.gd, project/tools/autoplay_scenarios.gd, examples/market-day/tools/autoplay_adapter.gd, framework/.godot-director/procedures/autoplay.md, framework/.godot-director/rules.md, README.md, selftest.sh, CHANGELOG.md
- Done when: `focus_roots()` on the adapter base returns the view node by default, the no-focus invariant accepts a focus owner under any root, counts a SubViewport root's own focus owner, finds focusable controls under any root, skips the check on an empty list, and names the roots in its finding; `_pick` with every weight 0 picks nothing and smoke carries on to the progress action; the seeds and the example carry the hook and the weight-0 note; the procedure, rules.md and README describe it; the selftest covers the five cases in the spec with the existing no-focus case still passing (check) · following AGENTS.md › Project rules for framework work; VERSION untouched (check)
- GDD: (none)
- Source: Director-Driven-Development T138

### T19 · /autoplay and the workflow hooks · done · M · agent
- Touches: framework/.godot-director/procedures/autoplay.md (new), framework/.claude/skills/autoplay/SKILL.md (new), framework/.godot-director/rules.md, tasks.md, procedures/next-task.md, build.md, review.md, function-check.md, playtest.md, align.md, framework/playtesting/README.md, framework/tools/check.sh, autoplay.sh, autoplay.gd, autoplay_adapter_base.gd, play_log_base.gd, project/tools/check.cfg, project/tools/autoplay_adapter.gd, examples/market-day/tools/check.cfg, framework/.claude/settings.json, install.sh, README.md, ONBOARDING.md, tests/play-log/selftest_play_log.gd, selftest.sh, CHANGELOG.md
- Done when: the procedure and skill run, review and replay as spec section 3.4 says, every named procedure uses autoplay as the spec says, the check runs smoke headless under `[autoplay] check_in_check` with `enforce` (on for new projects, off on upgrade, missing keys read as off), a new project gets everything wired so that `bash tools/autoplay.sh smoke` exits 0 in a fresh project made by the skill (a clean skip that names what to wire) and an upgrade gets the seeds plus a TASKS item (spec section 5), and the docs say what is framework-owned and what is project-owned and how an assistant without image viewing reviews from element maps (spec section 6) (check) · the play log names the current view when a run starts without a view change, so a run's log and review always carry its first view (check) · the whole feature is one open pull request, each stage one commit, with the selftest passing (check)
- GDD: (none)
- Source: Director-Driven-Development T131

### T18 · The dev menu base and its onboarding step · done · M · agent
- Touches: framework/tools/dev_menu_base.gd (new), project/tools/dev_menu.gd (new), framework/.godot-director/rules.md, ONBOARDING.md, README.md, project/AGENTS.md, examples/market-day/tools/dev_menu.gd (new), examples/market-day/tests/test_dev_menu.gd (new), examples/market-day/scripts/autoload/run_state.gd, examples/market-day/project.godot, examples/market-day/AGENTS.md, examples/market-day/.gitignore, examples/market-day/.gitattributes, tests/dev-menu/selftest_dev_menu.gd (new), install.sh, selftest.sh, CHANGELOG.md
- Done when: a framework-owned dev menu base (one tab per system through public APIs and debug hooks, an inspector for hidden values, a Log tab from the play log's tail, debug builds only) ships with a project seed, and onboarding asks whether the director wants a dev menu in the game and how to enable it (a setting, in game, or a command-line flag at start), recording the answer in the project's rules (check)
- GDD: (none)
- Source: Director-Driven-Development T130

### T17 · Log review with stable signatures · done · M · agent
- Touches: framework/tools/log_review.sh (new), framework/tools/log_review.gd (new), project/playtesting/signatures.tsv (new), examples/market-day/playtesting/signatures.tsv (new), examples/market-day/.gitignore, examples/market-day/.gitattributes, tests/log-review/signature-cases.tsv (new), install.sh, selftest.sh, CHANGELOG.md
- Done when: `bash tools/log_review.sh [<run>|--latest|--player]` writes review.md and findings.json with the timeline, the findings by signature (the normalisation from the spec, with a fixture carrying signatures.py's cases), coverage and the delta against the previous run, and `--check sig-xxxx` confirms a fix from signatures.tsv (check)
- GDD: (none)
- Source: Director-Driven-Development T129

### T16 · Autoplay drives the real game · done · L · agent
- Touches: framework/tools/autoplay.sh (new), framework/tools/autoplay.gd (new), framework/tools/autoplay_adapter_base.gd (new), framework/tools/autoplay_catalog.gd (new), framework/tools/ui_lint.gd, framework/tools/ui_capture.gd, project/tools/autoplay_adapter.gd (new), project/tools/autoplay_scenarios.gd (new), project/tools/autoplay_invariants.gd (new), install.sh, examples/market-day/tools/autoplay_adapter.gd (new), examples/market-day/tools/autoplay_scenarios.gd (new), examples/market-day/tools/autoplay_invariants.gd (new), examples/market-day/.gitignore, examples/market-day/.gitattributes, selftest.sh, CHANGELOG.md
- Done when: `bash tools/autoplay.sh <scenario|--all>` launches the real game through the main scene with the autoplay meta, drives it through the adapter by real input and API calls from scripted and strategy scenarios, requires a smoke scenario, writes screenshots and element maps at the spec's moments into `playtesting/autoplay/<run>/`, checks the framework invariants and the project's, writes a replayable repro on every failure, replays with `--replay`, and is deterministic from a seed (check) · the three planted bugs (a script error in a view's button handler, a progress block that never clears, a view with no default focus) are found with a signature-ready line, step, screenshot and repro, and `--replay` reproduces each at the same step (check)
- GDD: (none)
- Source: Director-Driven-Development T128

### T15 · The play log base and the logging rules · done · L · agent
- Touches: framework/tools/play_log_base.gd (new), project/tools/play_log.gd (new), framework/.godot-director/rules.md, framework/tools/check.sh, framework/tools/check.gd, framework/tools/setup-clone.sh, framework/tools/ui_capture.sh, framework/.godot-director/procedures/ui-design.md, framework/.godot-director/templates/release-workflow.yml, install.sh, examples/market-day/project.godot, examples/market-day/AGENTS.md, examples/market-day/.gitignore, examples/market-day/.gitattributes, examples/market-day/tools/play_log.gd (new), examples/market-day/scripts/autoload/run_state.gd, examples/market-day/scripts/ui/shop_screen.gd, examples/market-day/tests/test_play_log.gd (new), tests/play-log/selftest_play_log.gd (new), skills/godot-director/SKILL.md, README.md, ONBOARDING.md, PRIVACY.md, CLAUDE.md, selftest.sh, CHANGELOG.md
- Done when: the play log base writes the per-run text log and its JSONL twin with stable event ids, the session header, startup buffering, flush per line, the engine Logger, the tail, `start_capture()` for tests and scrubbing, writes nothing under the check, and has the project hooks `_session_extras()`, `_build_snapshot()`, `log_snapshot()` and `progress_block_reason()` (check) · `rules.md` has the logging, drivability, agent-visible state, seeded randomness and privacy rules (check) · the minimum Godot is 4.5 everywhere it's stated and checked, and the selftest proves the check fails on a compile error in a view that only loads when it opens (check)
- GDD: (none)
- Source: Director-Driven-Development T127

### T13 · The human-written GDD · done · S · agent
- Touches: project/design/director-gdd.md (new), examples/market-day/design/director-gdd.md (new), ONBOARDING.md, README.md, selftest.sh, CHANGELOG.md
- Done when: every project has the director's GDD template as a seed (`design/director-gdd.md`) for the human to fill in, and the example carries it too (check) · onboarding offers it before the design interview, as an alternative or an addition to the chat interview, with a word on why it helps, and reads a filled one first for a new or an existing game to build the initial assessment and the design records, marking what it took `(from your document)` and what it inferred `(inferred, please confirm)` (check) · the README mentions it (check) · the selftest fails when the seed, the example copy or onboarding's wiring is missing, and checks a new game and an upgrade receive the seed (check)
- GDD: (none)
- Source: Director-Driven-Development T88

### T12 · align checks the GDD against reality · done · S · agent
- Touches: framework/.godot-director/procedures/align.md, CHANGELOG.md
- Done when: align's item 6 is "Brief against reality", in place of the Decisions spot-check: it reads the whole GDD, checks every statement of state against the built game, the done items and the latest releases, and checks every decision line since the last `docs: align` commit one by one (check)
- GDD: (none)
- Source: Director-Driven-Development T94

## Queue

### T14 · The repository's own queue has a research counter · done · XS · agent
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
