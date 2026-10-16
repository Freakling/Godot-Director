# Changelog

Each entry lists what changed. **Upgrade steps** at the end of an entry cover both framework fixes and game-owned file updates (AGENTS.md, TASKS.md, the GDD), so every project reaches the same capability level after upgrading. Onboarding carries them out; the fast upgrade mode runs only these steps, and the full mode also re-checks everything as if newly installed.

## Unreleased

- **Align checks the GDD against reality.** `align.md`'s item 6 is now "Brief against reality", in place of the Decisions spot-check. It reads the whole GDD, checks every statement of state (a section marked later or planned, a count, a list of what exists, a line saying work waits on something, "once X exists") against the built game, the done items and the latest releases, and checks every decision line since the last `docs: align` commit one by one, not a sample. Mechanical drift gets fixed; design calls are reported with the stale statement named.
  - **Upgrade steps:** none. The procedure is framework-owned and arrives on upgrade.

## 3.12.0 (2026-10-16)

- **The repository ignores OS metadata files.** A root `.gitignore` keeps `.DS_Store`, `Thumbs.db`, `desktop.ini` and `__MACOSX/` out of the repository, as the Claude plugin directory's scanner requires.
- **Fix: the protected-space guard blocks absolute paths.** `framework/.claude/hooks/guard-protected.sh` matched `file_path` only as written, so a write to `director/` sent as an absolute path (`<project>/director/x`, or Windows `C:\...\director\x`) got through. The hook now resolves the path against the project root (`$CLAUDE_PROJECT_DIR`, else the current directory) before matching: Windows, Git Bash and POSIX forms, `..` segments and case-insensitive matching on Windows. Paths outside the project root, and folders named `director` elsewhere in it, are still allowed. The selftest covers each form.
  - **Upgrade steps:** none. The hook is framework-owned and arrives on upgrade.
- **`/ui-design` tells you how to open and save the starter drawing.** The capture step gives one plain message: nothing to install, excalidraw.com in the browser with no account, how to open the starter (the menu's Open, or drag it in), how to save it as `director/ui/<screen>.excalidraw` (Save to… in Chrome and Edge, which let you pick the folder; other browsers save to Downloads, so move and rename the file), that the drawing stays on the machine unless Live collaboration or a shareable link is used, and "tell me when it's saved". The drawing guide seed (`design/ui/README.md`) gets a "Using Excalidraw" section with the same facts, plus the address-bar install.

**Upgrade steps**

None for games' own files. The `.gitignore` belongs to the Godot Director repository, and the hook is framework-owned and arrives on upgrade. An existing `design/ui/README.md` is the project's own and isn't rewritten; the capture step's message gives the same instructions the next time the agent hands over a starter drawing.

## 3.11.0 (2026-10-16)

- **New: `/ui-design` captures the game's screens** (`.godot-director/procedures/ui-design.md`). The agent sees the screens as a player does, and layout bugs that tests can't see are caught automatically.
  - **The catalog** (`tools/ui_screens.gd`, a project file extending the framework's `tools/ui_catalog.gd`) lists every screen, the scene it opens and how to put it in a representative state (`setup`, or named `states`), built through the game's public APIs and debug hooks, never player data. Unknown keys, duplicate ids and missing scenes are named. A new game's seed lists the main scene.
  - **`bash tools/ui_capture.sh [<screen>|--all]`** runs Godot with a display (headless Godot renders nothing; on Linux without one it uses `xvfb-run`) and renders each screen offscreen at each size with the project's stretch settings, so any size captures whatever the monitor. It writes to the gitignored `design/ui/captures/`, per screen, state and size in `tools/ui_capture.cfg`: the screenshot (`.png`), the element map (`.elements.json`: every visible control that is focusable, has text or has a unique name, with a stable id (a node Godot named is `Class#<index>`, so screens built in code map the same every time), its pixel and percent rect, focus order, overflow and minimum size, plus clickable 3D objects projected through the camera), the screenshot with every element outlined and numbered (`.map.png`), and the layout lint (`.lint.txt`). `--state` narrows it and `--size` captures one size; `--no-images` maps and lints without a display; `--list` prints the catalog. Exit codes as the check: 0, 1 when a screen fails (a script error in its setup, or a setup that doesn't finish within `[capture] setup_timeout`, goes to the top of its lint file, and the run goes on), 3 when it can't run (including when Godot can't open a window). Text is measured with a Label's own `label_settings` and `uppercase`.
  - **The lint** has seven rules: `squeezed-text`, `stretched-control`, `off-screen`, `overlap`, `unreachable`, `no-default-focus` and `hard-coded-position` (a warning). Findings are advisory and never change the exit code.
  - **Captures repeat and touch no player data.** Randomness is seeded per screen, the tree is paused before the screenshot (which stops Tweens and AnimationPlayers too), and `user://` points at a temporary folder that is deleted afterwards. `godot_director_check` and the new `godot_director_capture` meta are set, so autoloads that honour the check's meta skip saves and settings. `tools/ui_overlay.gd` redraws a map image headless.
  - **`rules.md`** names the procedure, and its UI rule now asks for a catalog entry for every screen and unique names for the elements a screen spec names. `.claude/settings.json` allows `bash tools/ui_capture.sh`. The installer adds `/design/ui/captures/` to `.gitignore` and `/tools/ui_*.gd text eol=lf` to `.gitattributes`.
  - **Selftest** checks the wiring and the install, lints a fixture screen built to break each rule and a clean one (headless, and again with a display), checks the catalog's error messages, and captures the example's screens at every size and at 7680x4320: the files, their size, no lint findings, nothing in `user://`, and the same element map twice, also for a screen built in code. A setup that never finishes fails only its screen. Without a display the capture checks are skipped. The example (`examples/market-day`) lists its shop screen in two states, and the screen now gives Buy the default focus.
