<!-- Godot Director · framework-owned: replaced on upgrade. Project-specific rules go in
AGENTS.md › Project rules, and win over these defaults. -->
# Godot Director workflow rules

These rules apply to any AI assistant working in this project. For each of these requests, follow the procedure in `.godot-director/procedures/`:
- **next-task.md:** do the next task(s), or a named item (T12, B3, R2). The build itself is `build.md`.
- **design.md:** brainstorm, open design questions, change the design.
- **research.md:** research a question in a fresh context and save a dated note in `design/research/`, for a design call or a decision about plugins, assets, export or stores. It informs; the human decides. Domain reference: `.godot-director/research-domain.md`.
- **export.md:** export the game with Godot headless into `builds/` (`/export`), or set exports up: target platforms and where exports run. Setting up is a design session on the export open question.
- **release.md:** release the game's builds (`/release`): run the human's own upload command per export preset to a platform's UAT branch, and promote to production only when asked; or set release up: the commands, and the CI secrets they need. Setting up is a design session on the release open question.
- **ui-design.md:** capture the screens (`/ui-design`): a PNG per screen, state and size, with an element map, a numbered map image, layout lint and a starter drawing; process the human's Excalidraw drawing of a screen into a screen spec and items; verify a built screen against its spec and write compare images; list the screens in the catalog.
- **autoplay.md:** let the game play itself (`/autoplay`): play a scenario through the real game, review the play log into findings with a signature, step, screenshot, element map and repro, replay a failure. "Check the logs" after the human played ("I just played, check the logs") is `/autoplay --player`: the newest log a person played, reviewed in the same format.
- **playtest.md:** new playtest, process a playtest.
- **function-check.md:** prepare or process a function check.
- **align.md:** check the docs and tasks are aligned.
- **drift-reset.md:** reset the design when a pillar has been built more than one way, and later its postmortem. Only when the human asks: align often, reset when you have to.
- **prune.md:** prune the task list.
- **review.md:** review a finished change.
- **refresh-model-sizing.md:** scan available models and update the per-size model mapping in Project rules.

In Claude Code these are also slash commands, and builds, reviews and research run as the `builder`, `reviewer` and `researcher` subagents.

## The human decides
- The human owns design, balance, art direction and priorities. You build, keep the records, and propose.
- A design call is a mechanic, a rule, or anything the player feels that the GDD doesn't settle. For one, give 2-4 options with one recommendation and a one-line reason, then wait. Write down only what was chosen, following `design.md` › Record each decision. If you had to interpret the answer, say how you read it.
- Never answer an item in GDD › Open Questions yourself. Work that depends on one gets a placeholder that names the question.
- Something that seems to contradict a Design Pillar is flagged, never reinterpreted.
- Research informs a design call and never makes it. The `researcher` records no decision, never edits the GDD or `design/decisions.md`, never answers an open question, and never asks the human; its recommendation is shown as one option with its reason.

## Protected space
`director/` is the human's personal workspace: reference art, level sketches, audio stems, design notes, mood boards. Read files there for context when an item needs them, but never create, modify or delete anything inside it. If work depends on an asset the human owns, use the placeholder policy in AGENTS.md › Ownership instead of generating the real thing.

## Each fact lives in one place
| Fact | Only in |
|---|---|
| What the game should be | `design/gdd.md`. List its sections with `grep -n "^#" design/gdd.md` and read only the ones you need. |
| What's undecided | GDD › Open Questions (`Q<n>`) |
| Why a design decision was made | `design/decisions.md` (append-only) |
| The evidence behind a design call | `design/research/`, one dated note per topic; the decision line links to it |
| Which systems exist and what each owns | `AGENTS.md` › Architecture |
| How each screen is laid out | `design/ui/<screen>.md`, one spec per screen (`procedures/ui-design.md`) |
| The human's screen drawings | `director/ui/` (Excalidraw files; read-only for you) |
| Work, bugs, research, milestones | `TASKS.md` (format: `.godot-director/tasks.md`; done items: `TASKS-archive.md`) |
| Tunable values | `.tres` files (folders in AGENTS.md › Layout) |
| Whether it works | `bash tools/check.sh` |

Update the owning place in the same change that makes it untrue. Replace superseded text; never strike it through or keep two versions. Refer to GDD sections by heading ("GDD › Combat"), never by number.

