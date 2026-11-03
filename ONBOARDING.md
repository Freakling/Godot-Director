# Godot Director onboarding (for the AI assistant)

Follow these steps to install Godot Director into a Godot project, upgrade it, or migrate a project from Godot Director 1.x. Work from a session opened in the game's root folder, where `project.godot` is (or will be). You need to be able to run bash; on Windows, Git Bash.

The human makes every design and ownership decision; you gather, propose and write. Ask choices as multiple-choice questions when your tool supports them.

`$GDIR` below is the Godot Director folder:
- With the Claude Code plugin, it's `${CLAUDE_PLUGIN_ROOT}`.
- With the `godot-director` skill installed through `npx skills add`, it's the clone the skill fetches outside the game.
- With a manual install, it's the folder this file is in, usually `Godot-Director/` inside the game.

## 1. Preconditions and mode
1. **Git.** The project must be a git repository. If it isn't, ask to run `git init`.
2. **Manual install inside the game:** if `$GDIR` is inside the project, add its relative path (e.g. `/Godot-Director/`) to the file `git rev-parse --git-path info/exclude` names. Do it now, before any commit. That keeps it out of `git status`, the commits, the hooks and the check.
3. **Clean tree.** A new repository with files in it: commit them as they are first, so the install is one reviewable diff. Otherwise there must be no uncommitted changes (apart from the Godot Director folder itself); ask the human to commit or stash them first.
4. **Godot editor closed.** Ask the human to close the editor for this project during setup, since it rewrites `project.godot`.
5. **Mode.** Tell the human which mode you detected, and let them confirm:
   - **upgrade:** `.godot-director/manifest` exists, or `.claude4godot/manifest` (a 2.x install, from before Godot Director was renamed; `install.sh` moves it to the new names).
   - **migrate from 1.x:** `.promptx/personas/` or `playtesting/FUNCTION_CHECK.md` exists. An `AGENTS.md` alone isn't proof, since many projects have one.
   - **existing game:** `project.godot` and scripts, without Godot Director.
   - **fresh start:** no `project.godot`, or an empty project.
6. **Assistant adapters.** For a first install, ask which assistants will work on the game. The answer is `claude`, the default, or `none` if only using other assistants; the core works through `AGENTS.md`. An upgrade keeps the earlier choice.

## 2. Install the files
Run `bash "$GDIR/install.sh" --tools <claude|none> .` for a first install. For an upgrade, run `bash "$GDIR/install.sh" .` without `--tools`. Then read its report.
- **`CONFLICTS`** (`<file>.gdir-new`) mean the project already had its own version of a framework file:
  - `.claude/settings.json`: merge it, keeping the project's permissions, hooks and env and adding Godot Director's.
  - Files left over from 1.x (migrate mode): take the new version.
  - Anything else: show the human the difference and ask.

  Delete each `.gdir-new` file once it's merged.
- **"project files kept"** means the project already had that file.
  - In migrate mode, step 5 rewrites these.
  - Otherwise, bring each one into the shape of `$GDIR/project/<same file>`:
    - `CLAUDE.md` must contain the line `@AGENTS.md`, at the top. Move instructions meant for every assistant into AGENTS.md.
    - `AGENTS.md` keeps its content, gains the missing sections, and gets the line that points to `.godot-director/rules.md`.
    - `TASKS.md` and `design/gdd.md` convert to the seed's format, keeping their content.