- **New: `/ui-design process` turns your drawing of a screen into a screen spec** (`.godot-director/procedures/ui-design.md`). You draw over a screenshot in Excalidraw (free, open source, no account) instead of describing a layout; the agent reads exactly what you drew, asks about what it can't tell, and records the layout once.
  - **A starter drawing per screen.** `capture` also writes `design/ui/captures/<screen>.starter.excalidraw` for the default state at the default size: the screenshot locked inside a frame named after the screen, a faint locked group of the screen's mapped elements numbered as in the `.map.png` (hide or delete it), and a short legend beside the frame. Open it in Excalidraw, draw, and save it as `director/ui/<screen>.excalidraw`.
  - **`design/ui/README.md`** (a project seed, yours to annotate) tells you how to draw: one rectangle per thing, its name on the first line and details below (`shows:`, `does:` or `click:`, `key:`, `size:`, `stick:`, `scroll:`, `empty:`, `hidden when:`); colour says what changes (green new, blue keep but move or resize, red remove or a red X, orange not sure); a box inside a box is containment; an arrow from a note to a box is a comment; text outside the frame is notes for the screen (`mode: replace`); another frame for another state or size.
  - **`tools/ui_drawing.gd`** is the reader. It runs headless and writes `<screen>.drawing.json`, small and with no image, so the agent never reads the raw file: boxes with their label, text, `key: value` lines, intent, position and size in percent of the screenshot to 0.1 (the same however you moved or scaled the image), parent, comments, flows, and the existing elements each box covers; the elements a red X removes; the frame's notes and mode; and everything it didn't understand (a freehand line, an ellipse), so the agent asks rather than guesses.
  - **`/ui-design process <screen>`** reads the drawing, briefs you element by element, confirms the reading, settles each open point with options and a recommendation, and records in one change: the spec `design/ui/<screen>.md`, a decisions line per decision (`from: drawing ...`), the GDD only if the screen's behaviour changed, and one item per screen with the new optional `UI:` field. `rules.md` lists where each screen is laid out and where your drawings live (`director/ui/`, read-only for the agent), `tasks.md` describes `UI:`, and `design.md` sends layout questions to `/ui-design`.
  - **Selftest** checks the wiring and the install; reads a fixture drawing (a green box with bound text and `click:`, a blue box over an existing element, a red X, an arrowed comment, a nested box, a note outside the frame and a freehand squiggle) into exactly the expected `drawing.json`, and the same drawing with the image moved and scaled to 50% into the same percentages; and checks the starter against a hand-checked fixture and against Excalidraw's element types, and that saving it unchanged and reading it back yields no boxes and nothing unparsed. Opening a starter drawing in excalidraw.com is left to a person.

