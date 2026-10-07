<!-- Godot Director · framework-owned: replaced on upgrade. -->
# Playtest

Start a playtest report, or process a filled-in one into bug items, design proposals and tasks, comparing its scores with earlier reports.

If the human didn't say which, list the reports under `playtesting/` that have no `Processed:` line and ask whether to process one or start a new one.

## New report
Copy `playtesting/TEMPLATE.md` to `playtesting/YYYY-MM-DD-playtest.md` (add `-2`, `-3` for more reports on the same day). Fill in `Date:`, and `Build:` with `git rev-parse --short HEAD`. The human fills in the rest after playing.

## Process a report
Only when the human asks.

1. Read the whole report, including Free-Format Comments. They matter as much as the scores.
2. **Scores.** Build a small table: each scored statement, with its score in this report and in earlier reports. Match statements by exact wording; changed wording starts a new series. Add one line on anything notable.
3. **Bugs.** Every entry under Bugs becomes a `B` item in TASKS.md straight away (format: `.godot-director/tasks.md`), since it needs no decision: steps → expected / actual, severity as reported, `Found in:` the file. Check "might be a bug" entries against the GDD. A clear defect becomes a `B` item; anything else is a design finding.
4. **Design findings.** Group them. For each group, propose what could change as 2-4 options with a recommendation, following `design.md`. Record only what the human chooses: the GDD, `design/decisions.md` (with the file as the source), and TASKS.md items. Anything left unresolved becomes a new Open Question.
5. **Mark it.** Under the report's header, add `**Processed:** YYYY-MM-DD → B4, B5, T20, Q7`, listing what it produced.
6. **Finish.** Summarise, then commit as `docs: process playtest <file>` after the human approves.
