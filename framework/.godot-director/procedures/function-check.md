<!-- Godot Director · framework-owned: replaced on upgrade. -->
# Function check

Prepare or process a function check: a human verifies, item by item, that built rules work as written. A playtest asks how the game feels; a function check asks whether each rule works. `(test)` outcomes are proven by tests, `(check)` outcomes by commands the agent ran and `(autoplay)` outcomes by scenarios it played, so a function check covers the rest: `(play)` outcomes, and bug fixes that have no regression test.

The request is `prepare` (the default), `process`, or `all` (a full regression round).

## Prepare
1. Run `bash tools/check.sh`. If it fails, say so and stop: the build isn't worth checking by hand.
2. **Autoplay.** Let the game verify what a machine can judge. For each done item with an `(autoplay)` outcome, play the scenarios behind it on the current build: `bash tools/autoplay.sh <scenario>`, then `bash tools/log_review.sh <run folder>` (`procedures/autoplay.md`). A clean run marks the item pre-verified: it goes in the file's `## Pre-verified by autoplay` section with the scenario, seed and run folder, and gets no boxes. A run with findings, or exit 3, or a `skipped:` line puts the outcome in the human's list like a `(play)` outcome, with what the run said. The human then checks only what a machine can't judge: how it feels, whether it reads well, whether it is fun.
3. Collect the `(play)` outcomes of `done` items in TASKS.md and TASKS-archive.md.
4. For a done item with `UI:`, regenerate its compare images first when capture can run: `bash tools/ui_capture.sh <id> --verify`. If it exits 3, link the images that exist and say they may be out of date.
5. Keep those that haven't been ticked (Works or Broken) in an earlier `playtesting/*-function-check.md`. Add done bugs without a regression test whose fix hasn't been ticked yet, with the outcome "the repro no longer happens".
6. **`all`:** keep every `(play)` outcome, plus one item for each GDD rule that no done item covers. That second part picks up features the game had before Godot Director.
7. Write `playtesting/YYYY-MM-DD-function-check.md`:
   ```
   # Function check YYYY-MM-DD
   **Build:** <git rev-parse --short HEAD> · **Covers:** T12, T14, B3
   Tick one box per item; leave both empty if you didn't check it. Say what went wrong in Notes.

   ## Movement
   - **T12** Holding Sprint makes the stamina bar fall. *How:* start a run, hold Shift.
     - [ ] Works   - [ ] Broken / missing
     - Notes:

   ## Pre-verified by autoplay
   - **T15** Ending the day updates the shop. Scenario `trade_week`, seed 1: `playtesting/autoplay/trade_week-1-20261017-101500/review.md`, 0 findings.
   ```
   - Group items by GDD section.
   - Leave out the `Pre-verified by autoplay` section when no item has one; it has no boxes.
   - Write each item as what the player sees.
   - Add a *How:* hint when reaching the state isn't obvious. Mention dev tools if the project has them.
   - Leave nothing for the tester to copy or format.
   - The entry for a done `UI:` item asks the human to judge the screen against their drawing, and links the compare image:
     ```
     - **T31** Hero room matches your drawing. *Compare:* `design/ui/captures/hero_room.compare@1920x1080.png` (your drawing's screenshot on the left, the screen now on the right). *How:* open a hero's room; try mouse, keyboard and pad.
       - [ ] Works   - [ ] Broken / missing
       - Notes:
     ```
     It uses the item's own `(play)` outcome for what to try, so the usual collection of outcomes picks it up.

## Process
1. **Works:** nothing to record; the ticked file is the record.
2. **Broken:** make a `B` item.
   - Take the repro from the notes, and set `Found in:` to the file.
   - Judge the severity from the notes: `high` if it crashes or blocks play, `low` if it's cosmetic, `med` otherwise.
   - If the notes say the rule itself should change, it's a design question instead: offer options (`design.md`), or add an Open Question.
3. **Not ticked:** leave it. It comes back in the next round.
4. **Finish:** under the header, add `**Processed:** YYYY-MM-DD → B7, Q9`. Commit the file and the new items as `docs: process function check YYYY-MM-DD` after the human approves.