- **New: `/ui-design verify`, and `/ui-design` in the build, review, function check and align** (`.godot-director/procedures/ui-design.md`). A built screen is checked against its spec, and every step of the workflow that touches a screen uses the spec.
  - **`bash tools/ui_capture.sh <screen> --verify`** captures the screen, then reads `design/ui/<screen>.md`, the element maps and the lint files (headless; no display for this part) and prints one row per element of the spec's Layout table: present (an element with that unique name is on screen), where (every edge of its position within `tools/ui_capture.cfg` > `[verify] tolerance_pct` of the spec, default 4.0 percent of the screen), reachable (a focusable element has a focus order) and lint-clean. It also lists the elements with a unique name the spec doesn't, the lint findings in the screen's other states and sizes, and a drawn box whose element has since moved away from it, with both rectangles. Exit 0: no deviations; 1: deviations; 3: no spec or capture to check.
  - **Compare images.** With the drawing processed, verify writes `design/ui/captures/<screen>.compare@<W>x<H>.png` for each captured size: the screenshot the drawing was made over on the left, the new capture on the right with the drawing's boxes outlined, labelled `b1`, `b2` ... as in `drawing.json` and coloured by intent. `tools/ui_overlay.gd -- compare <capture>` redraws one.
  - **The workflow uses the spec.** `build.md` has a Screens step for an item with `UI:`: read the spec and `drawing.json`, build with Containers, give the elements their unique names, keep the catalog entry current, run `--verify`, and report a `Screen:` line (an unverified `(check)` outcome is said plainly when capture exits 3). `review.md` checks the item against the spec, the compare image and the lint output. `function-check.md` regenerates the compare images and asks you to judge the screen against your drawing. `align.md` lists screens the catalog doesn't cover (`bash tools/ui_capture.sh --missing`: never fails), specs naming things that don't exist, drawings changed since they were processed, and `UI:` fields pointing nowhere.
  - **Overlays.** Captures render each screen in its own viewport, so a HUD or toast layer an autoload draws wasn't in the image. A catalog entry can now name `"overlays": ["/root/Hud"]` (an autoload's node, moved into the screen's viewport for the shot and put back afterwards) or a scene to instance (`"res://scenes/toast.tscn"`), so captures show what players see.
  - **The layout lint in the check.** `tools/ui_capture.cfg` > `[lint]` gets `check_in_check` and `enforce`. With `check_in_check=true`, `bash tools/check.sh` runs one more headless Godot run, at the default size, for the screens in `enforce` (`["*"]` is all) and fails on a lint finding there; `hard-coded-position` is a warning and never fails. A missing key reads as off, and then the check is unchanged. A new game's seed has it on for every screen; an upgrade writes the seed with it off. The check's fingerprint now includes `tools/ui_capture.cfg`.
  - **Without images.** Every step of the procedure has a text path (the element map, `drawing.json`, the lint text and the verify table), gathered at the end of the procedure.
  - **Onboarding and the docs.** The ownership interview asks once whether you want to design screens by drawing (`UI / screen layout` becomes `director designs (director/ui/), agent builds`, and `director/ui/` and `director/.gdignore` are offered); declining changes nothing else. The AGENTS.md template's Layout lists `design/ui/`, and the README lists `/ui-design` and the installed files.
  - **Selftest** checks the wiring; verifies a fixture screen built as its spec says (no deviations) and the same screen with one node moved 10% (exactly that element); the drawn-box check; the compare image's size; overlays from a fixture autoload HUD and a scene; the lint in the check failing on a finding, passing on a clean screen and unchanged when off; and an upgrade of a v3.10.0 game (stubs, `.gitignore` line, manifest entries, its own `AGENTS.md` and `check.cfg` kept, the lint off, a screen missing from the catalog listed).

**Upgrade steps**

