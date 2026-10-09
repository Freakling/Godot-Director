<!-- Godot Director · framework-owned: replaced on upgrade. -->
# Drift reset

A structured reset for when a Design Pillar has been read more than one way across the project, and patching each place would make it worse. It's the big counterpart to `align.md`: align often, reset when you have to. It fits when align keeps surfacing the same conflict, or one conflict spans several pillars.

**Only the human starts a reset.** Never run it on your own; `align.md` may recommend it.

The request can be:
- empty: steps 1-4, a new reset;
- `postmortem`: step 5, once the rebuild items are done.

## Ground rules
- **A branch of its own.** Before step 1, recommend running the reset on its own branch (`git switch -c reset-YYYY-MM-DD`) and wait for the human's answer. The rebuild items can be built on the same branch.
- **The reset folder** is `design/resets/YYYY-MM-DD/` (add `-2` for a second reset on the same day). Everything the reset writes goes there, except the GDD and `design/decisions.md` (step 3) and TASKS.md (steps 4 and 5). Never delete or rewrite a file in a reset folder; a correction is a new section in it.
- **No application code.** Nothing in this procedure changes code, scenes or data. The rebuild goes through `next-task.md`.
- **Human-owned areas** (the rows AGENTS.md › Ownership gives to the human, such as art, audio and tunable values) are never rewritten. A tunable value that is part of the drift becomes a design call, and the human edits the `.tres`.
- **Git.** No destructive commands (`rules.md` › Git). Commit each step's files after the human approves, as `docs: drift reset <step> (YYYY-MM-DD)`.

## 1. Analyse as built
Describe how the game actually behaves today, not how the GDD says it should. This step only writes `as-built.md`.
1. Split the project into areas: one per row in AGENTS.md › Architecture, plus one for the screens. Merge small rows so there are no more than about six.
2. Have each area analysed by a read-only reviewer in a fresh context. In Claude Code, that's the `reviewer` subagent, given the area's name, its files and this step. Other tools: do it yourself, one area at a time, or in a subagent if your tool has them. Each analysis reports, with `file:line` references:
   - what the area does: its rules in plain words, and the values it reads;
   - where each rule lives: in a rule class, or in a screen or scene script;
   - rules the check wouldn't catch: logic in screens that is neither randomness nor an autoload write, rules without a test, values hard-coded instead of read from a `.tres`;
   - anything that disagrees with the GDD section it implements, quoting both.
3. Write the reports to `as-built.md`, one section per area, keeping the references.

## 2. Map interpretations
This step only writes `interpretations.md`. For each pillar in GDD › Design Pillars:
1. Find where it's implemented, using `as-built.md`, and how it actually plays, using the playtest reports and function checks in `playtesting/`. Quote the scores and remarks that bear on it.
2. List each reading of the pillar you find, and where it lives: files, GDD sections, decisions.
3. Classify the pillar:
   - **consistent:** one reading everywhere;
   - **divergent:** readings that don't exclude each other but pull the game different ways;
   - **contradictory:** readings that can't both hold.
4. Write `interpretations.md`: one section per pillar with its readings, evidence and class. Then list conflicts that span several pillars, and GDD rules that serve no pillar.

Present the summary to the human: one line per pillar with its class, then the divergent and contradictory ones in detail. Commit steps 1 and 2 together.

## 3. Rewrite the design
1. Copy `design/gdd.md` to `gdd-before.md` in the reset folder.
2. For every divergent or contradictory pillar, and every cross-pillar conflict, raise a design call following `design.md` › For each question. Each of the 2-4 options names which current reading it keeps and what would have to be rebuilt. Recommend one, and invite the human's own answer. The pillar itself may be what changes; ask which gives way.
3. Record each answer following `design.md` › Record each decision, steps 1-3, with `from: drift reset YYYY-MM-DD`. Only what the human chose goes into `design/decisions.md`. TASKS.md waits for step 4.
4. Once every call is answered, reread the revised GDD as a whole for text that still carries a rejected reading, and fix it. Show the human the diff against `gdd-before.md`.
5. If a hook or the tool blocks writing the GDD, write the draft to `gdd-proposed.md` in the reset folder and ask the human to apply it. Never get around the hook.

Commit after the human approves the revised GDD.

## 4. Plan the rebuild
1. Compare the approved GDD with `as-built.md`. Each difference is work: code that follows a rejected reading, a missing rule, a rule in the wrong place.
2. Turn the work into TASKS.md items in the format in `.godot-director/tasks.md`, planned in stages as `design.md` › Record each decision describes. Each item's `Touches` names every file it may change, and its `GDD:` names the revised heading. A rule the check wouldn't catch (step 1) gets a `(test)` outcome where it can have one.
3. Write `plan.md`: the item IDs in build order, each with the difference from `as-built.md` it removes.
4. Commit TASKS.md and `plan.md`, then hand over: the rebuild runs through `next-task.md` as usual.

## 5. Postmortem
Run with `postmortem`, for the latest reset folder without a `postmortem.md`. Every item in its `plan.md` must be `done` (in TASKS.md or `TASKS-archive.md`); if one isn't, list those and stop.
1. For each divergent or contradictory entry in `interpretations.md`, check the rebuilt code against the chosen reading, with a reviewer as in step 1, limited to the files the plan's items touched. Mark it resolved, partly resolved or still there, with references.
2. For each drift, ask whether it could have been caught automatically. A game can add:
   - a test in `tests/` that pins the rule;
   - a regular expression in `tools/check.cfg` › `[screens] forbidden` that screens must not contain.

   Propose each one as a design call: what it catches, the exact test or pattern, and the false positives it might cause. Directing scales by turning repeated judgment into checks. Approved ones become TASKS.md items. A check neither form can express is written down as a request for Godot Director.
3. Write `postmortem.md`: the state of each drift, the checks approved and the items created, and what still needs the human.
4. Commit after the human approves. Merging the reset branch is the human's call.
