<!-- Godot Director · framework-owned: replaced on upgrade. -->
# Playtesting

Two kinds of session feed the game's design and its bug list:

| | Asks | You fill in | The assistant turns it into |
|---|---|---|---|
| **Playtest** | How does it play and feel? | `TEMPLATE.md`: scores, answers, bugs, free comments | bug items, design proposals for you to decide, score trends |
| **Function check** | Does each built rule work as written? | a generated checklist: tick Works or Broken | bug items, and design questions when a rule itself seems wrong |

Rules that can be tested automatically are proven by `bash tools/check.sh` on every change. A function check covers only what needs a person: feel, visuals, input and UI flow.

## Playtest
1. Say "new playtest" (in Claude Code also `/playtest new`). This creates `playtesting/YYYY-MM-DD-playtest.md` from `TEMPLATE.md`, with the build filled in.
2. Play, then fill it in. Skip loops you didn't reach. A score with no comment is still useful, and the free-format section matters as much as the scores.
3. Say "process my playtest". Bugs become bug items, and design findings come back as options with a recommendation; nothing is written until you approve a summary of all of it. Scores are compared with earlier reports that use the same statement.

Each loop in the template has one fixed scored statement, so scores stay comparable across builds. If you reword a statement, it starts a new series.

In a game that uses user stories (AGENTS.md › Project rules), both kinds of report also list the stories behind what was built since the last one: tick **Still right** or **Needs a change** for each, and say what should change in Notes. A story you tick Still right is dated as confirmed; one that needs a change is rewritten for you to confirm.

## Function check
1. Say "prepare a function check" (in Claude Code also `/function-check`). This writes `playtesting/YYYY-MM-DD-function-check.md` with everything built since the last check that needs a human eye. Say "function check all" for a full regression round.
2. For each item, tick **Works** or **Broken / missing**, and say what went wrong in Notes. Leave both boxes empty for anything you didn't check; it comes back next time.
3. Say "process the function check". Broken items become bugs. A note saying the rule itself should change becomes a design question for you. Nothing is written until you approve a summary of all of it.

## Autoplay and your session's log
The game writes a play log of every session. After you play, say "I just played, check the logs" (in Claude Code also `/autoplay --player`): the assistant reviews your newest log into a timeline, findings with a signature, coverage, and what changed since the last run, and tells you what it found. `/autoplay` plays the game by itself in the same way, so the assistant can check a change before your playtest. A processed playtest gets that review attached as a Machine review, and a function check lists what autoplay already verified as pre-verified, so you tick only what a machine can't judge.

## Files
- `TEMPLATE.md`: the report template. It's yours, with one section per core gameplay loop.
- `YYYY-MM-DD-playtest.md` and `YYYY-MM-DD-function-check.md`: one file per session. Once processed, a file gets a `Processed:` line listing the bugs, tasks and questions it produced, and the stories it corrected.
