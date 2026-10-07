# Changelog

Each entry lists what changed. **Upgrade steps** at the end of an entry cover both framework fixes and game-owned file updates (AGENTS.md, TASKS.md, the GDD), so every project reaches the same capability level after upgrading. Onboarding carries them out; the fast upgrade mode runs only these steps, and the full mode also re-checks everything as if newly installed.

## 3.4.2 (2026-10-07)

- **Role terminology aligned.** "Designer" and "developer" as role names are replaced with the canonical Director-model terms throughout: the human is the **director**, the main session is the **orchestrator**, the build subagent is the **builder**, the review subagent is the **reviewer**. "Design" as an activity (design sessions, design calls, the GDD, the `design` skill) is unchanged.

**Upgrade steps**

No framework file changes affect installed games. Existing `AGENTS.md` files may keep the old terms — updating them is optional.

## 3.4.1 (2026-10-07)

- **Per-size model mapping.** Each of the five item sizes (`XS`, `S`, `M`, `L`, `XL`) now maps to its own model ID, stored in AGENTS.md › Project rules. The previous two-tier rule (Haiku for XS/S, session model for everything else) is replaced by five independent entries. Default Claude Code mapping: XS/S → `claude-haiku-4-5-20251001`, M → `claude-sonnet-5-5`, L/XL → `claude-opus-5-5` (`claude-fable-5-1` is an alternative for XL on Claude platform / usage credits).
- **`/refresh-model-sizing` skill.** A new skill and procedure. It first checks whether the current assistant supports subagent spawning with per-subagent model selection — if not, it tells the human and stops without writing anything. If yes (Claude Code by default; other capable tools also supported), it proposes a mapping, confirms with the human, and writes it to Project rules. Run it when models change or on a new machine.
- **Onboarding writes the full mapping.** Step 7 now presents the five-size default and asks the human to confirm or adjust before writing it into Project rules.
- **Model sizing scoped correctly.** `rules.md` now labels model sizing as Claude Code (and any tool with equivalent subagent + model-selection support). Tools that don't qualify skip the feature entirely.

**Upgrade steps**
1. In AGENTS.md › Project rules, replace `Model sizing: on` (if present) with the five-line block. For Claude Code defaults:
   ```
   Model sizing: on
   - XS: claude-haiku-4-5-20251001
   - S: claude-haiku-4-5-20251001
   - M: claude-sonnet-5-5
   - L: claude-opus-5-5
   - XL: claude-opus-5-5
   ```
   Or run `/refresh-model-sizing` — it will detect the environment and propose the mapping for you.

## 3.4.0 (2026-10-06)

- **Builder skips final check.** The `builder` subagent no longer runs `bash tools/check.sh` at the end of its build. Step 4 of `next-task.md` runs the check from the outer session, and the pre-commit hook is the safety net — the third invocation was ~2 minutes of waste per task.
- **Review threshold raised to L and XL.** `M` items no longer trigger an independent review by default. The pre-commit hook and the builder's own testing are sufficient at that scale. Exception: an `M` item that rewrites the save codec (`to_dict`/`from_dict` pair) or touches more than three system boundaries still gets a review.
- **Auto-commit during autonomous work.** `next-task.md` now says to commit immediately after the check passes. The pre-commit hook is the gate; no conversational approval pause is inserted between a passing check and the commit.

**Upgrade steps**

No game-owned file changes. Framework files (`next-task.md`, `rules.md`) are replaced on upgrade.

## 3.3.0 (2026-10-05)