- **Upgrade mode.** Fresh installs (fresh start, existing game, migrate from 1.x) always run all steps. Upgrades are the only mode where the human chooses the depth. Present the choice before continuing:

  Tell the human the version being upgraded from and to, then summarise in one sentence each what the relevant changelog entries change. Then ask:

  > **Fast or full upgrade?**
  > - **Fast** (default for routine upgrades): applies the changelog steps, which cover both framework files and any game-owned file updates for new features (AGENTS.md, TASKS.md, the GDD). Takes a few minutes.
  > - **Full**: does everything fast does, then re-checks all project files against the current standards; same thoroughness as a fresh install of this version. Choose this after many versions have accumulated, for a new machine or contributor, or when you want a complete review.

  Then:
  1. Read the entries in `$GDIR/CHANGELOG.md` newer than the old version (the install report names it). Carry out each **Upgrade steps** section in order. From 2.x that includes 3.0.0.
  2. If full, carry out steps 4-8.
  3. Run step 3 only if `bash tools/check.sh` exits 3 (fast) or run it again now (full).
  4. **Screens.** Run `bash tools/ui_capture.sh --missing` (the Screens checks of `.godot-director/procedures/align.md`) and tell the human which screens the catalog doesn't cover yet. It lists them; it never fails the upgrade. Offer to add the entries now or leave them for the next item that touches a screen. An upgrade keeps the game's own `AGENTS.md` and `tools/check.cfg`, and the installer writes a new `tools/ui_capture.cfg` with the layout lint in the check off (`check_in_check=false`, `enforce=[]`); tell the human they can turn it on a screen at a time, in `enforce`, once the screen's capture is lint-clean.
  5. Summarise what changed, using the CHANGELOG and `git diff --stat`.
  6. Go to step 9.

## 3. Godot for this clone
Run `bash tools/setup-clone.sh --skip-hook`, adding the Godot path if the human gave one. It finds Godot 4.5+ and saves the path in `tools/godot_bin.local`, which is gitignored and never committed. If it exits 3, ask the human where Godot is and rerun it with the path. On Windows, prefer the `*_console.exe` build.

gitleaks is optional and recommended: with it on the PATH, the check and the pre-commit hook scan for secrets, and without it they print a note and go on. If `command -v gitleaks` finds nothing, tell the human it's worth installing (`winget install gitleaks`, `brew install gitleaks`, or https://github.com/gitleaks/gitleaks#installing) and carry on; never stop for it. (A prototype is the one place that needs it, since its commits skip the check and the scan is their only gate: `/prototype` says so when it is missing.)

Then run `bash tools/check.sh` once and keep the result. An existing game often fails at first; that's information, not a blocker. The pre-commit and pre-push hooks are installed at the very end (step 9), so the install commit isn't blocked.

## 4. Scan the project (read only)
- `project.godot`: name, `config/features` (the Godot version), autoloads, main scene, renderer, and window/stretch settings.
- Layout: where scripts, scenes, resource schemas, `.tres` data, screen/UI scripts and tests live, with a file count per folder.
- Existing test suites: `addons/gut`, `addons/gdUnit4`.
- Existing docs: README, design documents, TODO lists, changelogs.
- `TODO`, `FIXME` and `HACK` comments, with file and line.
- Game logic in screens: randomness, or assignments to autoload variables, in UI scripts.

## 5. Content, by mode

The answers stay in the conversation, and the records below are drafts, until the human approves the summary at the end of this section (Summary and approval).

### Your own design document (fresh start and existing game; before the interview or the GDD)
Every project has `design/director-gdd.md`: the human's own Game Design Document template, in their own words. It is the human's file: you read it and never edit it. The GDD (`design/gdd.md`) stays the design record you maintain, so each fact lives in one place; the human's document is input that stays as they wrote it.
1. **Is it filled?** It is still the template while its title reads `\[Game Title\]` and its sections hold only the prompts. If the human points to another document (a GDD or notes elsewhere, or a file in `director/`), read that instead.
2. **If it is blank, offer it** before the interview, as an alternative to the chat interview or an addition to it:
   - what it is: the template for describing the game, how it should work and what it is for, in their own words;
   - where it is: `design/director-gdd.md`;
   - why it helps: a written document gives you their intent and the context behind it, adds value that a chat interview alone doesn't, and sets the stage for later development, since every design session and build starts from it;
   - when: it can be filled before onboarding, now (you wait), or later, for a new game or one already underway; and the interview works without it.

   Ask which they prefer: fill it now, interview only, or both (interview first, document later). Never fill it in for them. If they fill it later, the next session reads it as below.
