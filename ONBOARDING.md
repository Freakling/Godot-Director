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
6. **Assistant adapters.** For a first install, ask which assistants will work on the game. The answer is `claude`, the default, or `none` for other assistants only; the core works through `AGENTS.md`, which most assistants read. An upgrade keeps the earlier choice.

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
  > - **Full**: does everything fast does, then re-checks all project files against the current standards — same thoroughness as a fresh install of this version. Choose this after many versions have accumulated, for a new machine or contributor, or when you want a complete review.

  Then:
  1. Read the entries in `$GDIR/CHANGELOG.md` newer than the old version (the install report names it). Carry out each **Upgrade steps** section in order. From 2.x that includes 3.0.0.
  2. If full, carry out steps 4–8.
  3. Run step 3 only if `bash tools/check.sh` exits 3 (fast) or run it again now (full).
  4. Summarise what changed, using the CHANGELOG and `git diff --stat`.
  5. Go to step 9.

## 3. Godot for this clone
Run `bash tools/setup-clone.sh --skip-hook`, adding the Godot path if the human gave one. It finds Godot 4.3+ and saves the path in `tools/godot_bin.local`, which is gitignored and never committed. If it exits 3, ask the human where Godot is and rerun it with the path. On Windows, prefer the `*_console.exe` build.

Then run `bash tools/check.sh` once and keep the result. An existing game often fails at first; that's information, not a blocker. The pre-commit hook is installed at the very end (step 9), so the install commit isn't blocked.

## 4. Scan the project (read only)
- `project.godot`: name, `config/features` (the Godot version), autoloads, main scene, renderer, and window/stretch settings.
- Layout: where scripts, scenes, resource schemas, `.tres` data, screen/UI scripts and tests live, with a file count per folder.
- Existing test suites: `addons/gut`, `addons/gdUnit4`.
- Existing docs: README, design documents, TODO lists, changelogs.
- `TODO`, `FIXME` and `HACK` comments, with file and line.
- Game logic in screens: randomness, or assignments to autoload variables, in UI scripts.

## 5. Content, by mode

### Fresh start
1. **The Godot project.** If there's no `project.godot`, write a minimal one yourself; don't send the human to Godot's project manager, which rewrites `.gitignore` and `.gitattributes`. Take the version from setup-clone's output (e.g. `4.7`). The renderer follows the interview: `forward_plus` is the default, and `gl_compatibility` suits web and low-end targets.
   ```ini
   config_version=5

   [application]
   config/name="<game name>"
   config/features=PackedStringArray("<major.minor>")

   [debug]
   gdscript/warnings/untyped_declaration=2

   [rendering]
   renderer/rendering_method="forward_plus"
   ```
2. **A short design interview,** in short rounds. For each question, give options with a recommendation and let the human pick:
   1. pitch, genre, and the feeling the game should give;
   2. 3–5 Design Pillars;
   3. the core loop: moment to moment, session, run or campaign, and starting conditions;
   4. platforms, input, 2D or 3D, camera, art direction and target aspect ratios.
3. **Record it.** Write the answers into the GDD as the current design, and add a line to `design/decisions.md` for each. Anything undecided becomes a `Q<n>`.
4. **Seed TASKS.md,** each item with Size, `Touches` and tagged `Done when`: the folder layout, a first autoload for game state, a first rule class with a test, and the first playable grey-box scene set as the main scene.

### Existing game
1. **AGENTS.md › Architecture:** one row per autoload, per area of rule code, and per group of screens. Take "Owns" from the scripts' top comments and public methods, not from guesses.
2. **GDD:** fill each section from the existing design documents and code. Mark anything inferred `(inferred — please confirm)`, and turn anything unknown into a `Q<n>`. Delete a section the game doesn't need only after the human agrees.
3. **TASKS.md:** turn TODOs, known bugs and the human's priorities into items, with bugs as `B` items.
4. **Screens with game logic.** Set `tools/check.cfg` › `[screens] dirs` to the UI folders. Each screen script that breaks the rule gets:
   - its own `M` item titled "Decouple: <screen>", which moves the logic into a system and removes the script from the list;
   - an entry in `[screens] known`, so the check passes meanwhile.
5. **Check failures** from step 3 become the first items. Crashes are `high`.
6. **Existing test suites.** Write `tools/check.local.sh` to run them headless. GUT: `"$GODOT_BIN" --headless -s addons/gut/gut_cmdln.gd -gexit`. gdUnit4: its command-line tool, with `--ignoreHeadlessMode`. The check itself skips their test files.
7. **Typed GDScript.** Add `gdscript/warnings/untyped_declaration=2` under `[debug]` in `project.godot`. If the check then fails with many untyped declarations, set it to `1`, and add an item: "Type the remaining untyped declarations, then set untyped_declaration to 2". To list them later, set it to 2 temporarily.

### Migrate from Godot Director 1.x
Rewrite the old files into the new format (`$GDIR/project/` shows the target shape of each, and `.godot-director/tasks.md` the item format), then delete what's obsolete; git keeps the history. IDs carry over: T and B numbers stay the same, and §11 questions become `Q<n>` with the same number. Also do steps 4–7 of Existing game above, for the screens, the check failures, the test suites and the typing setting.