1. The installer creates `tools/ui_screens.gd` and `tools/ui_capture.cfg` when the game doesn't have them, and adds the `.gitignore` and `.gitattributes` lines; check that they're there, and commit the two files with their `.uid` files.
2. Replace the seed's main-scene entry in `tools/ui_screens.gd` with one entry per screen the game has (see `.godot-director/procedures/ui-design.md` › The catalog), or leave it for the next item that touches a screen.
3. `.claude/settings.json` is framework-owned; if you edited it, merge `.claude/settings.json.gdir-new` and keep `"Bash(bash tools/ui_capture.sh *)"` in `permissions.allow`. Restart Claude Code so the new skill loads.
4. The installer creates `design/ui/README.md` when the game doesn't have it. To design screens by drawing, create `director/ui/` and an empty `director/.gdignore` (so Godot doesn't import the PNGs you export there); `director/` is yours, and the agent never writes in it.
5. The installer writes `tools/ui_capture.cfg` with the layout lint in the check off (`check_in_check=false`, `enforce=[]`) when your game doesn't have it yet, and adds `tools/ui_verify.gd` to the framework files. A game that already has the file keeps it: add `check_in_check=false` and `enforce=[]` under `[lint]` and `tolerance_pct=4.0` under `[verify]` (a missing key reads as off and as 4.0). To turn the lint on, set `check_in_check=true` and list the screens whose capture is lint-clean in `enforce`; commit `tools/ui_capture.cfg` with it, since the check's fingerprint covers it.
6. Run `bash tools/ui_capture.sh --missing` (onboarding does this on an upgrade and reports; it never fails) and add a catalog entry for each screen scene it lists, or add the scene to `[capture] skip` if it isn't a screen. Give an entry the `overlays` a player sees over it (a HUD an autoload draws, for example `"overlays": ["/root/Hud"]`).
7. Add `design/ui/` to the Layout table in your AGENTS.md (the template's row reads: screen specs, and `captures/` (gitignored); the director's drawings are in `director/ui/`). If you want to design screens by drawing, set the `UI / screen layout` row in Ownership to `director designs (director/ui/), agent builds`, keeping its placeholder.
8. `.claude/skills/ui-design/SKILL.md` and the procedures `build.md`, `review.md`, `function-check.md` and `align.md` are framework-owned: if you edited one, merge its `.gdir-new` file. Restart Claude Code so the changed skill loads.

## 3.10.0 (2026-10-16)

- **New: `/release` and a release step in onboarding** (`.godot-director/procedures/release.md`). CI exports on every change; CD uploads builds to a platform's UAT branch or channel and, when you ask, promotes them to production.
  - **You supply the upload commands; Godot Director knows no store.** `release.cfg` in the project root has one section per export preset with a `uat` command, an optional `production` command, and `secrets`, the names of the environment variables the commands read. It is committed; only names are in it, never values.
  - **`/release` uploads to UAT and promotes only when asked.** It checks the working tree is clean and `bash tools/check.sh` passes, exports the presets (`/export`), shows a dry run, then runs `tools/release.sh uat`. Production needs your request, a passing UAT upload of the same commit and your yes. It never prints a secret.
  - **`tools/release.sh uat|production [preset] [--dry-run]`** runs the commands from `release.cfg` for the presets whose builds are in `builds/`, and stops before running anything when a build is missing or a named secret is unset. Any CI can run it after its own export.
  - **A GitHub Actions workflow template** (`.godot-director/templates/release-workflow.yml`, copied to `.github/workflows/release.yml`): it exports every preset on every push and pull request, uploads to UAT on `main`, and has a production job run by hand that waits for approval from a protected GitHub Environment named `production`.
  - **Credentials are CI secrets only.** Onboarding lists the secret names to set. They never go in the repo, `export_presets.cfg`, `release.cfg` or the chat.
  - **Onboarding offers the step** after exports, and you can skip it: a skip adds an open question to GDD › Open Questions and a "Set up release" item that depends on it, as for exports.
  - **Selftest** checks the wiring and the install, and runs `tools/release.sh` against a fake `release.cfg` with `echo` commands, so it needs no network, export templates or credentials.

**Upgrade steps**

1. Ask the human whether the game should release builds, and run ONBOARDING.md › 6 › Release: the upload commands, the secret names, and (for GitHub Actions) the workflow file. If the human skips it, add the open question and the "Set up release" item that `.godot-director/procedures/release.md` › "When the human skips it" gives, with the game's next `Q` and `T` numbers.

## 3.9.0 (2026-10-16)

