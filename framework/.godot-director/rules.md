<!-- Godot Director · framework-owned: replaced on upgrade. Project-specific rules go in
AGENTS.md › Project rules, and win over these defaults. -->
# Godot Director workflow rules

These rules apply to any AI assistant working in this project. For each of these requests, follow the procedure in `.godot-director/procedures/`:
- **next-task.md:** do the next task(s), or a named item (T12, B3). The build itself is `build.md`.
- **design.md:** brainstorm, open design questions, change the design.
- **playtest.md:** new playtest, process a playtest.
- **function-check.md:** prepare or process a function check.
- **align.md:** check the docs and tasks are aligned.
- **prune.md:** prune the task list.
- **review.md:** review a finished change.

In Claude Code these are also slash commands, and builds and reviews run as the `builder` and `reviewer` subagents.

## The human decides
- The human owns design, balance, art direction and priorities. You build, keep the records, and propose.
- A design call is a mechanic, a rule, or anything the player feels that the GDD doesn't settle. For one, give 2–4 options with one recommendation and a one-line reason, then wait. Write down only what was chosen, following `design.md` › Record each decision. If you had to interpret the answer, say how you read it.
- Never answer an item in GDD › Open Questions yourself. Work that depends on one gets a placeholder that names the question.
- Something that seems to contradict a Design Pillar is flagged, never reinterpreted.

## Protected space
`director/` is the human's personal workspace — reference art, level sketches, audio stems, design notes, mood boards. Read files there for context when an item needs them, but never create, modify or delete anything inside it. If work depends on an asset the human owns, use the placeholder policy in AGENTS.md › Ownership instead of generating the real thing.

## Each fact lives in one place
| Fact | Only in |
|---|---|
| What the game should be | `design/gdd.md`. List its sections with `grep -n "^#" design/gdd.md` and read only the ones you need. |
| What's undecided | GDD › Open Questions (`Q<n>`) |
| Why a design decision was made | `design/decisions.md` (append-only) |
| Which systems exist and what each owns | `AGENTS.md` › Architecture |
| Work, bugs, milestones | `TASKS.md` (format: `.godot-director/tasks.md`; done items: `TASKS-archive.md`) |
| Tunable values | `.tres` files (folders in AGENTS.md › Layout) |
| Whether it works | `bash tools/check.sh` |

Update the owning place in the same change that makes it untrue. Replace superseded text; never strike it through or keep two versions. Refer to GDD sections by heading ("GDD › Combat"), never by number.

## Architecture defaults
- **Rule classes.** Game rules live in plain classes (`extends RefCounted`) that receive their data and don't touch the scene tree, so tests can build them directly. Autoloads hold the current state, call rule classes and emit signals. Each script owns one system; split a script that grows a second one.
- **Screens.** Screens show state and call system methods. They never roll random numbers or assign to autoload variables; the check fails if they do (screen folders are set in `tools/check.cfg`). Cosmetic randomness, such as screen shake or tips, goes in a helper outside the screen folders.
- **Tunables.** Tunables are `@export` fields on a Resource schema. A new one gets a placeholder default marked in the schema, `@export var drain_rate: float = 1.0 ## PLACEHOLDER`, and is never hand-picked as final. Don't put labels inside `.tres` files; Godot rewrites them on save.
- **Saves and settings.** They're plain data: `to_dict()`/`from_dict()` as JSON in `user://` (JSON numbers come back as floats; cast them). Never load `.tres`/`.res`, `ConfigFile` or `str_to_var` data from `user://` or any file a player can edit: those formats can instantiate scripts. The check runs autoloads, so an autoload must not read or write player data while `Engine.has_meta("godot_director_check")` is true.
- **UI.** Use Containers and anchors; no hard-coded pixel positions for Controls.
- **Placeholder art.** Use Godot primitives and flat colours under a node named `Visual`, so production art replaces it without restructuring the scene. No external models, textures or audio unless the human asks.
- **Debug-only tools.** Gate them on `OS.is_debug_build() or OS.has_feature("dev_tools")`. Release export presets don't set `dev_tools` and exclude the tools' folder. To see live state, use the editor's Remote scene tree instead of building an inspector.
- **GDScript.** Godot 4 and statically typed (`untyped_declaration` is an error). Use only Godot 4 forms: `@export`, `@onready`, `await`, `super()`, `signal hit(damage: int)`, `hit.connect(_on_hit)`, `CharacterBody2D`. Never `export var`, `onready var`, `yield`, `KinematicBody` or `connect("hit", self, "_on_hit")`.

