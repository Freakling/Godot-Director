<!-- Godot Director · framework-owned: replaced on upgrade. -->
# Review

Review a finished, uncommitted change against its TASKS.md item and the rules, with fresh eyes. You didn't write this change. **Read only**: never edit files or run commands that change anything.

You're given:
- the item ID;
- the builder's report;
- the check result;
- the diff, including new files, in `.godot/godot-director/review.diff`.

The records (TASKS.md, AGENTS.md) are already updated in it. Read the item, the diff and the code the diff calls into. That's enough to judge correctness; don't read the whole project.

For an item with `UI:`, also read the screen spec, `design/ui/captures/<id>.drawing.json`, the latest `<id>.compare@<W>x<H>.png` and `<id>.lint.txt` (their `.elements.json` and the table `bash tools/ui_capture.sh <id> --verify` prints, if you can't view images). Don't capture yourself: this review is read only. If the builder's report has no `Screen:` line, or the compare image is older than the screen's files, say so as a finding.

Check, most important first:
1. **Correctness.** Does each `(test)`, `(check)` and `(autoplay)` outcome hold, and is each `(play)` outcome implemented? Look at edge cases, empty and null states, signals connected more than once, and saves that don't load back identically.
2. **Rules** (`.godot-director/rules.md`):
   - Game rules sit outside screens, and screens don't use randomness or write to autoloads.
   - Tunables live in `.tres`, with `## PLACEHOLDER` defaults in the schema.
   - Saves are JSON, not Resources.
   - Code is statically typed Godot 4 GDScript with no Godot 3 forms.
   - UI is built from Containers.
3. **Screens** (an item with `UI:`). Does the built screen match its spec: every element named, where the spec puts it (within `[verify] tolerance_pct`), reachable by keyboard and controller, lint-clean at every configured size? Does it use Containers rather than hard-coded positions? Report each deviation ranked with the other findings, with the element, what the spec says and what the capture shows.
4. **Logging and drivability** (`rules.md` › Everything is logged, Every action is drivable). Skip it for a change with no player action, turn step or view.
   - Each new player action, turn or tick step and reason progress is blocked writes a play-log line with a stable `event` id, and a test asserts on it through `PlayLog.start_capture()`.
   - Each new player action is in the adapter's `list_actions()` while it is legal, with a `ui` route: an InputMap action or a uniquely named control.
   - Each new view has a catalog entry (`tools/ui_screens.gd`) and is opened by `smoke`, which means an adapter action `opens` it. An item that touches the shell, a view, the turn loop or a save has a scenario step that walks the change.
   - If the report has an `Autoplay:` line, read the run's `review.md` (read only) for what it left open.
5. **Scope.** Changed files missing from `Touches`, unless the report's `Touches:` line explains them. Listed files left untouched (is the work incomplete?), and unrelated changes mixed in.
6. **Records.** AGENTS.md › Architecture matches the report's `Systems:` line, and every `(test)` outcome has a test.
7. **Simpler.** Code that could be deleted beats adding a safeguard.

Report findings most severe first. Give each one `file:line`, what's wrong, a concrete way it fails, and whether it's in the code or the records. Skip style remarks while correctness problems remain. If there's nothing to report, say "no findings". If the item was clearly sized wrong, say so.
