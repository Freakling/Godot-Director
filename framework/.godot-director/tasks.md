<!-- Godot Director · framework-owned: replaced on upgrade. -->
# TASKS.md items

Read this before adding or editing an item.

```
### T12 · Stamina drains while sprinting · todo · M · agent
- Depends on: T10
- Touches: scripts/systems/stamina.gd, data/stamina.tres (+drain_rate)
- Done when: drains drain_rate per second (test) · the stamina bar falls while sprinting (play)
- GDD: Movement › Sprint
```

- **Heading.** It reads `ID · title · status · size · owner`, and a bug adds `· high|med|low`. New IDs (`T<n>`, `B<n>`, `R<n>`) come from the `Next IDs` line, which you then bump. If the line has no `R` counter yet, add `· R1`. IDs are never reused.
- **Status.** `todo`, `in-progress YYYY-MM-DD` (the claim date) or `done`. "Ready" isn't stored: a `todo` item is ready when everything in `Depends on` is `done`. `Depends on` may also name an open question (`Q<n>`): that part is met once the question is no longer in GDD › Open Questions.
- **Size.**
  - `XS`: a single value, label, or line. No logic change and no new tests.
  - `S`: 1-2 files, data, text, or a clear bug.
  - `M`: 1-2 systems, or a feature that follows an established pattern.
  - `L`: 3+ systems, new architecture, a save format, or a bug without a repro.
  - `XL`: a cross-cutting refactor, a complete subsystem redesign, or a change that touches most systems.

  When in doubt, pick the smaller size. Split an `L` or `XL` when you can. An item that needed more becomes `M (escalated from S)`.
- **Owner.** `agent` or `human`. Human items have size `(none)`.
- **`Touches`.** The files expected to change. Mark new files `(new)` and schema fields `(+field)`.
- **`Done when`.** 1-3 observable outcomes, each tagged `(test)`, `(check)`, `(autoplay)` or `(play)` (see `rules.md` › Doing the work). Naming `Q<n>` means an open question gates the real behaviour.
- **`GDD:`.** The heading(s) the item implements, or `(none)` for items that aren't about the design.
- **`UI:`** (optional). `design/ui/<screen>.md`, the screen spec, for an item that builds or changes a screen (`procedures/ui-design.md`). The item builds to the spec and names its elements as the spec does. A `UI:` item sized `L` or `XL` is split per screen.
- **Bugs.** Instead of `Done when`, a bug has `Repro: steps → expected / actual` and `Found in:` (a playtest file, an item ID or `ad hoc`). It's done when the repro no longer happens.
- **Research.** A research item (`R<n>`) answers one question and changes no code. It looks like this:

  ```
  ### R3 · Which Web export options fit a 2D game · todo · M · agent
  - Depends on: (none)
  - Question: Which Web export options fit a 2D game that must load in under 10 seconds on a desktop browser, and what does each cost in features? Assume under 20 MB of assets.
  - Informs: Q4
  - GDD: Presentation and Platforms
  ```

  - The owner is always `agent`; status and `Depends on` work as for any item.
  - `Question:` replaces `Done when`: one question, stated so a reader can tell when it is answered. It may state assumptions and scope.
  - `Informs:` is the open question the research feeds (`Q<n>`), or `(none)`. `GDD:` is the heading the question concerns, or `(none)`. There is no `Touches`.
  - It is done when its note exists in `design/research/` (see `procedures/research.md`). A note that says what was searched and what stays unknown is a valid result; the human decides whether to queue a follow-up.
  - It is sized like any item (the same rules for doubt and escalation), and the size picks the model:
    - `XS`: one fact check against one primary source, such as a version, a licence, a limit or a date.
    - `S`: one narrow question with two options and a few sources, such as whether a plugin supports a feature.
    - `M`: a comparison of 2-4 options in one area, with trade-offs and a recommendation.
    - `L`: a comparison across several areas, with sources to reconcile.
    - `XL`: several linked areas that feed more than one decision, such as an export, store and licensing plan. Split it when you can.
- **`Note:`** (optional). An item paused partway through gets `- Note: <where it stands, what's next>`. Delete the note when the item is done.
- **Merge conflicts.** On a merge conflict in TASKS.md, keep both sides' items, give any duplicate ID a new number from `Next IDs`, and fix references to it.
