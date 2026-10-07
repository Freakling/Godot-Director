# Market Day

A five-day grain market in one screen. Each day the price moves; buy low, sell high, and finish with enough gold to win. A tiny example of a game run with Godot Director.

Instructions for AI assistants working on this game. The workflow is Godot Director: its rules are in `.godot-director/rules.md`, which names the procedure for each kind of request. Read it before any work, unless your tool has already loaded it (Claude Code imports it: @.godot-director/rules.md).

## Project facts
- Godot 4.3+ · GDScript · 2D (UI only) · desktop
- Rendering and window: Compatibility renderer, 640×360, stretch mode `canvas_items`

## Layout
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
| `RunState` (autoload) | the current run: day, gold, grain; applies trades | `scripts/autoload/run_state.gd` | uses `Market`; emits `changed` |
| `Market` | price per day, whether a trade is allowed, end and win conditions | `scripts/systems/market.gd` | reads `MarketConfig` |
| `MarketConfig` | tunable market values | `scripts/resources/market_config.gd`, `data/market_config.tres` | (none) |
| Shop screen | shows the run; buttons call `RunState` | `scenes/shop_screen.tscn`, `scripts/ui/shop_screen.gd` | reads `RunState`, listens to `changed` |

## Ownership
| Area | Owner | Placeholder |
|---|---|---|
| GDScript / game code | agent | (none) |
| UI / screen layout | agent | (none) |
| Art / sprites / textures | human | `ColorRect` under `Visual` node, labelled |
| Audio / music / SFX | human | `AudioStreamPlayer`, no stream, named |
| Scene / level design | agent | (none) |
| Tunable values (`data/`) | human | `## PLACEHOLDER` default in schema |
| Player-facing text | agent | (none) |

## Project rules
- No git remote: never push.
