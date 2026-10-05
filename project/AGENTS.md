# {{PROJECT_NAME}}

{{ONE_PARAGRAPH_PITCH}}

Instructions for AI assistants working on this game. The workflow is Godot Director: its rules are in `.godot-director/rules.md`, which names the procedure for each kind of request. Read it before any work, unless your tool has already loaded it (Claude Code imports it: @.godot-director/rules.md).

## Project facts
- Godot {{GODOT_VERSION}} · GDScript · {{DIMENSION}} · {{PLATFORMS}}
- Rendering and window: {{RENDERING}}

## Layout
<!-- The real folders of this project. Setup fills this in; keep it current when folders move. -->
| Folder | Holds |
|---|---|
| `scripts/autoload/` | autoloads: current state, signals |
| `scripts/systems/` | game-rule classes (`RefCounted`) |
| `scripts/resources/` | Resource schemas for tunable data |
| `scripts/ui/` | screen scripts (display only; checked by tools/check.cfg) |
| `scenes/` | scenes |
| `data/` | `.tres` content: the values the human tunes |
| `tests/` | rule tests (`test_*.gd`) |

## Architecture
One row per system: what it owns and where its boundary is. Screens depend on systems, never the other way round.

| System | Owns | Where | Talks to |
|---|---|---|---|
<!-- | `RunState` (autoload) | the current run: day, gold, roster | `scripts/autoload/run_state.gd` | calls `Market`; emits `changed` for screens | -->

## Project rules
<!-- Only where this project differs from the Godot Director defaults, as agreed with the human.
Examples:
- The agent may generate UI icons; all other art and audio stays human-made.
- No git remote: never push.
- Model sizing: on (recommended on; Claude Code only)
-->