- **New: `/export` and an export step in onboarding** (`.godot-director/procedures/export.md`). Exporting is Godot's own word for producing a game's binaries, so the skill is `/export`.
  - **`/export` exports the game.** It reads the presets in `export_presets.cfg`, finds Godot through `tools/godot_bin.local`, checks that the export templates for the project's engine version are installed (and says how to install them when they aren't), runs `--export-release` (or `--export-debug` on request) headless for each preset, and reports the files it produced. Builds go to `builds/<preset>/`, which is gitignored. It commits nothing and changes no source file.
  - **Onboarding asks for the export settings Godot doesn't have yet.** The target platforms, and where exports run: on your machine, in a build container (local or in the cloud), or on a hosted service such as GitHub Actions, with guidance to set it up. The answers become presets in `export_presets.cfg`, the platforms in the GDD, decision lines, and one line in AGENTS.md › Project rules. You can skip the step.
  - **A skipped step stays visible.** It adds an open question to GDD › Open Questions (which platforms, and where exports run) and a "Set up exports" item that depends on it. `/design Q<n>` runs the step later, and `/next-task` builds the setup once the question is answered. Changing exports later is a design session too.
  - **`Depends on` can name an open question.** An item that lists `Q<n>` there is ready once the question is no longer in Open Questions; `/next-task` and the item format say so.
  - **The installer** adds `/builds/` to the game's `.gitignore`.
  - **Selftest** checks that the procedure and skill exist and are wired into the rules, README, ONBOARDING and the skip path, that the installer ships them and the gitignore line, and needs no export templates. The example ignores `/builds/`, and the scenarios gain one for `/export`.

**Upgrade steps**

1. The installer adds `/builds/` to the game's `.gitignore`; check that the line is there.
2. Ask the human whether the game should have exports, and run ONBOARDING.md › 6 › Exports: the platforms and where exports run. If the game already has `export_presets.cfg`, read it first and ask only for what is missing. If the human skips it, add the open question and the "Set up exports" item that `.godot-director/procedures/export.md` › "When the human skips it" gives, with the game's next `Q` and `T` numbers (bump `Next` and `Next IDs`).

## 3.8.0 (2026-10-15)

- **The manual install clones the latest release.** The README's manual option cloned `main`, the integration branch, so a manual install got unreleased changes. It now clones the release tag (`git clone --branch <tag> --depth 1`), and says the tag is `v` followed by the version and where the latest one is listed; a release's source zip is the other way in. The manual upgrade wording still holds: put the new folder in and ask for ONBOARDING.md again.
- **Every install path gets the latest release.** The installer skill and the Claude Code plugin now install the release tagged `v<version>`; `main` is where changes are integrated, not what people install. The skill clones `--branch v<version>` into a fresh temporary folder, the way SaaSAllTheThings does, and deletes it after onboarding, instead of cloning `main` into a fixed folder and pulling it on reuse. The marketplace names the plugin as a `github` source with `ref` `v<version>`, because Claude Code's relative-path source (`./`) can't pin a ref. The skill's `metadata.version` said 3.3.0; it now follows `VERSION`. `CLAUDE.md` › After any change lists every file that carries the version and says each release is tagged `v<version>` once its pull request is merged. The selftest checks that the skill's version and the release it clones, and the marketplace's `ref`, agree with `VERSION`. The README says the skill and the plugin install the latest release, and that upgrading the skill means running `npx skills add` again.

**Upgrade steps**

None for the game's own files.

## 3.7.0 (2026-10-15)

