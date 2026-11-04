<!-- Godot Director · framework-owned: replaced on upgrade. -->
# Design session

Brainstorm a topic, rank and answer open design questions, or change how part of the game works. Also turn user stories on or off, and validate them in a game that uses them (User stories, below), or harvest a prototype (Harvest a prototype, below). Write down only what the human decides. Your job is to make the human's decisions fast and well informed, never to make them.

## Prepare
- Read GDD › Design Pillars, GDD › Open Questions, the GDD sections the topic touches, and the related lines in `design/decisions.md`. Don't re-propose something decided against there without saying what has changed since.
- With user stories on (AGENTS.md › Project rules), read the stories in `design/user-stories.md` under the pillars and systems the topic touches (`grep -n "^## " design/user-stories.md` lists them).
- List `design/research/` for notes on the topic. A note whose Verified as of date is recent enough for its claims is evidence you can use; research only what has changed since.
- **Ranking the open questions** (no topic, or "which questions block development?"): order them by what they unblock in TASKS.md:
  1. a question blocking a ready item;
  2. one that would cause rework;
  3. one that gates a placeholder value;
  4. long-term questions.

  Give a one-line reason for each position.

## Brief the human

After preparing, present what you found before the first question:
- **Relevant GDD:** quote the lines that bear directly on the topic, or a one-sentence summary per section if nothing verbatim is at stake.
- **User stories** (with them on): the stories the topic touches, by ID and text.
- **Related decisions:** any entries from `design/decisions.md` that touch this topic - date, decision, and why. Skip unrelated ones.
- **Research on file:** notes in `design/research/` on the topic - path, conclusion, and Verified as of date.
- **Scope:** the questions you plan to address, in ranked order if you ranked them.

Then ask: "Anything I've missed, or shall we begin?"

## For each question
1. **Research first when the options depend on facts you don't have,** or when the human asks for it, such as how other games handle this, what a plugin's licence allows, or what a store requires.
   - A single fact one source settles (a version, a licence, a limit) you may check yourself. Anything larger goes to the `researcher`, as `research.md` › Starting research describes, so this session's context stays small.
   - The result is a note for `design/research/` and a done `R<n>` item, held in the conversation with the answers until the human approves the summary. Tell the human where the researcher's assumptions are, since those are the first thing to check.
   - The researcher's recommendation is one option, shown with its reason like any other. It informs; the human decides.
2. Offer 2-4 concrete options. For each: how it plays, what it would take to build (which systems in AGENTS.md › Architecture), and which pillar it serves or strains. With user stories on, name the stories it serves, and draft the new or changed stories it needs (User stories, below), so the human confirms them with the option.
3. Recommend one, with a one-line reason.
4. Wait for the human. Hold the answer in the conversation: nothing is recorded yet, and an answered part is not recorded by itself. If you had to interpret the answer, state your reading and ask them to confirm it.

## Summary and approval
When every question of the session is answered, show one summary of everything the session will write, and wait. Nothing is written before the human approves it.
1. **List it.** For each file, what it gets, as it will read:
   - the GDD text written or replaced;
   - each line for `design/decisions.md`, word for word;
   - the GDD › Open Questions removed or added;
   - each TASKS.md item, new or changed, in full;
   - with user stories on, each user story with its ID and its Confirmed date, or `unconfirmed`;
   - the research notes and `R<n>` items.
2. **Ask:** "Approve this summary, or tell me what to change?"
3. **Re-open on any change.** A chat message or an "Other" answer, before the summary or after it, is a scope change or a modification: re-open the options it touches, research a new fact if the options now depend on one, then restart the session from the first affected question or continue, and show a new summary. Only a yes to the summary as shown approves it.

## Record each decision in one change
Write these only after the human has approved the summary, as the summary shows them.
1. **GDD:** write the rule into its section as the current design, replacing any text it supersedes. A new area gets a new subsection.
2. **`design/decisions.md`:** append one line in the format given at the top of that file. When the decision followed research, end the `why` with the note's path, as in `why: <reason> (research: design/research/<note>.md)`, so later sessions reuse the evidence instead of redoing it.
3. **GDD › Open Questions:** delete the answered question. Follow-up questions become new `Q<n>` (bump `Next`).
4. **`design/user-stories.md`** (with user stories on): the chosen option's stories. Each one the human confirmed is dated today: a new one gets the next ID from the header (then bump it), a changed one is rewritten in place, and a dropped one is deleted. A drafted story they didn't answer goes in as `unconfirmed`.
5. **TASKS.md:** add or change the items the decision creates, in the format in `.godot-director/tasks.md`. Plan a big rework in stages: first move rules out of screens, then rework the systems, then rebuild the UI.
   - Give each new item a Size, `Depends on`, `Touches`, `Done when` with tags, a `GDD:` heading and, with user stories on, its `Stories:`.
   - A `done` item the decision changes gets a new item; don't reopen it.
   - Leave `in-progress` items alone and tell the human about them, since another session may be working on them.
   - Suggest reorders; don't make them.