3. **If it is filled, read it first.**
   - Fresh start: take the interview's answers from it (step 2 of Fresh start below). Show each answer taken, marked `(from your document)`, and ask only what it leaves open. An answer you worked out from the document without it saying so is `(inferred, please confirm)`.
   - Existing game: read it with the existing documents and the code, and use it to build the initial assessment: Architecture rows, GDD sections and first items. Mark each statement it supplied `(from your document)` and each you inferred `(inferred, please confirm)`.
   - Both: where the document and the code or the earlier docs disagree, say so and let the human decide.
4. **Draft the records.** The GDD sections you draft from it, and a `design/decisions.md` line for each decision (`why: from your document` when that is the reason). Anything the document leaves undecided becomes a `Q<n>`. Don't copy the document wholesale into the GDD; write the current design in the GDD's own sections. They are written after the summary below is approved.
5. **Upgrade.** On an upgrade the installer adds `design/director-gdd.md` when it is missing; offer it as above. Later, when the human says the document changed, read it again and bring the GDD in line, marking what you inferred; show the changes as a summary and write them after the human approves it.

### Fresh start
1. **The Godot project.** If there's no `project.godot`, write a minimal one yourself; don't send the human to Godot's project manager, which rewrites `.gitignore` and `.gitattributes`. Take the version from setup-clone's output (e.g. `4.7`). The renderer follows the interview: `forward_plus` is the default, and `gl_compatibility` suits web and low-end targets.
   ```ini
   config_version=5

   [application]
   config/name="<game name>"
   config/features=PackedStringArray("<major.minor>")

   [autoload]
   PlayLog="*res://tools/play_log.gd"

   [debug]
   gdscript/warnings/untyped_declaration=2
   settings/gdscript/always_track_call_stacks=true

   [rendering]
   renderer/rendering_method="forward_plus"
   ```
2. **A short design interview,** in short rounds, after reading the human's document if they filled one (above): ask only what it leaves open, and confirm what you took from it. For each question, give options with a recommendation and let the human pick, and hold the answers in the conversation (question 5 has none: User stories, below):
   1. pitch, genre, and the feeling the game should give;
   2. 3-5 Design Pillars;
   3. the core loop: moment to moment, session, run or campaign, and starting conditions;
   4. platforms, input, 2D or 3D, camera, art direction and target aspect ratios;
   5. whether the game uses user stories (User stories, below).
3. **Draft the records.** Draft the answers as GDD text, the current design, and a line for `design/decisions.md` for each. Anything undecided becomes a `Q<n>`. Question 5's answer is drafted for AGENTS.md › Project rules instead (User stories, below).
4. **Draft the TASKS.md seed,** each item with Size, `Touches` and tagged `Done when`: the folder layout, a first autoload for game state, a first rule class with a test, and the first playable grey-box scene set as the main scene, with the play log wired into its run (`PlayLog.begin_run()`, and `log_snapshot()` where the player may act) and the autoplay adapter filled in (`tools/autoplay_adapter.gd`: start a run with a seed, every player action in `list_actions()`, `state()`), so `bash tools/autoplay.sh smoke` plays it. A new game's `tools/check.cfg` starts with `[autoplay]` on (`check_in_check=true`, `enforce=["smoke"]`): the check plays smoke headless, and skips it with a note while the adapter is still the seed's, so a game with nothing registered yet passes.

### Existing game
Draft the records among these in the conversation; what they produce (the Architecture rows, the GDD text, the decision lines, the Open Questions and the items) joins the summary below. The settings they change (`tools/check.cfg`, `tools/check.local.sh`, `project.godot`) are part of the install and are approved with the install commit (section 9).
1. **AGENTS.md › Architecture:** one row per autoload, per area of rule code, and per group of screens. Take "Owns" from the scripts' top comments and public methods, not from guesses.
2. **GDD:** fill each section from the human's document (above), the existing design documents and the code. Mark anything inferred `(inferred, please confirm)`, and turn anything unknown into a `Q<n>`. Delete a section the game doesn't need only after the human agrees.
3. **TASKS.md:** turn TODOs, known bugs and the human's priorities into items, with bugs as `B` items.
4. **Screens with game logic.** Set `tools/check.cfg` › `[screens] dirs` to the UI folders. Each screen script that breaks the rule gets:
   - its own `M` item titled "Decouple: <screen>", which moves the logic into a system and removes the script from the list;
   - an entry in `[screens] known`, so the check passes meanwhile.
