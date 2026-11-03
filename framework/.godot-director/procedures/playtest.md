<!-- Godot Director · framework-owned: replaced on upgrade. -->
# Playtest

Start a playtest report, or process a filled-in one into bug items, design proposals and tasks, comparing its scores with earlier reports. In a game that uses user stories, it also asks whether the stories behind what was built are still right.

If the human didn't say which, list the reports under `playtesting/` that have no `Processed:` line and ask whether to process one or start a new one.

## New report
Copy `playtesting/TEMPLATE.md` to `playtesting/YYYY-MM-DD-playtest.md` (add `-2`, `-3` for more reports on the same day). Fill in `Date:`, and `Build:` with `git rev-parse --short HEAD`. The human fills in the rest after playing.

With user stories on (AGENTS.md › Project rules), add a `## User stories` section at the end: the stories the items built since the previous report serve, collected as `design.md` › Validate the stories › Collect does, from the previous report's `Build:` commit, or its `Date:` when that commit isn't in this history (every story when there's no earlier report). Leave out a story that's no longer in `design/user-stories.md`. Group them by pillar or system, each with its ticks as `design.md` › Still right? in a playtest or function check gives, and one `Notes:` line for the section. Leave the section out when it would list none. The human ticks them after playing, with how the game felt still fresh.

## Process a report
Only when the human asks. Read the whole report first and work out what it leads to. Write nothing until the human approves a summary of all of it (`design.md` › Summary and approval); a chat message or an "Other" answer before then re-opens the options. The summary lists the `B` items, the story rewrites and ticks (with user stories on), the records of the design findings (the GDD text, decision lines, Open Questions and items), the Machine review section, and the Processed line.

1. Read the whole report, including Free-Format Comments. They matter as much as the scores.
2. **Machine review.** Let the game say what it did on that build, beside what the human felt. If the report's `Build:` is this working tree's build, or a commit you can check out in a worktree (`git worktree add ../game-<build> <build>`, then `bash tools/setup-clone.sh` there), run `bash tools/autoplay.sh smoke` on it and `bash tools/log_review.sh <run folder>` (`procedures/autoplay.md`). If the human played on this machine, also run `bash tools/log_review.sh --player`: it reviews the log of their session. Draft what the reviews found as a `## Machine review` section for the end of the report, written with the rest: the build, the scenario and seed, the run folder, and the findings table (signature, kind, first step). Note a finding beside the Bugs entry it matches; one with no entry becomes a `B` item, as in step 4. Skip this when the game has no adapter (`skipped:`) or no log, and say so.
3. **Scores.** Build a small table: each scored statement, with its score in this report and in earlier reports. Match statements by exact wording; changed wording starts a new series. Add one line on anything notable.
4. **Bugs.** Every entry under Bugs becomes a `B` item for TASKS.md (format: `.godot-director/tasks.md`), since it needs no decision: steps → expected / actual, severity as reported, `Found in:` the file and, with user stories on, `Stories:` (the story whose behaviour it restores, or `(none)`). Check "might be a bug" entries against the GDD. A clear defect becomes a `B` item; anything else is a design finding.
5. **Design findings.** Group them. For each group, propose what could change as 2-4 options with a recommendation, following `design.md`. Hold the answers in the conversation. What the human chooses becomes the GDD text, `design/decisions.md` lines (with the file as the source) and TASKS.md items, all for the summary. Anything left unresolved becomes a new Open Question.
6. **Stories** (with user stories on): collect each story's ticks as `design.md` › Still right? in a playtest or function check says. The summary lists the Confirmed dates and the rewritten stories for `design/user-stories.md`.
7. **Mark it.** Draft the line to add under the report's header, `**Processed:** YYYY-MM-DD → B4, B5, T20, Q7, US-2`, listing what it produced and the corrected stories.
8. **Finish.** Show the summary and wait. Once the human approves it, write everything it lists, the `Processed:` line included, and commit it as `docs: process playtest <file>`; the approval of the summary is the approval to commit.