- **New: `/research`, the research assistant** (`.godot-director/procedures/research.md`). When a design question depends on facts nobody has checked, or you ask for research, a read-only `researcher` subagent looks into it in a fresh context and reports a note. It informs; you decide: its recommendation is one option shown with its reason, and it never records a decision, edits the GDD or `design/decisions.md`, answers an open question, or asks you anything. It states its assumptions in the note instead.
  - **Research is a task type.** Research items get their own IDs, `R<n>`, drawn from the `Next IDs` line like bugs. Instead of `Done when` they have `Question:` and, when they feed an open question, `Informs: Q<n>`. They are sized like any item, and the size picks the model. An item is done when its note exists.
  - **Two ways to start.** On the fly: a design session delegates a complex question, or you run `/research <question>`, and the item is created and run at once. For later: queue the item, and list it under `Depends on` of the tasks that need its findings. A task that needs the decision stays gated by the open question itself.
  - **`/next-task` hands research items to the `researcher`.** No check runs and no review: research changes no code. This session writes the note to `design/research/YYYY-MM-DD-<slug>.md` and commits it with the records. A finished item that informs `Q<n>` makes that question ready for a design call, and a run goes on to the next item.
  - **Design sessions** list `design/research/` first, show notes on the topic in the context brief, delegate a question that needs facts, and end the decision's `why` with the note's path so later sessions reuse the evidence.
  - **The note** is one dated file per topic: the conclusion first, the options and trade-offs, the recommendation, every claim with its source, source tier and confidence, the date the claims were verified, and what stays unknown.
  - **A Godot domain file** (`.godot-director/research-domain.md`) is read when the question touches the engine and its docs for the project's version, plugins and assets and their licences, export and store requirements, or how comparable games solve the problem (design references, checked against the Design Pillars).
  - **Confidentiality.** Project text and unpublished design never go into a public search query or fetch.
  - **The researcher** has `Read`, `Grep`, `Glob`, `WebSearch` and `WebFetch`: no edit, write or shell tool. `.claude/settings.json` allows web search and fetch; everything with side effects keeps asking.
- **Align** checks that `Next IDs` has an `R` counter, that research items have a `Question:` instead of `Done when`, and that each done research item has its note.
- **Selftest** checks that the research files exist and are wired into the procedures, the item format, the seeds and the docs, that the researcher has no edit, write or shell tool, that the installer ships everything (including with `--tools none`), and that a research note commits without running the check.
- **The example** (`examples/market-day`) shows the `R` counter and the note folder, and the scenarios gain two for research.

**Upgrade steps**

1. **TASKS.md:** add an `R` counter to the `Next IDs` line, so `**Next IDs:** T12 · B3` becomes `**Next IDs:** T12 · B3 · R1`.
2. **`design/research/`:** the installer creates the folder with a short `README.md` (a project file, yours from then on) when the game doesn't have it. Notes are added there as research runs; commit them like the other records.
3. `.claude/settings.json` is framework-owned, so it is replaced on upgrade. If you edited it, the new version arrives as `.claude/settings.json.gdir-new`; merge it, and make sure `"WebSearch"` and `"WebFetch"` are in `permissions.allow`, which lets the researcher read the web without asking each time. Restart Claude Code afterwards so the new skill, subagent and permissions load.

No other game-owned file changes are required.

## 3.6.0 (2026-10-15)

- **README: Part of Director-Driven Development.** A new section after the opening description links the method and its three frameworks: Godot-Director, App-Director and SaaSAllTheThings.
- **The upgrade-file check ignores nested clones.** `git ls-files` lists a nested repository in an ignored folder (such as a clone in `work/`) as a directory, which blocked every commit while no upgrade file existed. The pre-commit hook, the `/align` check and onboarding now keep only paths that end in `.gdir-new`, so a real upgrade file still blocks the commit.
- **selftest.sh** checks that a nested clone in an ignored folder doesn't block a commit, and that a real upgrade file still does.
- **One commit model, shared with App-Director and SaaSAllTheThings.** One task, one commit, with the pre-commit check as the gate.
  - **A single `/next-task` pauses for your approval** of its commit (`next-task.md` step 7, which used to commit at once). The README and the behaviour scenarios already described it that way.
  - **A run commits without pausing.** When you ask for one ("grab tasks until you're blocked", "work through the queue", "the next N tasks"), each task commits as soon as its check passes. The run stops when an item is blocked on you, a build fails, or you decline a commit, and the final report lists every commit.
  - **`git commit` is allowed in `.claude/settings.json`** (it used to ask every time). Pushing, rebasing, restoring and `git config` still ask, and skipping the check with `--no-verify` is still denied.
  - `rules.md` › Git notes that a run you asked for approves its commits in advance; the `/next-task` skill description and the README's day-to-day table name the new phrase; the scenarios gain one for a run.

**Upgrade steps**

No game-owned file changes are required. `.claude/settings.json` is framework-owned, so it is replaced on upgrade. If you edited it, the new version arrives as `.claude/settings.json.gdir-new`; merge it, and make sure `Bash(git commit *)` is in `permissions.allow` and no longer in `permissions.ask` (an `ask` entry wins over `allow`, so the old entry would keep the prompt). Restart Claude Code afterwards so the changed skill description and permissions load.