- **Recurring-warning suppression.** After each passing run, `check.sh` tracks how many consecutive passes each warning has appeared in. Once a warning hits the threshold (default 5, configurable as `recurring_threshold` in `check.cfg`'s new `[warnings]` section), it emits `check: note: recurring warning (N×): <text>`. The AI director then verifies whether the warning is genuinely benign and, with human approval, adds a matching substring to `tools/check.ignore` as an XS commit.
- **`tools/check.ignore`.** A new optional project file — one substring per line, `#` comments supported — whose entries are added to the allowlist that `check.sh` already builds. Approved suppressions take effect immediately on the next run. Changing the file invalidates the check cache.

**Upgrade steps**
1. In `check.cfg`, add the `[warnings]` section (see the updated template in `$GDIR/project/tools/check.cfg`). No values need changing; it documents the `recurring_threshold` option.

## 3.2.0 (2026-10-05)

- **Protected workspace (`director/`).** The human's personal space — reference art, sketches, audio files, notes. The agent reads files there for context but is blocked from creating, modifying or deleting anything inside it. Edit and Write tool hooks enforce this in Claude Code.
- **Ownership interview in onboarding.** Step 7 now goes through every work area (code, UI, art, audio, scene design, tunables, text) and asks who owns each. Human-owned areas get a documented placeholder policy. AGENTS.md now has an `## Ownership` table to record the result.

**Upgrade steps**
1. In AGENTS.md, add an `## Ownership` section (see `$GDIR/project/AGENTS.md` for the template). Fill it with the agreed ownership for each area, or leave the commented-out examples and fill it in conversation.
2. If the human owns any area, consider creating `director/` as their protected workspace. Ask them.

## 3.1.0 (2026-10-05)

- **`XS` and `XL` item sizes.** `XS` is a single value, label or line with no logic change and no new tests. `XL` is a cross-cutting refactor, a complete subsystem redesign, or a change touching most systems. `L` and `XL` items both trigger an independent review before commit.
- **Model sizing recommended on.** Onboarding now asks about it explicitly and recommends enabling it. When on, `XS` and `S` items run on the smallest capable model (Haiku in Claude Code); `M`, `L` and `XL` use the session model. The model tier table is now in `rules.md` so non-Claude tools have a definition to map to their own model names.
- **Upgrade path: fast and full modes.** Upgrades now have two explicit modes: fast (changelog steps only, the default) and full (re-run all content steps against the existing files). Changelog upgrade steps now explicitly cover game-owned files, so every project reaches the same capability level as a fresh install of the current version.

**Upgrade steps**
1. **Model sizing.** Check AGENTS.md › Project rules for a `Model sizing` line. If it is absent, ask the human whether to enable it (recommend yes), and add `Model sizing: on` if they agree.
2. **New sizes.** `XS` and `XL` are now available for new items. Existing `S`, `M` and `L` labels are unchanged; no edits to existing items are needed.

## 3.0.0 (2026-10-02)

**Claude4Godot is now Godot Director.** Everything that carried the old name is renamed; nothing else changes in how the workflow works.

- **Framework folder:** `.claude4godot/` is now `.godot-director/` (rules, procedures, `tasks.md`, `LICENSE`, `manifest`). The manifest header reads `# godot-director <version>`.
- **Upgrade files:** `<file>.c4g-new` is now `<file>.gdir-new`.
- **Runtime state:** the check's logs and state, the builder's marker and the review diff moved from `.godot/claude4godot/` to `.godot/godot-director/`.
- **Check meta:** while the check runs, `Engine.has_meta("godot_director_check")` is true. The old name, `claude4godot_check`, is still set during 3.x so games that haven't migrated keep working; it is deprecated and will be removed in 4.0.
- **Stop hook switch:** `CLAUDE4GODOT_STOP_CHECK=0` is now `GODOT_DIRECTOR_STOP_CHECK=0`.
- **Check output markers:** `C4G-FAIL`, `C4G-NOTE`, `C4G-IGNORE` are now `GDIR-FAIL`, `GDIR-NOTE`, `GDIR-IGNORE`. A test that expects an error prints `GDIR-IGNORE:<text>`; `C4G-IGNORE:` is still accepted during 3.x, deprecated, and will be removed in 4.0.
- **Plugin and marketplace:** both are `godot-director`. Install with `/plugin marketplace add Freakling/Godot-Director` and `/plugin install godot-director@godot-director`; the command is `/godot-director:godot-director`.
- **Manual install folder:** `Godot-Director/` in the game (was `Claude4Godot/`). The skill fetches into `${TMPDIR:-/tmp}/godot-director`.
- **`install.sh` migrates a 2.x install by itself.** When it finds `.claude4godot/manifest`, it moves `.claude4godot/` to `.godot-director/` (with `git mv` when the files are tracked), carries the manifest over so your edits to framework files are still recognised, renames leftover `*.c4g-new` files to `*.gdir-new`, updates the lines 2.x added to `.gitignore` and `.gitattributes`, updates this clone's pre-commit shim, and deletes `.godot/claude4godot/`. `tools/setup-clone.sh` replaces a 2.x shim in other clones.
- Onboarding detects an upgrade from either manifest.

**Upgrade steps**
1. In `AGENTS.md`, replace `.claude4godot/` with `.godot-director/` (the line that points to `rules.md`, and its `@.claude4godot/rules.md` import), and "Claude4Godot" with "Godot Director". Do the same in `CLAUDE.md` if it names either.
2. Do the same in the game's other files that mention them: the item-format line in `TASKS.md`, the conventions line in `design/gdd.md`, the header comment in `tools/check.cfg`, and the README's development section if it has one. Find them with `git grep -n -e claude4godot -e Claude4Godot -e CLAUDE4GODOT -e C4G- -e c4g-new` (a plain `c4g` also matches Godot uids). Leave history as it is: processed playtest reports, `design/decisions.md`, `TASKS-archive.md` and done items.
3. Replace `claude4godot_check` with `godot_director_check` in the game's own scripts: autoloads that guard player-data IO check `Engine.has_meta("godot_director_check")`, and so do tests of that guard. Likewise replace `C4G-IGNORE:` with `GDIR-IGNORE:` in tests that print it to expect an error. Run the check afterwards.
4. If `CLAUDE4GODOT_STOP_CHECK` is set in `.claude/settings.json` (or, per machine, `.claude/settings.local.json`; tell the human), rename it to `GODOT_DIRECTOR_STOP_CHECK`.
5. A manual-install `Claude4Godot/` folder inside the game: offer to delete it, and replace `/Claude4Godot/` in `.git/info/exclude` with the new folder's name if one is kept.
6. Tell the human: plugin users remove the old marketplace (`/plugin marketplace remove claude4godot`) and install again with the commands above; every other clone runs `bash tools/setup-clone.sh` once, which updates its pre-commit hook (the check notes it until then).
7. Commit with the moved folder staged as a rename (`git add -A -- .claude4godot .godot-director`).

## 2.0.2 (2026-10-01)
- **Install with `npx skills add Freakling/Godot-Director`.** The installer skill is now `skills/godot-director/` (Anthropic reserves "claude" in skill names) and works on its own: it uses the plugin's copy or a `Claude4Godot/` folder when there is one, and otherwise fetches Claude4Godot outside the game. Any assistant the skills CLI supports can install it, and installs list it on skills.sh.
- **The plugin command is now `/claude4godot:godot-director`** (was `/claude4godot:setup`), because the plugin uses the same skill.
- **The GitHub repository is now `Freakling/Godot-Director`.** The old address redirects; the install commands and the skill use the new one.

## 2.0.1 (2026-09-30)

- The check no longer mistakes a type annotation that names an autoload's inner type, such as `var store: GuildStorage.Store = …`, for a screen writing to the autoload. It also ignores capitalised members, which are types and constants that can't be assigned to. Found while migrating a real game.

## 2.0.0 (2026-09-30)

A rework of the foundation. It has fewer files to keep in sync, a core that works with any assistant, and rules enforced by tooling instead of by reminders. To migrate a 1.x project, follow `ONBOARDING.md`; it detects 1.x.

### One core for any assistant, adapters per tool
- **The tool-neutral core** is `.claude4godot/rules.md` and `.claude4godot/procedures/*.md`, plus `tools/` and `.githooks/`. A game's `AGENTS.md` points to it; most assistants read `AGENTS.md` natively.
- **The Claude Code adapter** lives in `.claude/`. Its skills are thin wrappers that point to the procedures. It also holds the `builder` subagent (builds each item in a fresh context, on Haiku for `S` items if model sizing is on) and the read-only `reviewer` subagent, permissions, a Stop hook that runs the check, and a guard hook that blocks risky git commands wherever they appear in the command line. A game's `CLAUDE.md` is `@AGENTS.md`.
- **`install.sh --tools claude|none`** picks the adapters. Adding an adapter for another assistant means adding its files; nothing needs restructuring.
- **A Claude Code plugin** (`/claude4godot:setup`) runs onboarding. It is only the installer: the workflow itself is committed in the game.
- **Cowork is gone,** along with everything that coordinated two tools. From a phone, use Claude Code's Remote Control or Dispatch.

### Context and tokens
- Builds run in the `builder` subagent (`.claude4godot/procedures/build.md`), one at a time and in the foreground. The main session keeps only its short report: result, files, how each outcome is met, systems and API/save changes, placeholders, questions and discovered work. So a session that works through several items ("do the next 3 tasks") stays small. A design question from a build comes with options, and the answer is recorded in the GDD before the rebuild.
- The TASKS.md item format moved to `.claude4godot/tasks.md`, which only the procedures that write items read. The always-loaded rules are smaller, for the main session and for every subagent.
- The records are the hand-off: after a commit, a fresh session or `/clear` loses nothing. A paused item gets a one-line `Note:`.
- Model sizing now only chooses the builder's model (Haiku for `S` items), which replaced the separate `dev-small` subagent.

### Verification
- **New `tools/check.sh` + `tools/check.gd`.** They replace `godot --headless --path . --quit`, which only parsed scripts the main scene reached, exited 0 on parse errors, and failed on a fresh clone. The new check:
  - runs the import pass on every run (new assets and `class_name`s need it, and it's quick when nothing changed);
  - loads every script, scene and resource;
  - runs the tests;
  - fails when a screen script uses randomness or assigns to an autoload;
  - scans Godot's output for errors;
  - exits 0 (pass), 1 (fail) or 3 (couldn't run).

  It locks against concurrent runs, and `--if-changed` reuses the last pass.
- **What the check doesn't do:** plain GDScript warnings aren't printed, since that needs `-d`, and `-d` can wait for debugger input. Raise the warnings that matter to Error in `project.godot`. `untyped_declaration=2` is the default; the `unsafe_*` warnings are left to each project, because they flag a lot of ordinary dynamic code.
- **A built-in test base,** `tools/test_case.gd`. Each test runs on a fresh instance, and tests that use `await` are rejected. GUT and gdUnit4 suites are skipped and can run from `tools/check.local.sh`.
- **`[screens] known`** in `tools/check.cfg` accepts known violations while "Decouple:" items fix them.
- **`tools/setup-clone.sh`** handles each clone:
  - It finds Godot and saves the path in `tools/godot_bin.local`. That file is gitignored, and is read by the check and the git hook alike; that's why the path isn't in `.claude/settings.local.json`, which only Claude Code reads.
  - It installs a small pre-commit hook in `.git/hooks`, instead of setting `core.hooksPath`, so Git LFS and existing hooks keep working.

### Fewer files, one home per fact
- **Removed:** `SYSTEMS.md`, `.promptx/` (six personas and the core principles), `playtesting/FUNCTION_CHECK.md`, GDD §10 and §13, and the README's status and responsibility sections.
- **`AGENTS.md`** holds project facts, the layout, the architecture table (formerly `SYSTEMS.md`) and project rules.
- **Personas became procedures:** `next-task`, `design`, `playtest`, `function-check`, `align`, `prune`, `review`. Rebaser, Merger and Multiplan Manager were dropped. Their few useful rules, such as TASKS.md merge conflicts and non-interactive history cleanup, moved into `rules.md`.

### Records
- **TASKS.md:**
  - one heading per item;
  - statuses `todo` / `in-progress YYYY-MM-DD` / `done` ("ready" is derived);
  - an owner field;
  - bugs in the same queue as `B` items;
  - milestones at the top;
  - a `Next IDs` line;
  - done items go to `TASKS-archive.md`.
- **`Done when` outcomes are tagged** `(test)`, `(check)` or `(play)`. "Done" means the tests and the check pass and the `(play)` outcomes are implemented. Function checks are built from the `(play)` outcomes, and `all` adds GDD rules no done item covers.
- **GDD:** no section numbers, and references use heading names. There's no version number either: git holds the history, and **`design/decisions.md`** records why each decision was made.
- **Playtests** are named by date, with the build hash. Design findings are proposed to the human, not applied directly.
- **Commits** are one per item, restricted to its own paths (`git commit -- <paths>`), so parallel sessions don't take each other's staged work.

### Godot guidance
- **Saves and settings** are JSON in `user://`. Resource, `ConfigFile` and `str_to_var` data is never loaded from player-editable files. Autoloads skip player data while the check runs (`Engine.has_meta("claude4godot_check")`).
- **Dev tools** are gated on `OS.is_debug_build()` or a feature tag, and excluded from release presets.
- **Rule classes** are `RefCounted` and testable; there's one system per script.
- **Placeholders** carry `## PLACEHOLDER` on the schema field, because Godot rewrites `.tres` files on save.
- **Syntax** is Godot 4 only, with the Godot 3 forms listed so they're avoided.

### Installing and upgrading
- **MIT license** (`LICENSE`). Installed games get a copy in `.claude4godot/LICENSE`, so the notice travels with the files.
- **`install.sh`** is deterministic:
  - It keeps a manifest in `.claude4godot/manifest`.
  - It replaces files you haven't changed, and keeps your edits when upstream didn't change the file. It writes `<file>.c4g-new` only when both changed.
  - It removes files that were dropped from the framework.
  - It compares contents the way git does, so CRLF checkouts don't count as edits.
  - It writes LF files and makes the scripts executable.
  - It refuses a folder that isn't a repository root.
- **The pre-commit hook** refuses while unmerged `.c4g-new` files exist.
- **`examples/market-day`** is a small worked example. **`selftest.sh`** tests the installer, the check, the hooks and the guard against it, and **`examples/scenarios.md`** lists behaviour checks to run by hand.
