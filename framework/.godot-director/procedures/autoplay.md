<!-- Godot Director · framework-owned: replaced on upgrade. -->
# Autoplay

The game plays itself, and you read what happened (`/autoplay` in Claude Code). `bash tools/autoplay.sh` launches the real game through its main scene and plays a scenario through the game's adapter; `bash tools/log_review.sh` turns the play log into a review you can read without opening the game. Use it to playtest a change before the human does, to check what a person's session did ("I just played, check the logs"), and to replay a failure.

Requests (the words `run`, `all`, `review`, `player` and `replay` mean the same as their flags):
- `<scenario>` or `--all`: play it, review the run, report. No argument plays `smoke`.
- `--replay <run folder> [--until <step>]`: play a failed run again from its recording, review the replay, report whether it fails at the same step.
- `--player`: review the newest log a person played, with no run of yours. This is what "check the logs" means.
- `--latest` or a run folder: review a run that already exists.

## Who owns what
- **Framework-owned,** replaced on upgrade: `tools/autoplay.sh` and `autoplay.gd` (the driver and its invariants), `autoplay_adapter_base.gd`, `autoplay_catalog.gd`, `play_log_base.gd`, `log_review.sh` and `log_review.gd`. Don't edit them in a game.
- **Project-owned,** edited by you and the human: `tools/autoplay_adapter.gd` (how the game starts a run, which actions are legal, how each is performed, the state), `tools/autoplay_scenarios.gd` (the scenarios, with the required `smoke`), `tools/autoplay_invariants.gd` (the game's own always-true checks), `tools/play_log.gd` (the PlayLog autoload's hooks), `playtesting/signatures.tsv` (the record of problems seen; commit it) and the `[autoplay]` section of `tools/check.cfg`.
- **Written by a run** into `playtesting/autoplay/<scenario>-<seed>-<datetime>/` (gitignored): the play log's `.log` and `.jsonl`, `<step>-<reason>.png`, `.elements.json` and `.map.png` at the start, at every view change, snapshot, error, warning, invariant failure and progress block, and at the end, `repro.json` when something was found, and `review.md` and `findings.json` after the review.

## Run
1. Run `bash tools/autoplay.sh <scenario>` (or `--all`; `--list` names the scenarios). `--seed N` picks the run's seed: the same seed and scenario play the same run. It needs a display for screenshots and opens a small window; Godot is found as the check finds it.
2. Read the exit code:
   - `0` and a line ending `skipped:` means the game can't be played yet (no PlayLog autoload on the base, no main scene, or the adapter's `start_run()` is still the seed's). Say what the line says to wire, and stop; the check skips the same way and passes. A game whose item adds the first playable scene fills the adapter in that item.
   - `0` otherwise: a clean run. Still review it, for the delta and the coverage.
   - `1`: findings. Each is a `FAIL` line with its step, kind, an element map and a repro folder. Carry on to the review.
   - `3`: it couldn't run (no Godot, Godot older than 4.5, no display). On a machine with no display `--no-images` plays headless: the logs and the element maps are still written, the screenshots aren't. Say so, and that what you read is from the maps.
3. If a finding is the adapter's (`adapter`, `no-actions`, `drive`), the fix is in `tools/autoplay_adapter.gd` or in the view the action drives, not in the driver: `rules.md` › Every action is drivable.

## Review
1. Run `bash tools/log_review.sh <run folder>` (the folder is on the run's last line), or `--latest`, or `--player` for a person's log. It writes `review.md` and `findings.json` next to the log, and records each signature in `playtesting/signatures.tsv`. A player's review is written beside the player's log, in the game's real `user://logs/play`; nothing is copied or sent anywhere.
2. Read `review.md`:
   - the **timeline**: turns, the views each opened, the game's own events and the findings that came in each, with the first view at the top;
   - the **findings** by signature, worst first: kind, count, what it is, its first step, turn and log line, and the screenshot, element map, repro and replay command;
   - the **coverage**: the views opened against the catalog, the input actions pressed against every action the game defines, the adapter actions taken;
   - the **delta** against the previous run of the same scenario: new, gone and still present signatures.

## Look
1. At every finding, and at each view change when the item is a UI item, look at the screenshot the review names.
2. **If you can't view images,** read the element map beside it instead (`<step>-<reason>.elements.json`, named in the review). Each element has a number, its unique `id` when it has one, its kind and visible text, its `rect` in pixels and percent, whether it is `focusable` and its `focus_order`. From these you can say what is on screen, what overlaps, what sits outside the window, what has no focus and whether the text is there. Say plainly that you judged from the maps and not from pixels, and leave "does it look right" to the human: that is the part of a function check or playtest a machine can't judge.
3. For a finding with a script line (`at res://...:12 in _on_buy_pressed()`), read that code.

## Report
Keep it short: one table, then the lines under it.

| Signature | Kind | First step | What the screenshot or map shows | Likely cause | Repro |
|---|---|---|---|---|---|
| `sig-1a2b3c4d` | error | 1 | the shop after Buy; the Buy button is still enabled | `shop_screen.gd:41` frees a node that is null | `bash tools/autoplay.sh --replay <folder> --until 1` |

- The delta line: how many signatures are new, gone and still present.
- Coverage gaps worth a scenario step: views never opened, actions never taken or pressed.
- For `--player`: the build and the length of the session (the review's first lines), and that it has no screenshots: the timeline, the findings and the game's own events are what a person's log holds.
- For `--replay`: whether it failed at the same step, and the new run folder (it ends in `-replay`).

## File and confirm
- Each real bug becomes a `B` item once the human agrees (at once inside a `/next-task` run), in the format of `.godot-director/tasks.md`: `Repro:` the scenario, seed, step and signature, and the run folder and replay command; `Found in:` the review's path. Never edit `director/`.
- A fix is confirmed by playing the same scenario and seed again: the signature leaves the delta's "still present", and `bash tools/log_review.sh --check sig-xxxxxxxx` says whether it is in that log (exit 0 absent, 1 present).
- A finding the framework can't tell from intended behaviour (a block that is meant to last) is the human's call: show it, with the options, and don't file it.
