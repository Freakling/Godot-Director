<!-- Godot Director · framework-owned: replaced on upgrade. -->
# Align

A consistency pass across the GDD, decisions, TASKS.md, AGENTS.md, project settings and code. Check everything below, fix what's mechanical, and list what needs the human, with a recommendation for each. Never change design.

1. **Placeholders.** No `{{…}}` left in AGENTS.md, TASKS.md, `design/` or `playtesting/TEMPLATE.md` (`git grep -n "{{" -- AGENTS.md TASKS.md design playtesting/TEMPLATE.md`). The template's loop sections may wait until the core loop is decided, but only if an item for filling them exists.
2. **Entry files.**
   - AGENTS.md points to `.godot-director/rules.md`.
   - In Claude Code, CLAUDE.md contains `@AGENTS.md`.
   - No `*.gdir-new` files are left unmerged: `git ls-files -o -i --exclude-standard -- '*.gdir-new' | grep '\.gdir-new$'` (the grep drops nested clones, which `ls-files` lists as directories).
3. **Items.**
   - IDs are unique and below `Next IDs`, which has a counter for each of `T`, `B` and `R` (add `· R1` to a line that lacks one), and every `Depends on` exists, in TASKS.md or the archive.
   - No `done` item depends on a `todo` one.
   - Every `agent` item has a Size, `Touches`, tagged `Done when` outcomes (or a Repro, for bugs; a research item has a `Question:` and an `Informs:` instead of both) and a `GDD:` value. That value is an existing heading, or `(none)` for items that aren't about the design.
   - Every `Q<n>` an item that isn't done names, in `Done when` or `Informs:`, is still in Open Questions. If it's been answered, update the item.
   - Every done research item has a note in `design/research/` whose second line starts with its ID (`grep -l "^R3 · " design/research/*.md`).
   - Items follow `.godot-director/tasks.md`.
   - Report `in-progress` items claimed before today.
4. **Coverage.** Every rule in the GDD is either built (a done item), planned (a todo item), or reported to the human as a gap. Only report the gaps; the human decides which ones become items.
5. **Architecture.**
   - Every autoload in `project.godot`, and every folder of rule classes, has a row in AGENTS.md › Architecture.
   - Every row points at something that exists.
   - List screens that depend on other screens, and systems that depend on screens.
   - Every file listed under `tools/check.cfg` › `[screens] known` has an open item that removes it from the list.
6. **Brief against reality.** For this step only, read the whole GDD, not sections by heading.
   - Read `design/gdd.md` from its first line to its last.
   - For every statement of state, check it against what exists: the built game, the done items (`TASKS.md` and `TASKS-archive.md`) and, where the project tracks them, the latest releases (the game's exports and their UAT or production uploads, which `release.md` records in its report). A statement of state is a section marked later or planned, a count, a list of what exists, a line saying work waits on something, and "once X exists". Fix a stale statement as mechanical drift when the fact is settled (the item is done, the page exists). Report it to the human when the fix is a design call.
   - Check every line added to `design/decisions.md` since the last `docs: align` commit (`git log --grep="^docs: align"` for the last one; all lines if there is none) against the GDD, one by one and not a sample. Each is reflected in it, and no older text contradicts it.
   - Report what was fixed and what needs the human, naming each stale statement, so the next align can tell a repeat.
7. **Balance placeholders.** Count them with `git grep -n "## PLACEHOLDER" -- "*.gd"`, and write the number into the Content & balance milestone row.
8. **Setup.**
   - `bash tools/check.sh` passes and prints no `note:` about typing or hooks.
   - The `.gitignore` and `.gitattributes` lines that install.sh adds are still there (among them `/design/ui/captures/` and `/playtesting/autoplay/`). If any are missing, rerun the installer.
9. **Screens** (skip it when the game has no `tools/ui_screens.gd`). Report what is missing; none of it fails the pass.
   - `bash tools/ui_capture.sh --missing` lists the screen scenes (a root script in `tools/check.cfg` › `[screens] dirs`) with no catalog entry and not in `tools/ui_capture.cfg` › `[capture] skip`. With no screen folders set it says so, and nothing is listed.
   - Every `design/ui/<screen>.md` names a scene or catalog entry that exists, and every unique name its Layout table lists (`%GearList`) is in that scene or in the script that builds it.
   - Every `director/ui/<screen>.excalidraw` has a spec whose recorded sha1 matches the file (`sha1sum`, or `shasum` on macOS). A newer drawing: report "drawing changed since it was processed".
   - Every item's `UI:` points at an existing spec.
   - On an upgrade, this is the check that lists the game's screens the catalog doesn't cover yet.
10. **Logging and autoplay** (skip it when the game has no `tools/autoplay_adapter.gd`). Report what is missing; none of it fails the pass.
    - **Logging gaps.** Signals that carry a player action or a turn step (`git grep -n "^signal " -- "*.gd"`) whose script never writes a play-log line (`PlayLog.log_event`) and isn't connected to one: each is an action or step the log can't show (`rules.md` › Everything is logged).
    - **Scenario gaps.** Play `bash tools/autoplay.sh --all` and `bash tools/log_review.sh --latest` (or read a review from today), then list its Coverage section: the catalog views no scenario opens, the `Controls` actions no scenario presses and the actions the adapter never offers (`rules.md` › Every action is drivable). A `skipped:` run means the adapter isn't filled in yet: list that instead.
11. **Report.** Say what you fixed and what needs the human. Recommend a drift reset (`drift-reset.md`) when a conflict comes back that `design/decisions.md` shows was already settled, or one conflict involves several Design Pillars; patching those one place at a time makes them worse. Only the human starts one. Commit the fixes as `docs: align` after the human approves; during onboarding they go into the install commit instead.
