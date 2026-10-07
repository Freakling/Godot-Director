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

- **Heading.** It reads `ID · title · status · size · owner`, and a bug adds `· high|med|low`. New IDs (`T<n>`, `B<n>`) come from the `Next IDs` line, which you then bump. IDs are never reused.
- **Status.** `todo`, `in-progress YYYY-MM-DD` (the claim date) or `done`. "Ready" isn't stored: a `todo` item is ready when everything in `Depends on` is `done`.
- **Size.**
  - `XS`: a single value, label, or line. No logic change and no new tests.
  - `S`: 1-2 files, data, text, or a clear bug.
  - `M`: 1-2 systems, or a feature that follows an established pattern.
  - `L`: 3+ systems, new architecture, a save format, or a bug without a repro.
  - `XL`: a cross-cutting refactor, a complete subsystem redesign, or a change that touches most systems.

  When in doubt, pick the smaller size. Split an `L` or `XL` when you can. An item that needed more becomes `M (escalated from S)`.
- **Owner.** `agent` or `human`. Human items have size `(none)`.
- **`Touches`.** The files expected to change. Mark new files `(new)` and schema fields `(+field)`.
- **`Done when`.** 1-3 observable outcomes, each tagged `(test)`, `(check)` or `(play)` (see `rules.md` › Doing the work). Naming `Q<n>` means an open question gates the real behaviour.
- **`GDD:`.** The heading(s) the item implements, or `(none)` for items that aren't about the design.
- **Bugs.** Instead of `Done when`, a bug has `Repro: steps → expected / actual` and `Found in:` (a playtest file, an item ID or `ad hoc`). It's done when the repro no longer happens.
- **`Note:`** (optional). An item paused partway through gets `- Note: <where it stands, what's next>`. Delete the note when the item is done.
- **Merge conflicts.** On a merge conflict in TASKS.md, keep both sides' items, give any duplicate ID a new number from `Next IDs`, and fix references to it.