6. **Numbers** stay placeholders. Say what a value is for and how it should feel; the human tunes it in the `.tres`.
7. **Pillars:** if an idea contradicts a Design Pillar, stop and ask which gives way, the pillar or the idea.
8. **Layout:** where things sit on a screen goes to `ui-design.md`. A design session settles what a screen is for, not where its elements are.

## Finish
- Write everything the approved summary lists and commit it as one change, `docs: <summary>`, with a body listing the decisions. The approval of the summary is the approval to commit (`rules.md` › Git). The session's research notes and `R<n>` items go in the same commit. A design session doesn't edit code or data.
- Say what was decided, what's still open, and the next most useful question.
- After the commit, suggest `/clear` (or starting a fresh session) before the next topic. The GDD, decisions.md, the stories and TASKS.md hold everything; the conversation history no longer adds value and only grows the context.

## User stories
User stories are optional: a game uses them when AGENTS.md › Project rules says `User stories: on`. With `User stories: off`, or no such line, skip every step about stories in the procedures, and this section except Turning them on, which runs when the human asks for it: no item needs `Stories:`, and nothing asks about them.

`design/user-stories.md` says whom the game is for, and why each feature is built: the value for each role in one paragraph, the roles, and one table of stories per Design Pillar or system (its heading in the GDD), each with its ID, the story and the date the human confirmed it. They tell you why each thing is built, so the work stays aligned with the design. You draft stories; only the human confirms them.
- **A story** is one thing a role does in the game and why, in the role's words: "As a player I <do something>, so <why>". Roles other than the player are there when the game has them, such as a streamer or a modder. A story names no scene, node or implementation. Its role is one in Roles; a new role is added there, and its value paragraph with it.
- **New and changed stories** come from a design (For each question), from turning them on, or from a feature item that has none. A new one gets the next ID from the file's header, which you then bump; IDs are never reused. Until the human confirms it, its Confirmed column says `unconfirmed`.
- **A feature item with no story** (no `Stories:` line, or `(none)` while it changes what a player can do): draft the story it serves, add it `unconfirmed`, and set the item's `Stories:`. Name it in your report so the human can confirm it; a run of several items doesn't stop for it.
- **Confirmed** is the date the human last confirmed the story as it reads now: in a design, a validation, a playtest or a function check (Still right? in a playtest or function check, below).

