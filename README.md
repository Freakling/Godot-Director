# Godot Director

<p align="center"><img src=".claude-plugin/icon.png" alt="Godot Director" width="160"></p>

**Make the game you designed, with AI doing the building and you staying the designer.**

A workflow for Godot projects, new or already in development. You decide the design, the balance and the priorities. The AI builds, tests and keeps the records. Built for Claude Code, and usable with any AI coding assistant that reads `AGENTS.md`. Everything lives in your game's own git repository.

## Why

AI writes game code fast. Without structure, that speed goes wrong in familiar ways:

- **The design drifts.** The AI quietly decides a mechanic or a number you never agreed to. With Godot Director, design calls come to you as 2–4 options with a recommendation. Only your choice is written down, and anything undecided goes on an open-questions list instead of being guessed.
- **"Done" means "it compiled".** One check defines "works": the whole project loads and the tests pass. It runs before every commit that touches code, and in Claude Code also before the AI ends its turn.
- **Rules end up inside UI screens.** Game rules live in testable classes and screens only display them. The check fails when a screen rolls dice or writes game state.
- **Context gets lost between sessions.** A few plain files hold everything: the design document, a decision log, the task queue, and an architecture table. Each fact has one home, so any session picks up where the last one stopped.

## How to use it

> You've read this far, so Godot Director may be what you're looking for. It's free and open source, and if it helps you make your game, a tip on Ko-fi or GitHub Sponsors helps me keep building it. I greatly appreciate your support.
>
> <a href='https://ko-fi.com/Q6J027VJG1' target='_blank'><img height='36' style='border:0px;height:36px;' src='https://storage.ko-fi.com/cdn/kofi5.png?v=6' border='0' alt='Support me on Ko-fi' /></a> <a href='https://github.com/sponsors/Freakling' target='_blank'><img height='36' style='border:0px;height:36px;' src='https://img.shields.io/badge/Sponsor-on%20GitHub-EA4AAA?logo=githubsponsors&logoColor=white&style=for-the-badge' border='0' alt='Sponsor me on GitHub' /></a>

### Install

Your game needs git (`git init` if it has none) and no uncommitted changes. You also need Godot 4.3 or newer, and bash (on Windows it comes with Git for Windows).

**Option 1: the skill.** In your game's folder, run:

```
npx skills add Freakling/Godot-Director
```

That gives your assistant access to the setup instructions. In Claude Code it becomes a `/godot-director` command; in other tools, ask your assistant to set up Godot Director and it will follow the same instructions. The skill fetches Godot Director outside your game and runs onboarding.

**Option 2: the Claude Code plugin.** In Claude Code:

```
/plugin marketplace add Freakling/Godot-Director
/plugin install godot-director@godot-director
```

Then open a new Claude Code session in your game's folder (or run `/reload-plugins`), and run `/godot-director:godot-director`.

**Option 3: manual install.** Put this repository in your game's root folder, next to `project.godot`, as a folder named `Godot-Director`. Either run `git clone https://github.com/Freakling/Godot-Director.git Godot-Director` there, or download the zip and rename the extracted `Godot-Director-main` folder. Then ask your assistant:

> Read Godot-Director/ONBOARDING.md and follow it to install Godot Director into this project.

Either way, onboarding works out whether this is a new game, an existing game, a Godot Director 1.x project to migrate, or an upgrade. It then:
1. installs the files and finds your Godot;
2. interviews you (new game) or reads the existing game;
3. agrees with you who owns what;
4. ends with one commit for you to approve.

Afterwards, restart Claude Code so the new commands load. Each new clone of the game later needs one command: `bash tools/setup-clone.sh`.

**With another AI assistant:** tell onboarding, and it installs the tool-neutral core only (`--tools none`); you can also keep the Claude adapter alongside. Your assistant reads `AGENTS.md`, which points it to `.godot-director/rules.md` and the procedures. The check and the git hook work the same for every tool, and for you. Note: Godot Director is built and tested on Claude Code. Other assistants should work in theory — the core is tool-neutral by design — but this is untested in practice. Reports welcome.

### Upgrade
- **Skill:** ask for the skill again (`/godot-director` in Claude Code); it fetches the latest Godot Director each time.
- **Plugin:** run `/plugin marketplace update godot-director` and then `/plugin update godot-director@godot-director`. Start a new session in the game, and run `/godot-director:godot-director` again.
- **Manual:** put the new Godot Director folder in the game, and ask for ONBOARDING.md again.

