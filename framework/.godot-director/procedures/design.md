<!-- Godot Director · framework-owned: replaced on upgrade. -->
# Design session

Brainstorm a topic, rank and answer open design questions, or change how part of the game works. Write down only what the human decides. Your job is to make the human's decisions fast and well informed, never to make them.

## Prepare
- Read GDD › Design Pillars, GDD › Open Questions, the GDD sections the topic touches, and the related lines in `design/decisions.md`. Don't re-propose something decided against there without saying what has changed since.
- **Ranking the open questions** (no topic, or "which questions block development?"): order them by what they unblock in TASKS.md:
  1. a question blocking a ready item;
  2. one that would cause rework;
  3. one that gates a placeholder value;
  4. long-term questions.

  Give a one-line reason for each position.

## Brief the human

After preparing, present what you found before the first question:
- **Relevant GDD:** quote the lines that bear directly on the topic, or a one-sentence summary per section if nothing verbatim is at stake.
- **Related decisions:** any entries from `design/decisions.md` that touch this topic - date, decision, and why. Skip unrelated ones.
- **Scope:** the questions you plan to address, in ranked order if you ranked them.

Then ask: "Anything I've missed, or shall we begin?"

## For each question
1. Offer 2-4 concrete options. For each: how it plays, what it would take to build (which systems in AGENTS.md › Architecture), and which pillar it serves or strains.
2. Recommend one, with a one-line reason.
3. Wait for the human. If they answer only part, record only that part. If you had to interpret the answer, write down your reading and ask them to confirm it.

## Record each decision in one change
1. **GDD:** write the rule into its section as the current design, replacing any text it supersedes. A new area gets a new subsection.
2. **`design/decisions.md`:** append one line in the format given at the top of that file.
3. **GDD › Open Questions:** delete the answered question. Follow-up questions become new `Q<n>` (bump `Next`).
4. **TASKS.md:** add or change the items the decision creates, in the format in `.godot-director/tasks.md`. Plan a big rework in stages: first move rules out of screens, then rework the systems, then rebuild the UI.
   - Give each new item a Size, `Depends on`, `Touches`, `Done when` with tags, and a `GDD:` heading.
   - A `done` item the decision changes gets a new item; don't reopen it.
   - Leave `in-progress` items alone and tell the human about them, since another session may be working on them.
   - Suggest reorders; don't make them.
5. **Numbers** stay placeholders. Say what a value is for and how it should feel; the human tunes it in the `.tres`.
6. **Pillars:** if an idea contradicts a Design Pillar, stop and ask which gives way, the pillar or the idea.

## Finish
- Summarise what was decided, what's still open, and the next most useful question.
- Commit the design files as `docs: <summary>`, with a body listing the decisions, after the human approves (see `rules.md` › Git). A design session doesn't edit code or data.
- After the commit, suggest `/clear` (or starting a fresh session) before the next topic. The GDD, decisions.md and TASKS.md hold everything; the conversation history no longer adds value and only grows the context.
