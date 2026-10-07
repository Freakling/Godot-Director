# Tasks

Milestones, the work queue and bugs: the only place work is tracked. Item format: `.godot-director/tasks.md`. Queue order is priority; reorder by moving items. Pruning moves done items to `TASKS-archive.md`.

**Next IDs:** T7 · B2

## Milestones
| Milestone | Status |
|---|---|
| Design: pitch, pillars and core loop decided | 🟨 all but Q2 (unsold grain) |
| Foundation: project settings, first system with a test, check passing | ✅ |
| Core loop playable (grey-box) | ✅ one screen, five days |
| Content & balance: no `## PLACEHOLDER` left (human) | 🟨 4 placeholders in `market_config.gd` |
| Production art and audio replace placeholders (human) | ⬜ |

✅ done · 🟨 in progress · ⬜ not started

## Queue

### T1 · The check passes on a clean clone · done · S · agent
- Depends on: (none)
- Touches: project.godot, tools/check.cfg
- Done when: `bash tools/check.sh` exits 0 after deleting `.godot/` (check)
- GDD: (none)

### T2 · Grain price moves each day · done · M · agent
- Depends on: T1
- Touches: scripts/systems/market.gd (new), scripts/resources/market_config.gd (new), data/market_config.tres (new), tests/test_market.gd (new)
- Done when: the price stays within ±swing of the base (test) · the same seed gives the same prices (test) · the shop shows today's price (play)
- GDD: Systems › Market

### T3 · Shop screen: buy, sell, next day · done · M · agent
- Depends on: T2
- Touches: scripts/autoload/run_state.gd (new), scripts/ui/shop_screen.gd (new), scenes/shop_screen.tscn (new), project.godot
- Done when: buying needs enough gold (test) · each button updates the status line at once (play)
- GDD: Systems › Shop screen

### T4 · The run ends after day 5, won or lost · done · S · agent
- Depends on: T3
- Touches: scripts/systems/market.gd (+is_over, +is_won), scripts/ui/shop_screen.gd, tests/test_market.gd
- Done when: the run is over after the last day and won at the target (test) · after day 5 the screen says whether you won (play)
- GDD: Win and Loss

### B1 · Buy stays clickable when you can't afford grain · todo · S · agent · low
- Repro: start a run, buy until gold is below the price → expected: Buy is disabled / actual: Buy looks enabled and does nothing
- Found in: playtesting/2026-09-28-playtest.md
- Touches: scripts/ui/shop_screen.gd
- GDD: Systems › Shop screen

### T5 · Show yesterday's price next to today's · todo · S · agent
- Depends on: T3
- Touches: scripts/ui/shop_screen.gd, scripts/autoload/run_state.gd (+previous_price)
- Done when: from day 2 on, the status line shows yesterday's price (play)
- GDD: Systems › Shop screen

### T6 · Tune the market values · todo · (none) · human
- Depends on: T5
- Touches: data/market_config.tres
- Done when: no `## PLACEHOLDER` left in `market_config.gd` (check) · a full run is winnable but not trivial (play)
- GDD: Difficulty and Scaling

## Notes
- T5 and B1 both edit `shop_screen.gd`; do them in one session, or one after the other.