5. **Check failures** from step 3 become the first items. Crashes are `high`.
6. **Existing test suites.** Write `tools/check.local.sh` to run them headless. GUT: `"$GODOT_BIN" --headless -s addons/gut/gut_cmdln.gd -gexit`. gdUnit4: its command-line tool, with `--ignoreHeadlessMode`. The check itself skips their test files.
7. **Typed GDScript.** Add `gdscript/warnings/untyped_declaration=2` under `[debug]` in `project.godot`. If the check then fails with many untyped declarations, set it to `1`, and add an item: "Type the remaining untyped declarations, then set untyped_declaration to 2". To list them later, set it to 2 temporarily.
8. **Autoplay.** The seeds of `tools/check.cfg` start `[autoplay]` on, which suits a new game: set `check_in_check=false` and `enforce=[]` there, so the check plays nothing until the adapter works. Add an item "Wire autoplay" as the Autoplay upgrade step in the changelog describes (the play log wired, then the adapter, smoke and a scripted scenario for the core loop, ending with `bash tools/autoplay.sh --all` exiting 0 and `[autoplay]` turned on).

### Migrate from Godot Director 1.x
The rewritten files keep the human's content in the new format and are reviewed in the install commit (section 9). What the rewrite adds beyond them (the decision lines reconstructed from the version line and revision notes, the `B` items, the items for the `No task` entries the human picks) joins the summary below.

Rewrite the old files into the new format (`$GDIR/project/` shows the target shape of each, and `.godot-director/tasks.md` the item format), then delete what's obsolete; git keeps the history. IDs carry over: T and B numbers stay the same, and §11 questions become `Q<n>` with the same number. Also do steps 4-8 of Existing game above, for the screens, the check failures, the test suites, the typing setting and autoplay.

| 1.x | 2.x |
|---|---|
| `AGENTS.md` (routing table, ground rules, two agents, model sizing) | Rewrite from `$GDIR/project/AGENTS.md`. The rules now live in `.godot-director/rules.md`. Carry project-specific rules into Project rules. |
| `SYSTEMS.md` | AGENTS.md › Architecture (System · Owns · Where · Talks to). Drop file-level detail the code already shows, then delete the file. |
| `CLAUDE.md` (persona selection) | Replace with `$GDIR/project/CLAUDE.md`. |
| `.promptx/` | Delete. |
| `README.md` › Project Status | TASKS.md › Milestones; leave a one-line link in the README. |
| `README.md` › AI vs. Human Responsibilities, doc-ownership table | Record what differs from the defaults in Project rules, then delete both sections. |
| `TASKS.md` tables | One heading per item: `ready`/`blocked` → `todo`; `in-progress: code`/`cowork` → `in-progress <today>`; `needs-validation` → `todo`, with "the check passes (check)" in `Done when`. Owner: `human` for human-only work, otherwise `agent` (Cowork's work is the agent's now). Size `TBD` → XS/S/M/L/XL by judgement. `## Bugs` rows → `B` items (Repro, severity, Found in). Drop the Systems column. Tag each `Done when` outcome `(test)`, `(check)` or `(play)`. Replace `§` references with heading names. Delete recurring rows such as the old T2. Move `## Archived` rows to `TASKS-archive.md`. Add the `Next IDs` line (`T<n> · B<n> · R1`). |
| `design/gdd.md` | Keep the content, but rename headings to the seed's names (High-Concept Pitch → Pitch; Core Gameplay Loop → Core Loop; Screens & Systems → Systems; Open Design Questions → Open Questions) and drop the numbers. See the next three rows for the sections that move. |
| GDD §10 Technical Blueprint | Engineering conventions are in rules.md now; put any that differ in Project rules. Facts go to AGENTS.md. Platforms, input, camera and art go to GDD › Presentation and Platforms. Settings & Dev Tools: rewrite to the current rules (settings as JSON in `user://`; dev tools gated on debug builds or a feature tag). Add an item if existing code writes settings next to the executable or gates tools on a player-editable flag. |
| GDD §11 Open Design Questions | Open Questions with `Q<n>` and a `Next` line. |
| GDD §13 Playtesting Process, and the version line | Delete. The process is in `playtesting/README.md` now. |
| Version line and revision notes | `design/decisions.md`: one line for each decision you can reconstruct from them and `git log -- design/gdd.md`. Don't invent reasons; write `why: not recorded` when none is known. |
| `playtesting/FUNCTION_CHECK.md` | Write `playtesting/<today>-function-check.md` as a baseline ("carried over from 1.x"). Items whose last result was OK go in ticked Works; items that were built but never verified go in unticked. Items marked `Broken` with no bug become `B` items. Give the `No task` items to the human as a list: each may become an item. Then delete the file. |
| `playtesting/README.md` | Take the new version (the `.gdir-new` file). |
| `playtesting/<version>/playtest_N.md` | Leave in place as history. Add `**Processed:** under 1.x` to those already processed; ask if unsure. New reports are `playtesting/YYYY-MM-DD-playtest.md`. |
| `playtesting/TEMPLATE.md` | Keep its loops and scored statements, worded exactly the same so scores stay comparable, in the new layout. |
| A copy of the framework inside the game (`Claude4Godot/` in 1.x) | Delete it after asking. |
| Files under `.claude/` that aren't in `.godot-director/manifest` (1.x agents, skills or commands) | List them for the human. Delete the 1.x ones after asking; keep the project's own. |
| `core.hooksPath` set to `.githooks` | `tools/setup-clone.sh` explains it. The human runs `git config --unset core.hooksPath` (the guard hook blocks you from doing it), then setup-clone installs the hooks the 2.x way. |