Only Godot Director's own files are replaced, and your edits to them are kept. When a new version also changes a file you edited, the new version is written next to it as `<file>.gdir-new` for you to merge. Review the result with `git diff`.

### Day to day

| Say | What happens |
|---|---|
| "Do the next task" (`/next-task`) | Builds the next ready item (high-severity bugs first), proves it with the check, updates the records, and asks you to approve the commit. |
| "Do the next 3 tasks", "Work through the queue" | The same, item after item, until one needs you. |
| "Which open questions block development?" (`/design questions`) | Ranks the open design questions by what they unblock, with options and a recommendation for each. |
| "Let's brainstorm {topic}" (`/design {topic}`) | A design session. Your decisions become GDD text, decision-log lines and task items. |
| "New playtest", "Process my playtest" (`/playtest`) | Creates a report from the template, or turns a filled-in one into bugs, score trends and design proposals. |
| "Prepare a function check", "Process the function check" (`/function-check`) | A checklist of what's been built since the last round and needs a human eye; you tick Works or Broken. |
| "Check the docs are aligned" (`/align`) | A consistency pass. Drift gets fixed; gaps and conflicts come to you. |
| "Prune the task list" (`/prune`) | Moves done items to `TASKS-archive.md`. |

```
you play, or have an idea
        │
        ▼
design session ── options + a recommendation ── you decide ──► GDD + decisions.md + TASKS.md items
        │
        ▼
next task ── builds the next ready item ── tests ── bash tools/check.sh ──► commit (you approve)
        │
        ▼
playtest (how it feels)   ·   function check (does each built rule work?)
        │
        ▼
bugs and design proposals ── you decide ── repeat
```

---

## What this is

### Who does what
| | Responsible for |
|---|---|
| **You** | Design, balance, art direction, priorities; playing and playtesting; approving commits. You have the final say on everything. |
| **The AI assistant** | GDScript, scenes, `.tres` schemas, placeholder art, tests, running Godot and git, keeping the records true. |

### What gets installed in your game
```
your-game/
│  yours: never overwritten
├── AGENTS.md                   for every assistant: project facts, layout, architecture, ownership, project rules
├── CLAUDE.md                   "@AGENTS.md", for Claude Code
├── TASKS.md                    milestones and the queue (tasks and bugs)
├── design/gdd.md               the game's current design, and Open Questions
├── design/decisions.md         why: one line per design decision
├── playtesting/TEMPLATE.md     playtest template, one section per core loop
├── tools/check.cfg             check settings: screen folders, folders to skip
│
│  Godot Director's, tool-neutral: updated on upgrade
├── .godot-director/rules.md      the workflow rules, loaded through AGENTS.md
├── .godot-director/tasks.md      the TASKS.md item format, read when items are written
├── .godot-director/procedures/   next-task · build · design · playtest · function-check · align · prune · review
├── tools/check.sh, check.gd    the check;  tools/test_case.gd: base for tests in tests/
├── tools/setup-clone.sh        per clone: finds Godot, installs the pre-commit hook
├── .githooks/pre-commit        runs the check before commits that touch code, scenes or data
├── playtesting/README.md       how playtests and function checks work
│
│  Godot Director's, Claude Code adapter: updated on upgrade
├── .claude/skills/             /next-task and the rest: each points to its procedure
├── .claude/agents/             builder (builds each item in a fresh context) · reviewer (read-only)
├── .claude/hooks/              runs the check before a turn ends; blocks risky git commands
└── .claude/settings.json       permissions, hooks, timeouts
```
Machine-local and gitignored: `tools/godot_bin.local` (the path to your Godot) and `.claude/settings.local.json`.

### The rules, briefly
The full rules are in `.godot-director/rules.md`, and the assistant reads them every session.
- **You decide design.** The assistant offers options and a recommendation. It never picks balance numbers (new values are marked `## PLACEHOLDER`), and never answers an open question itself.
- **Areas you own are never generated.** Onboarding asks who owns art, audio, scenes, tunables and text. Human-owned areas get a documented placeholder policy instead of generated content. `director/` is an optional protected workspace — the AI reads it for context but never creates, modifies or deletes anything inside it.
- **Each fact lives in one place,** and is updated in the same change that makes it untrue.
- **Rules live in systems, not screens.** They sit in plain classes that tests can build directly. Saves are JSON in `user://`, never Resources, which can run scripts when loaded.
- **Done means the check passes,** and the work is committed only with your approval.
- **Guarded git:** in Claude Code, force-push, `reset --hard`, `--no-verify` and other work-destroying commands are blocked by a hook that checks the whole command line. It's a strong safety net, not a guarantee.

