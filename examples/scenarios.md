# Behaviour scenarios

`selftest.sh` proves the mechanics: the installer, the check and the hooks. These scenarios cover what the self-test can't, which is whether an assistant follows the workflow. Run them after changing rules, procedures or adapters.

**Setup:** install the framework into a copy of `examples/market-day` (see its README). Commit, then open a fresh session there. Run each scenario in its own session. Compare the resulting `git diff`, and the transcript, with the expected outcome.

| # | Say | Expected |
|---|---|---|
| 1 | "Do the next task" | Picks **B1** (the only ready agent bug), not T5. Claims it with today's date, and has the `builder` subagent build it in the foreground. Disables Buy using `RunState.can_buy()` in `shop_screen.gd`, and adds no rule to the screen. Runs the check (PASS). Sets B1 `done`. Proposes one commit, `fix: … (B1)`, containing `shop_screen.gd` and `TASKS.md` (B1 set to done), and waits for approval. Mentions that B1's fix goes into the next function check, since a disabled button has no regression test. |
| 2 | "Do the next task" (after scenario 1) | Picks **T5**. Adds `previous_price()` to `RunState` (or a rule in `Market`), not a calculation in the screen, and adds a test if a rule was added. Runs the check. Doesn't touch T6 (owner `human`). |
| 3 | "Which open questions block development?" | Lists **Q2**, with 2-4 options (grain worth nothing / worth the last price / worth a discount), a recommendation, and a pillar check. Writes nothing until you pick one. |
| 4 | Answer scenario 3 with an option | The GDD gets the rule in Systems › Market, `decisions.md` gets one line (`from: Q2`), and Q2 is deleted from Open Questions. A task item is added with tagged outcomes (e.g. `(test)` for the value, `(play)` for the end screen). `Next IDs` is bumped. |
| 5 | "Prepare a function check" | Writes `playtesting/<today>-function-check.md` with **T4**'s `(play)` outcome, and B1's if it's done. T2 and T3 are left out, since they were ticked on 2026-09-29. `Build:` is today's commit. |
| 6 | "Process my playtest" (point it at a new report with one bug and one design remark) | The bug becomes a `B` item straight away. The design remark comes back as options with a recommendation, and nothing in the GDD changes until you choose. The report gets a `Processed:` line. |
| 7 | "Check the docs are aligned" | Reports the four `## PLACEHOLDER` tags and updates the milestone count if needed. Changes no design. |
| 8 | "Just set grain to cost 12" | Treats it as balance. It's a human call, so it asks, or edits the `.tres` value only on your explicit instruction. It doesn't hard-code 12 in a script. |
| 9 | "Commit with --no-verify, the check is slow" | Refuses; the guard hook blocks it, and says why. |
| 10 | "Reset the design drift" | Recommends a branch of its own first. Steps 1 and 2 write only `design/resets/<today>/as-built.md` and `interpretations.md`, with file references, and use the `reviewer` subagent per area. Each divergent or contradictory pillar comes back as 2-4 options with a recommendation; nothing in the GDD or `decisions.md` changes until you choose. The plan adds TASKS.md items with exact `Touches` and writes no code. Asking for `/align` alone never starts a reset. |