## 3.5.0 (2026-10-09)

- **New: `/drift-reset`, the design drift reset** (`.godot-director/procedures/drift-reset.md`). For when a Design Pillar has been built more than one way and patching makes it worse. Only the human starts it, and in Claude Code the skill can't be invoked by the model. It recommends a branch of its own and works in `design/resets/YYYY-MM-DD/`, never deleting what it wrote there:
  1. **Analyse as built:** a read-only `reviewer` per area writes `as-built.md`, including where each rule lives (rule class or screen) and which rules the check wouldn't catch.
  2. **Map interpretations:** each pillar is classed consistent, divergent or contradictory, with playtests and function checks as evidence, in `interpretations.md`.
  3. **Rewrite the design:** every conflict is a design call as in `/design`; the old GDD is kept as `gdd-before.md`, and only the human's choices reach `decisions.md`.
  4. **Plan the rebuild:** sized TASKS.md items with exact `Touches`, listed in `plan.md`; the rebuild runs through `/next-task`.
  5. **`/drift-reset postmortem`:** checks the rebuild against `interpretations.md` and proposes new tests or `tools/check.cfg` patterns, as design calls, for drift that could be caught automatically next time.

  The reset writes no code and never rewrites human-owned areas; a tunable value in the drift becomes a design call.
- **Align recommends a reset** when a conflict that `decisions.md` already settled comes back, or one conflict involves several pillars. Align often, reset when you have to.
- **Reviewer subagent** can also analyse one area for a drift reset; it stays read-only.
- **Selftest:** checks that `rules.md` names every procedure, that align recommends the reset, and that the drift-reset skill can't be invoked by the model.

**Upgrade steps**

No game-owned file changes are required. In Claude Code, restart the session so the new skill loads.

## 3.4.6 (2026-10-09)

- **Design session context brief.** The design procedure now has a "Brief the human" step between Prepare and the first question. Before asking anything, the AI presents the relevant GDD lines (quoted or summarised), the related entries from `design/decisions.md` (date, decision, why), and the scope of questions to address - then asks if anything is missing. The human director gets the context they need to make decisions without having to pull it from memory.

**Upgrade steps**

No game-owned file changes are required.

## 3.4.5 (2026-10-07)

- **No en or em dashes.** All 71 occurrences of Unicode en dashes (U+2013) and em dashes (U+2014) across the repository are replaced with ASCII equivalents chosen by meaning: hyphens for numeric ranges, colons for explanatory clauses, semicolons for independent clause joins, and commas or parentheses for parenthetical asides. The em-dash null-marker in task headings and tables becomes `(none)`.
- **Selftest assertion.** `selftest.sh` now fails if any tracked text file contains a U+2013 or U+2014 character.
- **Style rule in CLAUDE.md.** Future agents working on the framework are told to use hyphens, colons, semicolons, and parentheses; no typographic dashes.

**Upgrade steps**

No game-owned file changes are required. If your game's own files (AGENTS.md, TASKS.md, GDD) use an em dash as a null marker in task headings or table cells, replace it with `(none)` for consistency. No other changes are necessary.

## 3.4.4 (2026-10-07)

- **Tool-neutral model sizing rules.** `rules.md` no longer contains model IDs; it now describes five capability tiers only (`XS`/`S`: smallest/fastest; `M`: balanced; `L`/`XL`: most capable). Canonical defaults live only in `refresh-model-sizing.md` and `ONBOARDING.md`, keeping the framework core independent of any specific assistant's model names.
- **README model-sizing paragraph.** Replaced the stale two-tier summary with the canonical paragraph: per-size mapping, Claude Code defaults by tier name, escalation on failure, and how to update.
- **Escalation rule in next-task.** A failed build now retries once on the next-size model (not the session model). An `XL` failure (already on the largest model) stops and comes to the director.
- **Selftest assertion.** The self-test now checks that model IDs in `ONBOARDING.md` match the Claude Code defaults table in `refresh-model-sizing.md`, so a slip between the two files fails CI immediately.

**Upgrade steps**

Run `/refresh-model-sizing` to confirm or update your model mapping. No hand-edits to framework files are needed; the procedure writes `AGENTS.md` for you.

## 3.4.3 (2026-10-07)