### Context and token use

The designer (main session) and the developer (builder subagent) are deliberately separate contexts. Each optimises differently.

**The main session — designer and orchestrator**
- **Small at the start.** A session starts with about 10 KB of instructions (AGENTS.md and the rules). Each procedure, and the task format, loads only when it's used.
- **Stays small across items.** The main session picks items, records decisions, updates TASKS.md, and approves commits. It never reads the files being changed. After it hands an item to the builder and the report comes back, its context holds only that ~20-line report — not the source files, test output, or check logs the builder went through.
- **Nothing to hand off between sessions.** TASKS.md, the commits, AGENTS.md and the GDD hold everything. Once an item is committed, a new session (or `/clear` in Claude Code) loses nothing. An item interrupted mid-build gets a one-line `Note:` in TASKS.md; the next session reads it and resumes.
- **Design sessions: clear after each commit.** Once a design session's commit lands, the conversation has no value left — every decision is in the GDD and decisions.md. `/clear` before the next topic so you're not carrying a week of brainstorming into an unrelated question. The procedure reminds you at the end of each session.

**The builder subagent — developer with a fresh context**
- **Fresh context per item.** In Claude Code, each build runs as a separate `builder` subagent that starts with an empty context. It reads only what the item needs: the files in `Touches`, the relevant Architecture rows in AGENTS.md, and the GDD sections named in the item. It builds, runs the check, and returns a structured ~20-line report.
- **Isolation prevents accumulation.** Because the builder is isolated, the main session never carries the file contents, check logs, or edit history from the build. A session that works through ten tasks stays about as lean as one that worked through one.
- **The report is the only channel.** The builder's report fields (`Files`, `Done when`, `Systems`, `API/saves`, `Found`, `For the human`) give the main session exactly what it needs to update the records and decide what's next — no more.

**Model sizing** (recommended on): `XS` and `S` items run the builder on a smaller model (Haiku in Claude Code); `M` through `XL` use the session model. Onboarding asks you to choose; record it in AGENTS.md › Project rules.

### The check
`bash tools/check.sh` runs four steps:
1. Godot's import pass;
2. loads every script, scene and resource, checks screen scripts for game rules, and runs `tests/**/test_*.gd`;
3. scans Godot's output for errors;
4. runs `tools/check.local.sh`, if the game has one.

It exits 0 on pass, 1 on fail, and 3 when it can't run. It remembers the last passing state, so hooks don't run it again when nothing has changed. Game-specific settings go in `tools/check.cfg`, and extra steps (for example an existing GUT suite) go in `tools/check.local.sh`.

### This repository
| Path | |
|---|---|
| `ONBOARDING.md` | what the assistant follows to install, migrate or upgrade |
| `install.sh` | copies the files deterministically, keeps your edits, writes a manifest (`--tools claude\|none`) |
| `framework/` | installed into each game: the tool-neutral core, plus `.claude/` for Claude Code |
| `project/` | seeds for the game's own files, copied only when missing |
| `skills/godot-director/` | the installer skill, for `npx skills add` and the plugin |
| `.claude-plugin/` | the Claude Code plugin (`/godot-director:godot-director`) |
| `examples/market-day/` | a tiny game that uses the workflow: a worked example, and the self-test's fixture |
| `examples/scenarios.md` | prompts to try after changing the framework, to check that behaviour still holds |
| `selftest.sh` | tests the installer, the check and the hooks (`bash selftest.sh [path to Godot]`) |
| `CHANGELOG.md` | what changed, and the upgrade steps for games |
| `CLAUDE.md` | instructions for an assistant working on Godot Director itself |

## License
Privacy: Godot Director runs on your machine and sends nothing anywhere; see [PRIVACY.md](PRIVACY.md).

MIT © 2026 Vikingur Saemundsson: see [LICENSE](LICENSE). You may use, fork and change Godot Director, including in commercial games, as long as the copyright notice and the license stay with it. Installed games carry a copy in `.godot-director/LICENSE`.