## Architecture defaults
- **Rule classes.** Game rules live in plain classes (`extends RefCounted`) that receive their data and don't touch the scene tree, so tests can build them directly. Autoloads hold the current state, call rule classes and emit signals. Each script owns one system; split a script that grows a second one.
- **Screens.** Screens show state and call system methods. They never roll random numbers or assign to autoload variables; the check fails if they do (screen folders are set in `tools/check.cfg`). Cosmetic randomness, such as screen shake or tips, goes in a helper outside the screen folders.
- **Tunables.** Tunables are `@export` fields on a Resource schema. A new one gets a placeholder default marked in the schema, `@export var drain_rate: float = 1.0 ## PLACEHOLDER`, and is never hand-picked as final. Don't put labels inside `.tres` files; Godot rewrites them on save.
- **Saves and settings.** They're plain data: `to_dict()`/`from_dict()` as JSON in `user://` (JSON numbers come back as floats; cast them). Never load `.tres`/`.res`, `ConfigFile` or `str_to_var` data from `user://` or any file a player can edit: those formats can instantiate scripts. The check runs autoloads, so an autoload must not read or write player data while `Engine.has_meta("godot_director_check")` is true.
- **UI.** Use Containers and anchors; no hard-coded pixel positions for Controls. Every screen has an entry in the catalog, `tools/ui_screens.gd`; add or update it whenever you add or change a view. Elements a screen spec names get a unique node name (`%GearList`) that the spec, element maps and tests share. A capture (`tools/ui_capture.sh`) sets both `godot_director_check` and `godot_director_capture`, so an autoload that honours the check's meta (Saves and settings) also reads and writes no player data during a capture.
- **Placeholder art.** Use Godot primitives and flat colours under a node named `Visual`, so production art replaces it without restructuring the scene. No external models, textures or audio unless the human asks.
- **Debug-only tools.** Gate them on `OS.is_debug_build() or OS.has_feature("dev_tools")`. The dev menu follows the director's answer instead (AGENTS.md › Project rules, `Dev menu:`): the key in debug builds, the `debug/dev_menu` setting, or the `-- --dev-menu` flag, and it is absent when none applies. Release export presets don't set `dev_tools` and exclude the tools' folder. The play log isn't one of them: it ships in every build, so release exports keep `tools/play_log_base.gd` and `tools/play_log.gd`.
- **Everything is logged.** Every player action, every turn or tick step's outcome, every view change and every reason progress is blocked writes one play-log line with a stable `event` id: `PlayLog.log_event(category, event, text, data)` from the system that does the work. `PlayLog` is the game's autoload (`tools/play_log.gd`, which extends the framework's `tools/play_log_base.gd`); it writes a `.log` and a `.jsonl` per run in `user://logs/play/`, and nothing under the check. Tools read the `event` id (`trade.buy`), so keep it once shipped; the text may change. A feature isn't done until its lines exist and a test asserts on them through `PlayLog.start_capture()`.
- **Every action is drivable.** Every player action appears in the autoplay adapter's `list_actions()` while it's legal, with a `ui` route: an InputMap action (a key or a pad button) or a uniquely named control (`%EndTurn`).
- **Agent-visible state.** The agent can't see the editor's Remote scene tree. Hidden values it needs to judge a feature go in the dev menu's inspector and in the play log's snapshot. The inspector is a system's `debug_inspect() -> Dictionary` (and its `@export` values), shown once the system is registered in the game's dev menu: `register_system(name, node)` in `tools/dev_menu.gd`, which extends the framework's `tools/dev_menu_base.gd`, with the system's `debug_*` methods as its actions. A game whose AGENTS.md › Project rules says `Dev menu: none` has no inspector, so there the snapshot carries them: `_build_snapshot()` in `tools/play_log.gd`, logged with `PlayLog.log_snapshot()` at each point the player may act.
- **Seeded randomness.** Run-level randomness comes from one seeded `RandomNumberGenerator` that the run owns: the game seeds it when a run starts (autoplay through the adapter's `start_run(seed)`), logs the seed, and saves the generator's state with the run, so the same seed plays the same run and a reload can't reroll. Never call `randi()`, `randf()`, `shuffle()` or `pick_random()` on the global seed for anything that changes the run.
- **Privacy.** Autoplay, the play log and its review never send anything over the network; only a report the player consents to leaves the machine. Logs never hold the OS user name, the home path, an install id or raw text the player typed. The play log base scrubs the first three from every line (return the install id from `_install_id()`, and give secret settings names its `secret_names` matches), and logs input by InputMap action name, never as typed text.
- **GDScript.** Godot 4 and statically typed (`untyped_declaration` is an error). Use only Godot 4 forms: `@export`, `@onready`, `await`, `super()`, `signal hit(damage: int)`, `hit.connect(_on_hit)`, `CharacterBody2D`. Never `export var`, `onready var`, `yield`, `KinematicBody` or `connect("hit", self, "_on_hit")`.

## Doing the work
- **Where work comes from.** `TASKS.md`, or straight from the human. A direct request that won't be finished this session, or that turns up follow-up work, gets a TASKS.md item. Work you discover always becomes a new item; never do it silently as part of another.
- **Read what the work needs:** the item's `Touches`, the Architecture rows, and the GDD sections it names. Read by heading or line range, not whole files. Quote only the relevant lines of logs; the full check logs are in `.godot/godot-director/`.
- **Stay inside the item.** Prefer the smallest change, and delete dead code. Match existing patterns; a new pattern needs a reason in the commit message.
- **Tests.** A rule that can be checked without a screen gets a test: `tests/**/test_*.gd`, `extends "res://tools/test_case.gd"`, synchronous methods `test_*()`. A fixed bug gets a regression test when it can have one; otherwise it goes into the next function check.
- **Scenarios.** An item that touches the shell, a view, the turn loop or a save adds or updates a step in `tools/autoplay_scenarios.gd` that walks the change, and the builder plays the scenarios the item names, plus `smoke`, with `bash tools/autoplay.sh` before reporting (`procedures/autoplay.md`).
- **Outcome tags.** Each outcome in `Done when` is tagged:
  - `(test)`: a test in `tests/` proves it;
  - `(check)`: a command you run and quote proves it, such as the check or a `grep`;
  - `(autoplay)`: a scenario run by `bash tools/autoplay.sh` proves it, such as "the smoke scenario plays 10 turns with no new signature". The builder runs it and quotes the review's delta line; a function check marks it pre-verified.
  - `(play)`: a human verifies it in the next function check.
- **Done** means every `(test)`, `(check)` and `(autoplay)` outcome holds, every `(play)` outcome is implemented, and `bash tools/check.sh` exits 0. Never report done otherwise, and show the output of a failing check. Exit 3 means the check couldn't run, so say the work is unverified.
- **Running the check.** Run it in the foreground with a long timeout (10 minutes or more). Other runs and hooks wait for it.
- **Two failed attempts.** After two failed attempts at the same problem, stop and report instead of guessing further.

## Git
- **One item, one commit.** The message is `<type>: <summary> (T12)`, with a body saying why; types are `feat fix refactor test docs data chore`. The item's paths are its code, tests, data, the `.uid` files Godot writes next to new scripts, and the records the item changed (TASKS.md, AGENTS.md, and the GDD and decisions for a decision made during the item). `git add` the new ones, then commit only those paths, `git commit -m "…" -- <paths>`, so another session's staged work stays out.
- **Approval.** Commit only with the human's approval. An approval prompt from your tool counts; otherwise ask in the conversation, unless Project rules say otherwise. A run the human asked for (`next-task.md` › Several items) approves its commits in advance. Push only when asked. Never get around the hooks (`--no-verify`, `core.hooksPath`).
- **Destructive commands.** Anything that discards uncommitted work or rewrites history needs the human. For a history cleanup they ask for, note the current tip first, and use non-interactive forms only.

## Sessions, clones and context
- **New clone or machine.** Run `bash tools/setup-clone.sh`. It finds Godot, writes `tools/godot_bin.local` (machine-local, never committed) and installs the pre-commit hook.
- **Two sessions at once** (say design and coding): give one its own worktree (`git worktree add ../game-design`) and run `bash tools/setup-clone.sh` there. A claim in TASKS.md protects only its own working tree. So only one session per project picks items; the others name the item they work on.
- **The records are the hand-off.** TASKS.md (what's done and what's next), commit messages (why), AGENTS.md and the GDD carry everything between sessions. Once an item is committed, a fresh session, or `/clear` in Claude Code, loses nothing.

## Reviews and model size
- An `L` or `XL` item gets an independent review (`review.md`) before its commit. Fix the findings that are in scope. For `M` and smaller, the pre-commit hook and the builder's own testing are sufficient.
- Exception: an `M` item that rewrites the save codec (the `to_dict`/`from_dict` pair) or touches more than three system boundaries also gets a review.
- A research item (`R<n>`) gets no check run and no review: it changes no code. Its size picks the `researcher`'s model the same way.
- **Model sizing** (requires subagent spawning and per-subagent model selection): each item size maps to its own build model, in one of five tiers: `XS` and `S` (smallest/fastest), `M` (balanced), and `L` and `XL` (most capable). Run `/refresh-model-sizing`: it checks whether your tool supports the feature and, if so, proposes a mapping and writes it to Project rules. A size without an entry uses the session model.