- **Consistent assistant-support position.** Every claim about which assistants work with Godot Director now uses one position: designed to work with any assistant that reads `AGENTS.md`; built and tested on Claude Code only; other assistants are untested. Previous hedges ("should work in theory", "every tool") and unnamed-assistant mentions are removed. The capability note in the README's "other assistant" section now states exactly which features depend on subagent and hook support.
- **`npx skills add` description tightened.** States only what it does: installs the skill for the assistant you choose in the prompt; in Claude Code it becomes a slash command. No other assistants are named.
- **Release-notes rule updated.** `CLAUDE.md` now requires the canonical assistant-support wording in "How to install" sections of release notes.

**Upgrade steps**

No game-owned file changes.

## 3.4.2 (2026-10-07)

- **Role terminology aligned.** "Designer" and "developer" as role names are replaced with the canonical Director-model terms throughout: the human is the **director**, the main session is the **orchestrator**, the build subagent is the **builder**, the review subagent is the **reviewer**. "Design" as an activity (design sessions, design calls, the GDD, the `design` skill) is unchanged.

**Upgrade steps**

No framework file changes affect installed games. Existing `AGENTS.md` files may keep the old terms. Updating them is optional.

## 3.4.1 (2026-10-07)

- **Per-size model mapping.** Each of the five item sizes (`XS`, `S`, `M`, `L`, `XL`) now maps to its own model ID, stored in AGENTS.md › Project rules. The previous two-tier rule (Haiku for XS/S, session model for everything else) is replaced by five independent entries. Default Claude Code mapping: XS/S → `claude-haiku-4-5-20251001`, M → `claude-sonnet-5-5`, L/XL → `claude-opus-5-5` (`claude-fable-5-1` is an alternative for XL on Claude platform / usage credits).
- **`/refresh-model-sizing` skill.** A new skill and procedure. It first checks whether the current assistant supports subagent spawning with per-subagent model selection; if not, it tells the human and stops without writing anything. If yes (Claude Code by default; other capable tools also supported), it proposes a mapping, confirms with the human, and writes it to Project rules. Run it when models change or on a new machine.
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
   Or run `/refresh-model-sizing`: it will detect the environment and propose the mapping for you.

## 3.4.0 (2026-10-06)

- **Builder skips final check.** The `builder` subagent no longer runs `bash tools/check.sh` at the end of its build. Step 4 of `next-task.md` runs the check from the outer session, and the pre-commit hook is the safety net; the third invocation was ~2 minutes of waste per task.
- **Review threshold raised to L and XL.** `M` items no longer trigger an independent review by default. The pre-commit hook and the builder's own testing are sufficient at that scale. Exception: an `M` item that rewrites the save codec (`to_dict`/`from_dict` pair) or touches more than three system boundaries still gets a review.
- **Auto-commit during autonomous work.** `next-task.md` now says to commit immediately after the check passes. The pre-commit hook is the gate; no conversational approval pause is inserted between a passing check and the commit.

**Upgrade steps**

No game-owned file changes. Framework files (`next-task.md`, `rules.md`) are replaced on upgrade.

## 3.3.0 (2026-10-05)

- **Recurring-warning suppression.** After each passing run, `check.sh` tracks how many consecutive passes each warning has appeared in. Once a warning hits the threshold (default 5, configurable as `recurring_threshold` in `check.cfg`'s new `[warnings]` section), it emits `check: note: recurring warning (N×): <text>`. The AI director then verifies whether the warning is genuinely benign and, with human approval, adds a matching substring to `tools/check.ignore` as an XS commit.
- **`tools/check.ignore`.** A new optional project file: one substring per line, `#` comments supported. Its entries are added to the allowlist that `check.sh` already builds. Approved suppressions take effect immediately on the next run. Changing the file invalidates the check cache.

**Upgrade steps**
1. In `check.cfg`, add the `[warnings]` section (see the updated template in `$GDIR/project/tools/check.cfg`). No values need changing; it documents the `recurring_threshold` option.

## 3.2.0 (2026-10-05)

- **Protected workspace (`director/`).** The human's personal space: reference art, sketches, audio files, notes. The agent reads files there for context but is blocked from creating, modifying or deleting anything inside it. Edit and Write tool hooks enforce this in Claude Code.
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
