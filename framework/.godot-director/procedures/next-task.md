<!-- Godot Director · framework-owned: replaced on upgrade. -->
# Next task

Pick the next ready item in `TASKS.md` (or the one the human named), have it built, prove it with the check, update the records, and commit it.

The build runs in a fresh context wherever the tool allows it; in Claude Code that's the `builder` subagent. This session keeps only the item, the builder's short report and the bookkeeping, so its context stays small however many items it gets through.

The request can be:
- empty: the next ready item;
- an item ID: that item;
- "the next N tasks" or "work through the queue": see Several items.

## 1. Pick
1. **Find items without reading the whole file.** `grep -n '^### ' TASKS.md` lists every heading; then read only the candidates.
2. **Is the tree clean?** If uncommitted changes from another item are in the working tree, don't start a new one. Ask the human whether to finish that item, commit it, or set it aside with `git stash push -- <paths>`.
3. **Does the check pass now?** Run `bash tools/check.sh --if-changed`; it's instant after a passing commit. If it fails, say so, and offer the items that would fix it. Build others only if the human says to, telling the builder the failure was there before.
4. **Items already `in-progress`:**
   - **Claimed today:** another session may be working on it right now, so ask before touching it.
   - **Older:** a session probably ended mid-task. Read its `Note:`, look at `git status` and `git diff`, then resume it or set it back to `todo`, and say which.
5. **Candidates** are `agent` items with status `todo` whose `Depends on` items are all `done`. IDs missing from TASKS.md are in `TASKS-archive.md`.
6. **Order:** `high` bugs first, then everything else in file order. File order is the human's priority, so don't reorder.
7. **Nothing ready?** Report what's blocked and on what (dependencies, `human` items, open questions), and stop.

## 2. Claim
Set the item to `in-progress YYYY-MM-DD` (today).

## 3. Build
- **In Claude Code,** give the `builder` subagent the item's ID and full text. Tell it to skip the final `bash tools/check.sh` call — step 4 runs the check from this session, and the pre-commit hook is the safety net. Run it in the foreground (`run_in_background: false`), and never run two builders at once: they would edit, and check, each other's files.
  1. Before starting it, create the file `.godot/godot-director/building`. Delete it when the report arrives; while it exists, the Stop hook leaves the half-built files alone.
  2. If AGENTS.md › Project rules turn on model sizing, read the per-size model from the mapping there (lines `- XS: …` through `- XL: …`) and pass `model: <id>` for this item's size. Otherwise use the session model.
- **Other tools:** follow `build.md` yourself, or in a subagent if your tool has them.
- **A rebuild** (after a failure, a blocked report or review findings) gets the previous report, anything the human said about the item, and word that the earlier attempt's edits are still in the tree to continue from.
- **Report `blocked`:** the report brings the question with options and a recommendation. Put it to the human.
  - If the answer is a design decision, record it following `design.md` › Record each decision before rebuilding. It's committed with the item.
  - Then rebuild, including the answer.
- **Report `failed`:**
  - An item built on a smaller-tier model gets one rebuild on the next-size model, and its size is annotated `S (escalated from XS)` or similar. An `XL` failure — already on the largest model — stops: give the human the check output without retrying.
  - Otherwise, add a `Note:` to the item and give the human the check output.
- **Report `failed: pre-existing`:** the failure was there before the build. Tell the human (see step 1).

## 4. Verify
Run `bash tools/check.sh --if-changed`. It passes at once if the files are as the builder left them. Don't re-read the changed files unless the report or the check gives a reason.

## 5. Update the records
From the report:
- Set the item to `done`, and delete its `Note:` if it has one.
- `Systems:` → AGENTS.md › Architecture.
- A milestone finished or changed → its row in TASKS.md › Milestones.
- `Found:` → new items, in the format in `.godot-director/tasks.md` (IDs from `Next IDs`, then bump it).
- Name any difference from `Touches` in your report to the human.

## 6. Review
Only when `rules.md` › Reviews and model size calls for one, judged from the item's size and the report's `API/saves:` line.
1. Make new files show up in the diff with `git add -N <new files>`, then write it: `git diff HEAD > .godot/godot-director/review.diff`.
2. Ask for a review following `review.md`; in Claude Code, that's the `reviewer` subagent. Give it the item ID, the builder's report and the check result.
3. Code findings that are in scope: rebuild with the findings. Record findings: fix them yourself. Everything else becomes new items.
4. Review again only if the fixes were substantial.

## 7. Commit and report
- **Commit** immediately after the check passes: one commit for the item's paths, including its records, as `rules.md` › Git describes. The pre-commit hook is the gate; no conversational approval pause is needed.
- **Report** in a few lines: what changed, the check result, placeholders added, and anything waiting on the human. Mention that the item's `(play)` outcomes, or a bug fix without a regression test, will be in the next function check.
- **After the commit,** the records hold everything about the item. A new item can start in a fresh session, or after `/clear` in Claude Code, without losing anything.

## Several items
Repeat steps 1–7 for each item, skipping `human` items as step 1 does. Report one line per finished item, and don't re-read files you've already seen. Stop early when:
- an item is blocked on something only the human can answer;
- a build fails.

End with the list of items done and what's next.

## Stopping partway through
If you must stop before the item is done, add `- Note: <where it stands, what's next>` to the item.

## Recurring warnings
After a passing check, `check: note: recurring warning (N×): <text>` lines may appear. Each names a warning that has appeared in every passing run for N consecutive checks. When you see one:

1. **Verify it's benign.** Search the codebase for the warning's source. Confirm it's genuinely harmless — engine noise, a resource the game creates at runtime, a known Godot limitation — and not masking a real problem. If it might be real, flag it to the human instead.
2. **Propose a suppression.** Tell the human the warning text and why it's harmless, and propose adding the matching substring to `tools/check.ignore` with a `#` comment explaining why. Wait for approval.
3. **Apply and commit as XS.** Add the line to `tools/check.ignore` and commit it as `chore: suppress recurring warning` — one warning per commit, no item ID needed unless the human asks for one.

Don't batch multiple suppressions in one commit. A suppression that the human rejects becomes a note to investigate the warning's source in a separate item.