| 1.x | 2.x |
|---|---|
| `AGENTS.md` (routing table, ground rules, two agents, model sizing) | Rewrite from `$GDIR/project/AGENTS.md`. The rules now live in `.godot-director/rules.md`. Carry project-specific rules into Project rules. |
| `SYSTEMS.md` | AGENTS.md › Architecture (System · Owns · Where · Talks to). Drop file-level detail the code already shows, then delete the file. |
| `CLAUDE.md` (persona selection) | Replace with `$GDIR/project/CLAUDE.md`. |
| `.promptx/` | Delete. |
| `README.md` › Project Status | TASKS.md › Milestones; leave a one-line link in the README. |
| `README.md` › AI vs. Human Responsibilities, doc-ownership table | Record what differs from the defaults in Project rules, then delete both sections. |
| `TASKS.md` tables | One heading per item: `ready`/`blocked` → `todo`; `in-progress: code`/`cowork` → `in-progress <today>`; `needs-validation` → `todo`, with "the check passes (check)" in `Done when`. Owner: `human` for human-only work, otherwise `agent` (Cowork's work is the agent's now). Size `TBD` → S/M/L by judgement. `## Bugs` rows → `B` items (Repro, severity, Found in). Drop the Systems column. Tag each `Done when` outcome `(test)`, `(check)` or `(play)`. Replace `§` references with heading names. Delete recurring rows such as the old T2. Move `## Archived` rows to `TASKS-archive.md`. Add the `Next IDs` line. |
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
| `core.hooksPath` set to `.githooks` | `tools/setup-clone.sh` explains it. The human runs `git config --unset core.hooksPath` (the guard hook blocks you from doing it), then setup-clone installs the hook the 2.x way. |

Finally, search the documents for leftovers and fix them. Use `git grep -n -e … -- '*.md'`, which skips an excluded Godot Director folder. Search for `§`, `SYSTEMS.md`, `SETUP.md`, `FUNCTION_CHECK`, `Cowork`, `needs-validation`, `in-progress:`, `persona`, `dev-small`, `.promptx`, `**Version:**`, `--headless --path . --quit` and `{{GODOT_BIN}}`.

## 6. Project facts and settings
- **AGENTS.md:** name, pitch, Godot version, dimension, platforms and rendering. Fill in the Layout table from the real folders (delete rows that don't apply), and the Architecture table (from step 5).
- **`tools/check.cfg`:** set `[screens] dirs` to the real UI folders, and `known` as in step 5. Use `allow_writes_to` only for an autoload a screen legitimately edits, such as Settings, and ask the human first. Put third-party folders in `[scan] skip`.
- **`project.godot`:** it has `untyped_declaration` (step 5).

## 7. Ownership and project rules
Walk the human through the defaults. Record only the differences, in AGENTS.md › Project rules.
- The human owns design, balance, art direction and priorities.
- The agent owns code, data schemas, placeholder art, tests and the records.
- Ask whether the agent may produce any production art, audio or player-facing text.
- Commits: the agent proposes and the human approves. Pushes happen when the human asks, or never if there's no remote.
- Model sizing (Claude Code only): **ask the human, and recommend on.** When on, the `builder` subagent uses Haiku for `XS` and `S` items and the session model for everything else. Record the answer in Project rules.
- Reviews: by default after `L` and `XL` items, and after `M` items that change saves or a system's public methods.

## 8. Playtest template
Replace the `{{LOOP…}}` parts of `playtesting/TEMPLATE.md` with one section per loop in GDD › Core Loop, usually 3–6. Each gets one fixed scored statement and 1–2 open questions about decisions and feel. Update the "Loops you played" line to match.

If the loops aren't decided yet, leave the placeholders, and add an agent item "Fill the playtest template's loop sections" that depends on the core-loop question.

## 9. Verify, commit, hand off
1. Run `bash tools/check.sh` and report the result.
2. Search for `{{` with `git grep -n "{{" -- '*.md'`. Only postponed template loops may remain, and only if an item exists for them. `git ls-files -o -i --exclude-standard -- '*.gdir-new'` must print nothing.
3. Walk through the checks in `.godot-director/procedures/align.md`. Its fixes go into the install commit.
4. List every file created, changed or deleted (`git status`). That includes the `.uid` files Godot 4.4+ creates next to scripts, among them `tools/check.gd.uid`.
5. **Commit it all in one commit, after the human approves.**
   - Stage everything: `git add -A -- <those files>`.
   - Mark the scripts executable, listing only files that exist (`.claude/hooks` is there with the Claude adapter only): `git add --chmod=+x -- tools/*.sh .githooks/pre-commit`, plus `.claude/hooks/*.sh`.
   - Use the message `chore: install Godot Director <version>` (or `migrate to` / `upgrade to`). The body names the mode and anything you inferred.
6. **The pre-commit hook.**
   - If the check passes, run `bash tools/setup-clone.sh`, which installs it.
   - If the check fails, leave the hook off and add an item: "Install the pre-commit hook once the check passes (`bash tools/setup-clone.sh`)".
   - If setup-clone exits 4, tell the human what it printed (an existing hook or `core.hooksPath` needs a manual line).
7. **Manual install:** offer to delete the Godot Director folder from the game. Deleting it is recommended, since upgrades come from a fresh download or the plugin. If the human keeps it, leave it in `.git/info/exclude`.
8. **Offer a "Development" section for the game's README:** clone, then `bash tools/setup-clone.sh`, then the commands.
9. **Tell the human:**
   - what needs their confirmation;
   - how to use it: "do the next task", "let's brainstorm…", "process my playtest", "prepare a function check", "check the docs are aligned" (in Claude Code also `/next-task`, `/design`, `/playtest`, `/function-check`, `/align`, `/prune`);
   - with the Claude adapter: to restart Claude Code, because skills, hooks and permissions load when a session starts;
   - to open the project in the Godot editor once, and commit the `.uid` and `.import` files it creates;
   - that every new clone needs `bash tools/setup-clone.sh`.