## Doing the work
- **Where work comes from.** `TASKS.md`, or straight from the human. A direct request that won't be finished this session, or that turns up follow-up work, gets a TASKS.md item. Work you discover always becomes a new item; never do it silently as part of another.
- **Read what the work needs:** the item's `Touches`, the Architecture rows, and the GDD sections it names. Read by heading or line range, not whole files. Quote only the relevant lines of logs; the full check logs are in `.godot/godot-director/`.
- **Stay inside the item.** Prefer the smallest change, and delete dead code. Match existing patterns; a new pattern needs a reason in the commit message.
- **Tests.** A rule that can be checked without a screen gets a test: `tests/**/test_*.gd`, `extends "res://tools/test_case.gd"`, synchronous methods `test_*()`. A fixed bug gets a regression test when it can have one; otherwise it goes into the next function check.
- **Outcome tags.** Each outcome in `Done when` is tagged:
  - `(test)`: a test in `tests/` proves it;
  - `(check)`: a command you run and quote proves it, such as the check or a `grep`;
  - `(play)`: a human verifies it in the next function check.
- **Done** means every `(test)` and `(check)` outcome holds, every `(play)` outcome is implemented, and `bash tools/check.sh` exits 0. Never report done otherwise, and show the output of a failing check. Exit 3 means the check couldn't run, so say the work is unverified.
- **Running the check.** Run it in the foreground with a long timeout (10 minutes or more). Other runs and hooks wait for it.
- **Two failed attempts.** After two failed attempts at the same problem, stop and report instead of guessing further.

## Git
- **One item, one commit.** The message is `<type>: <summary> (T12)`, with a body saying why; types are `feat fix refactor test docs data chore`. The item's paths are its code, tests, data, the `.uid` files Godot writes next to new scripts, and the records the item changed (TASKS.md, AGENTS.md, and the GDD and decisions for a decision made during the item). `git add` the new ones, then commit only those paths, `git commit -m "…" -- <paths>`, so another session's staged work stays out.
- **Approval.** Commit only with the human's approval. An approval prompt from your tool counts; otherwise ask in the conversation, unless Project rules say otherwise. Push only when asked. Never get around the hooks (`--no-verify`, `core.hooksPath`).
- **Destructive commands.** Anything that discards uncommitted work or rewrites history needs the human. For a history cleanup they ask for, note the current tip first, and use non-interactive forms only.

## Sessions, clones and context
- **New clone or machine.** Run `bash tools/setup-clone.sh`. It finds Godot, writes `tools/godot_bin.local` (machine-local, never committed) and installs the pre-commit hook.
- **Two sessions at once** (say design and coding): give one its own worktree (`git worktree add ../game-design`) and run `bash tools/setup-clone.sh` there. A claim in TASKS.md protects only its own working tree. So only one session per project picks items; the others name the item they work on.
- **The records are the hand-off.** TASKS.md (what's done and what's next), commit messages (why), AGENTS.md and the GDD carry everything between sessions. Once an item is committed, a fresh session, or `/clear` in Claude Code, loses nothing.

## Reviews and model size
- An `L` or `XL` item, or an `M` item that changes save data or a system's public methods, gets an independent review (`review.md`) before its commit. Fix the findings that are in scope.
- **Model sizing** (when on in Project rules): match the build to the item's size. The model names below are for Claude Code; other tools use the closest equivalent.
  | Size | Model tier |
  |---|---|
  | `XS`, `S` | smallest capable model |
  | `M`, `L`, `XL` | session model |
  See `next-task.md` for Claude Code model names.