Finally, search the documents for leftovers and fix them. Use `git grep -n -e … -- '*.md'`, which skips an excluded Godot Director folder. Search for `§`, `SYSTEMS.md`, `SETUP.md`, `FUNCTION_CHECK`, `Cowork`, `needs-validation`, `in-progress:`, `persona`, `dev-small`, `.promptx`, `**Version:**`, `--headless --path . --quit` and `{{GODOT_BIN}}`.

### User stories (fresh start, existing game and migrate)
Ask once whether the game uses user stories: in the design interview for a fresh start, and here for an existing or migrated game. Skip the question when AGENTS.md › Project rules already has a `User stories:` line (a full upgrade, say): the human has answered. Say in a sentence or two what they are for: one line per thing a player does and why ("As a player I sell my catch at the dock at sunset, so each evening ends with a clear result"), which tells the AI why each thing is built and keeps it aligned with the design; some developers prefer the GDD alone. Offer both answers without a recommendation: it's the human's taste.
- Draft the answer for AGENTS.md › Project rules in this exact format, `- User stories: on` or `- User stories: off`, since `tools/stories.sh` reads it. It joins the summary below, and the switch is set only after the human approves it.
- **On:** once the GDD and TASKS.md are drafted, follow `.godot-director/procedures/design.md` › User stories › Turning them on. A fresh start drafts them from the interview, for the human to confirm with the GDD; an existing or migrated game gets them written from the code, unconfirmed. What it writes (the stories file, the GDD link and the items' `Stories:` lines) joins the summary below instead of having one of its own. Tell the human the stories are validated in each playtest and function check, and every 10 built items (`tools/check.cfg` › `[stories] every`), which `/next-task` proposes.
- **Off:** nothing else changes: there is no `design/user-stories.md`, no item has `Stories:`, and nothing asks again. They can turn them on later ("turn on user stories").

### Summary and approval
At the end of the interview (fresh start), or when the records are drafted from the code and the human's documents (existing game), or once the rewrite has produced them (migrate), and after the user stories above are drafted, show one summary of everything this section will write (`.godot-director/procedures/design.md` › Summary and approval), and wait. Nothing is written before the human approves it.
1. **List it.** For each file, what it gets, as it will read: the GDD text; each line for `design/decisions.md`, word for word; the Open Questions; the `User stories: on` or `User stories: off` line for AGENTS.md › Project rules and, with user stories on, the stories with their IDs and their Confirmed dates, or `unconfirmed`, the Last validated line, the GDD link and the items' `Stories:` lines; the TASKS.md items in full; and for an existing game the AGENTS.md › Architecture rows. Mark what came from the human's document `(from your document)` and what you inferred `(inferred, please confirm)`.
2. **Ask:** "Approve this summary, or tell me what to change?"
3. Write nothing until the human approves a summary of all of it (`design.md` › Summary and approval); a chat message or an "Other" answer before then re-opens the options. Then write all of it; it goes into the install commit (section 9). The project facts, settings and ownership of sections 6 to 8 keep the install commit's approval as their gate, except that exports and release have a summary of their own (`export.md` › Set up exports, `release.md` › Set up release).

## 6. Project facts and settings
- **AGENTS.md:** name, pitch, Godot version, dimension, platforms and rendering. Fill in the Layout table from the real folders (delete rows that don't apply), and the Architecture table (from step 5).
- **`tools/check.cfg`:** set `[screens] dirs` to the real UI folders, and `known` as in step 5. Use `allow_writes_to` only for an autoload a screen legitimately edits, such as Settings, and ask the human first. Put third-party folders in `[scan] skip`. `[autoplay]` starts on for a new game and off for an existing or migrated one (step 8 of Existing game). `[stories] every`, in a game that uses user stories, is how many built items after the last validation of the stories `/next-task` proposes the next one (`.godot-director/procedures/design.md` › Validate the stories); the seed says 10, and the human can decline a proposal. Leave it unless the human wants them validated more or less often.
- **`project.godot`:** it has `untyped_declaration` (step 5); `settings/gdscript/always_track_call_stacks=true` under `[debug]`, so the play log names the script line of an error in release builds too; and the `PlayLog` autoload first under `[autoload]`: `PlayLog="*res://tools/play_log.gd"` (the seed, which extends the framework's `tools/play_log_base.gd`). If the game already has its own `PlayLog`, or another play log, keep it registered as it is and leave the seed unregistered; add an item: "Migrate PlayLog to extend tools/play_log_base.gd, keeping its line formats" (`HH:MM:SS T<turn> [category] text`, so existing logs stay readable). For an existing or migrated game, also add an item to wire the play log: fill the seed's hooks, call `begin_run()` or `continue_run()`, `log_snapshot()` where the player may act, and log each player action from its system (`rules.md` › Everything is logged).
- **Exports.** Offer the export step: the target platforms and where exports run (this machine, a build container, or a hosted service such as GitHub Actions). Follow `.godot-director/procedures/export.md` › Set up exports, in its voice: short rounds, options with a recommendation. Skip what the project already answers: an existing `export_presets.cfg` and the platforms in the GDD. The step shows a summary and waits for the human's approval before it writes anything. The human can skip the step. A skip puts the open question and the "Set up exports" item that `export.md` › "When the human skips it" describes into that summary, so `/design Q<n>` runs the step later and `/next-task` builds the setup.
- **Release.** Offer the release step once exports are set up: the command that uploads each preset's build to a platform's UAT branch or channel, the command for production, and the names of the CI secrets the commands need (values are never written in the repo or the chat). Follow `.godot-director/procedures/release.md` › Set up release, in its voice. The step shows a summary and waits for the human's approval before it writes anything. The human can skip the step. A skip puts the open question and the "Set up release" item that `release.md` › "When the human skips it" describes into that summary.

## 7. Ownership and project rules

### Work-area ownership interview
For each area below, state the default and ask the human whether they want to own it. Record the result in AGENTS.md › Ownership (create that section now with a table). A human-owned area means the agent uses placeholders when it needs something from there; it never makes the real thing.

| Area | Default | Agent placeholder when human owns it |
|---|---|---|
| **GDScript / game code** | agent | stubbed function or empty class with `## PLACEHOLDER` comment |
| **UI / screen layout** | agent, or `director designs (director/ui/), agent builds` | minimal functional screen, commented for redesign |
| **Art / sprites / textures** | human | `ColorRect` under a node named `Visual`, labelled with what goes there |
| **Audio / music / SFX** | human | `AudioStreamPlayer` node, no stream assigned, comment naming the audio |
| **Scene / level design** | shared | grey-box scene with placeholder geometry; human finishes the layout |
| **Tunable values (`data/`)** | human | `## PLACEHOLDER` default in the schema; human sets final values in `.tres` |
| **Player-facing text** | agent | `"[PLACEHOLDER: describe the text]"` string constant |

### Designing screens by drawing
Ask once, in the UI row of the table above: do they want to design screens by drawing over screenshots of the running game (`/ui-design`; free Excalidraw, no account)?
- **Yes:** the row becomes `director designs (director/ui/), agent builds`, with the same placeholder. Offer `director/` (below) with `director/ui/` and an empty `director/.gdignore`, and tell them the loop: `/ui-design capture` writes a starter drawing per screen, they draw and save it as `director/ui/<screen>.excalidraw`, and `/ui-design process <screen>` turns it into the screen's spec.
- **No:** the row stays `agent` and nothing else changes. Capture, the layout lint and the catalog still work. No open question and no item is added: drawing is optional, never a prerequisite.

For a new game, the catalog (`tools/ui_screens.gd`) starts with the main scene; the Layout table in AGENTS.md lists `design/ui/`. A new game starts with the layout lint in the check on (`tools/ui_capture.cfg` › `[lint]` `check_in_check=true`, `enforce=["*"]`).

### Protected workspace
If the human owns any area, or wants a space the agent will never touch, offer to create `director/`. The agent reads files there for context (reference art, sketches, audio, notes) but never creates, modifies or deletes anything inside it.

If they want it:
1. Create `director/` and `director/README.md` explaining what it is and that the agent won't touch it.
2. Ask whether to gitignore it (for large binary assets) or commit it (for design docs and notes). Update `.gitignore` accordingly.
3. Add a row to AGENTS.md › Ownership: `director/: human's workspace, read-only for the agent`.
4. If they want to design screens by drawing over screenshots (`/ui-design`), also create `director/ui/` and an empty `director/.gdignore`, so the editor doesn't import the PNGs they export there.

### Workflow defaults
- Commits: the agent proposes and the human approves. Pushes happen when the human asks, or never if there's no remote.
- Model sizing (Claude Code only): **ask the human, and recommend on.** When on, each item size maps to a specific model. Present the default mapping and ask whether any size should differ. Write the agreed mapping into AGENTS.md › Project rules in this exact format (run `/refresh-model-sizing` to update it later when models change):
  ```
  Model sizing: on
  - XS: claude-haiku-4-5-20251001
  - S: claude-haiku-4-5-20251001
  - M: claude-sonnet-5-5
  - L: claude-opus-5-5
  - XL: claude-opus-5-5
  ```
- Dev menu: **ask the human whether the game should have one, and how it is enabled; recommend in game.** The dev menu (`tools/dev_menu_base.gd`, with the game's seed `tools/dev_menu.gd`) has one tab per system with its actions and an inspector for its hidden values, and a Log tab with the play log's tail; it is how an assistant sees what the editor's Remote tree would show. Offer the ways to enable it (any combination):
  - **In game** (recommended): F12 opens it, in debug builds only.
  - **A setting:** `debug/dev_menu=true` under `[debug]` in `project.godot`, or a toggle in the game's own Settings (the seed's `setting_enabled()`), so it works in any build, release too.
  - **A command-line flag:** the game started with `-- --dev-menu`, in any build.

  Write the answer into AGENTS.md › Project rules, in this exact format (the ways joined with commas; `none` when the human doesn't want one), and tell the human what each means:
  ```
  Dev menu: in game (F12, debug builds only)
  Dev menu: in game (F12, debug builds only), setting (debug/dev_menu), flag (-- --dev-menu)
  Dev menu: none
  ```
  For any answer but `none`: with the editor closed, register the seed last under `[autoload]` in `project.godot`, `DevMenu="*res://tools/dev_menu.gd"`, set `enabled_by` in the seed's `_init` to the chosen ways (`MODE_IN_GAME`, `MODE_SETTING`, `MODE_FLAG`), and write `debug/dev_menu=false` under `[debug]` when the setting is chosen, so the human finds it. A new game registers each system from the seed's `_ready` as it adds it (`register_system("Run", RunState, ["next_day"])`, with the system's `debug_*` methods as actions and a `debug_inspect() -> Dictionary` for what only code can see). An existing game gets an item "Wire the dev menu: register its autoloads and systems, with their debug hooks". With `none`, leave the seed unregistered. A release export preset that excludes `tools/` keeps `tools/dev_menu_base.gd` and `tools/dev_menu.gd` when the answer includes the setting or the flag.
- Reviews: by default after `L` and `XL` items, and after `M` items that change saves or a system's public methods.

## 8. Playtest template
Replace the `{{LOOP…}}` parts of `playtesting/TEMPLATE.md` with one section per loop in GDD › Core Loop, usually 3-6. Each gets one fixed scored statement and 1-2 open questions about decisions and feel. Update the "Loops you played" line to match.

If the loops aren't decided yet, leave the placeholders, and add an agent item "Fill the playtest template's loop sections" that depends on the core-loop question.

## 9. Verify, commit, hand off
1. Run `bash tools/check.sh` and report the result.
2. Search for `{{` with `git grep -n "{{" -- '*.md' ':!.godot-director'` (the framework's own procedures and templates hold some). Only postponed template loops may remain, and only if an item exists for them. `git ls-files -o -i --exclude-standard -- '*.gdir-new' | grep '\.gdir-new$'` must print nothing (the grep drops nested clones, which `ls-files` lists as directories).
3. Walk through the checks in `.godot-director/procedures/align.md`. List the mechanical fixes it finds, and write them after the human approves them; they go into the install commit.
4. List every file created, changed or deleted (`git status`). That includes the `.uid` files Godot 4.4+ creates next to scripts, among them `tools/check.gd.uid`.
5. **Commit it all in one commit, after the human approves it and the fixes listed in step 3.**
   - Stage everything: `git add -A -- <those files>`.
   - Mark the scripts executable, listing only files that exist (`.claude/hooks` is there with the Claude adapter only): `git add --chmod=+x -- tools/*.sh .githooks/pre-commit .githooks/pre-push`, plus `.claude/hooks/*.sh`.
   - Use the message `chore: install Godot Director <version>` (or `migrate to` / `upgrade to`). The body names the mode and anything you inferred.
6. **The pre-commit and pre-push hooks.**
   - If the check passes, run `bash tools/setup-clone.sh`, which installs both.
   - If the check fails, leave the hooks off and add an item: "Install the pre-commit and pre-push hooks once the check passes (`bash tools/setup-clone.sh`)".
   - If setup-clone exits 4, tell the human what it printed (an existing hook or `core.hooksPath` needs a manual line).
7. **Manual install:** offer to delete the Godot Director folder from the game. Deleting it is recommended, since upgrades come from a fresh download or the plugin. If the human keeps it, leave it in `.git/info/exclude`.
8. **Offer a "Development" section for the game's README:** clone, then `bash tools/setup-clone.sh`, then the commands.
9. **Tell the human:**
   - what needs their confirmation;
   - how to use it: "do the next task", "let's brainstorm…", "validate the user stories" (in a game that uses them), "let me try … in a prototype", "process my playtest", "prepare a function check", "check the docs are aligned", "research how other games handle…", "export the game", "capture the screens", and, when a pillar has been built two ways, "reset the design drift" (in Claude Code also `/next-task`, `/design`, `/prototype`, `/research`, `/export`, `/ui-design`, `/playtest`, `/function-check`, `/align`, `/drift-reset`, `/prune`). Align often, reset when you have to;
   - with the Claude adapter: to restart Claude Code, because skills, hooks and permissions load when a session starts;
   - to open the project in the Godot editor once, and commit the `.uid` and `.import` files it creates;
   - that every new clone needs `bash tools/setup-clone.sh`.