### Turning them on
Onboarding asks once whether the game uses them; the human can also ask later ("turn on user stories"). Turning them on is a write like any other. The summary lists the `User stories: on` line for AGENTS.md › Project rules, and with it the stories file, the GDD link and the items' `Stories:` lines. The switch is set only after the approval, so draft steps 1 to 4 in the conversation first. Write nothing until the human approves a summary of all of it (`design.md` › Summary and approval); a chat message or an "Other" answer before then re-opens the options.
1. **The rule.** Write `- User stories: on` in AGENTS.md › Project rules in this exact format, since `tools/stories.sh` reads it, replacing a `- User stories: off` line.
2. **The file.** Copy `.godot-director/templates/user-stories.md` to `design/user-stories.md`, delete its first line (the template's header) and its comment's last sentence (about the worked example), replace the worked example and its `{{PROJECT_NAME}}` with the game's own, in the form User stories (above) gives, and set Next ID to the number after the game's last story. If the game already has its own `design/user-stories.md`, keep its stories and add what the template has and it lacks: the Next ID and Last validated line, the value and Roles sections, and a Confirmed column (`unconfirmed` until the human confirms each story). Its IDs are renumbered to `US-<n>` only if the human agrees.
   - **A new game:** draft them from the design interview: a role for each kind of player the pitch names, the value for each role in one paragraph, and a story for each thing they do in GDD › Core Loop, under the pillar or system it serves. Put them to the human with the GDD, as drafts to confirm, correct or drop, and hold their answers in the conversation. Each one they confirm gets today's date; the rest stay `unconfirmed`. When they've gone through them, set Last validated to today and `git rev-parse --short HEAD` (the date alone while the repository has no commit yet); if they'd rather do it later, leave it `never`, and `/next-task` proposes it.
   - **A game already underway** (an existing game, or stories turned on later): write them from the GDD and the code: a story for each thing a role can do today, not a plan. Every story is `unconfirmed` and Last validated stays `never`. Under the first paragraph, add `US-1 to US-<n> were written from the code on <date>, before the game kept user stories.`, so align leaves that range out of the stories no item serves. Offer to go through them with the human now (Validate the stories); otherwise `/next-task` proposes it.
3. **The GDD** links the file: under GDD › Design Pillars, the line ``Why each feature is built, and for whom: `design/user-stories.md`.``
4. **TASKS.md:** give each item that isn't done its `Stories:`. A feature item whose story isn't in the file gets one drafted, `unconfirmed`; `(none)` is only for foundation, tooling and infrastructure. Done items and `TASKS-archive.md` stay as they are.
5. **Commit** AGENTS.md, the file, the GDD and TASKS.md as `docs: turn on user stories`; the approval of the summary is the approval to commit. During onboarding they join onboarding's summary and go into the install commit instead.

**Turning them off:** the human asks. The summary lists the `User stories: off` line for AGENTS.md › Project rules, and you write it only after the human approves. Write nothing until the human approves a summary of all of it (`design.md` › Summary and approval); a chat message or an "Other" answer before then re-opens the options. Nothing reads the file or the `Stories:` lines after that; delete them only if the human asks, and the summary lists the deletions too.

### Validate the stories
`next-task.md` proposes this when `bash tools/stories.sh --due` says it's due: never validated, or `tools/check.cfg` › `[stories] every` built items (10 by default) since the commit on the file's Last validated line. It also runs on request.
1. **Collect.** The stories the items built since that commit serve: `git log --format=%s <commit>..HEAD` lists the items (subjects ending in `(T<n>)` or `(B<n>)`, or that and a squash merge's ` (#<pr>)`), and their `Stories:` lines name the stories. When the commit isn't in this history, or the line names none, use `git log --format=%s --since=<date>` instead. Add every story still `unconfirmed`. With Last validated `never`, take every story.
2. **Ask.** Show each story with the items that serve it, grouped by pillar or system, and ask the human to confirm, correct or drop it:
   - **confirm:** its Confirmed becomes today's date;
   - **correct:** write the new wording and date it. If you had to interpret the answer, show your reading and keep it `unconfirmed` until they confirm it. A correction that means the built game is wrong is a design question: offer options as For each question says, or add an Open Question;
   - **drop:** delete its row. A `todo` item that names it goes to the human, who decides whether it's still needed.

   A story the human doesn't answer stays as it is; an unconfirmed one comes back next time. Hold the answers in the conversation: nothing is written yet.
3. **Record.** Write nothing until the human approves a summary of all of it (`design.md` › Summary and approval); a chat message or an "Other" answer before then re-opens the options. The summary lists the stories changed, their Confirmed dates, and the Last validated line. Then set the header's Last validated to today and `git rev-parse --short HEAD`, as in ``**Last validated:** 2026-11-14 at `4e1f0c2` ``. Commit `design/user-stories.md` (and any items or Open Questions it changed) as `docs: validate the user stories`; the approval of the summary is the approval to commit.

### Still right? in a playtest or function check
A playtest (`playtest.md`) and a function check (`function-check.md`) put the stories behind what they cover to the human, word for word from `design/user-stories.md`, each with its own ticks: `- [ ] Still right   - [ ] Needs a change`. Processing the report collects the ticks, and the procedure's summary lists them (`playtest.md`, `function-check.md`); they are written only after the human approves it:
- **Still right:** its Confirmed becomes the report's date.
- **Needs a change:** rewrite the story from the notes and date it. If you had to interpret the notes, show your reading to the human and keep it `unconfirmed` until they confirm it. If the notes say the built game should change too, it's a design question: offer options (For each question), or add an Open Question.
- **Not ticked:** leave it as it is.

List the corrected stories in the report's `Processed:` line, and commit `design/user-stories.md` with the report.

## Harvest a prototype
`prototype.md` › Harvest brings a prototype here: its notes (`PROTOTYPE.md`: what was tried, how it felt, what to keep) and its diff against main. It shows how a change feels; it decides nothing, and its code is never merged or cherry-picked.
1. **Context.** Show the notes in the human's words, then what the prototype changes as a player would feel it, area by area from the diff rather than the code, with the GDD sections, Design Pillars, stories (with user stories on) and decisions it touches, as Prepare says. Name what it skipped that a real build needs: tests, the rule classes and tunables in `rules.md` › Architecture defaults, the play log lines, drivable actions and autoplay scenarios.
2. **Options,** as For each question says. They are usually to build it as tried, a variant the notes point to, or to leave it, and each says what it would take to build from main and which pillar it serves or strains.
3. **Record** what the human chooses, as Record each decision in one change says, naming the prototype in each: the decision's `why` ends with `(prototype: proto/<name>)`; the GDD changes are written as the current design; with user stories on, a story it adds or changes gets the line `US-<n> came from the prototype proto/<name> on <date>.` under its section's table; and each item gets `- Prototype: proto/<name>` (`.godot-director/tasks.md`). A number the prototype tuned stays a placeholder in the items (Record step 6): say how it felt, and the human tunes it in the `.tres`. The items are built from main like any other, with the check, autoplay and reviews. Write nothing until the human approves a summary of all of it (`design.md` › Summary and approval); a chat message or an "Other" answer before then re-opens the options. The summary lists the decisions, stories and items, each naming the prototype. Nothing is filed without the human's answer: a part they don't answer stays out, and leaving the prototype files nothing. Unlike Record step 4, a drafted story the human doesn't answer stays out too. Write and commit what the approved summary lists as Finish says, as `docs: harvest the <name> prototype`.
