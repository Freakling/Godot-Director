# Market Day · Game Design Document

<!-- How this document works
- It states the current design only. History is in git, the reason for each decision is in
  design/decisions.md, and anything undecided is under Open Questions. Agents write down only what
  the human decided.
- Refer to sections by heading ("GDD › Combat"), never by number. Add a subsection rather than
  growing a long one, and delete sections this game doesn't need.
- Say what a number is for and how it should feel; the values themselves live in data/*.tres.
- Engineering conventions live in .godot-director/rules.md, and project-specific ones in AGENTS.md ›
  Project rules, not here.
-->

## Pitch
A five-day grain market in one screen. Each day the price moves; buy low, sell high, and finish with enough gold to win.

## Design Pillars
1. **One decision a day:** every day asks only "buy, sell or wait?".
2. **Readable luck:** prices vary, but the player can see enough to make a reasoned bet.
3. **Two-minute runs:** a whole run fits in a coffee break.

Why each feature is built, and for whom: `design/user-stories.md`.

## Core Loop
### Moment to moment
Read today's price, then buy or sell grain one sack at a time.
### Session
Five days. Each day: trade, then press Next day. The market closes after day 5.
### Run / campaign
One run is one game; there's no campaign.
### Starting conditions
Some gold and no grain. Both amounts live in `data/market_config.tres`.

## Systems
### Market
- Each day grain has one price: the base price moved up or down by at most the swing. The swing is small enough that the price stays readable, but large enough that timing matters.
- Buying one sack costs today's price, and needs at least that much gold. Selling one sack earns today's price, and needs at least one sack.
- Prices are fixed for a run: the same run always has the same prices.

### Shop screen
- Shows the day, today's price, gold and grain, plus the buttons Buy grain, Sell grain and Next day.
- A button you can't use is disabled.
- From day 2 on, yesterday's price is shown next to today's.

## Difficulty and Scaling
The target is reachable with a few good trades but not by luck alone. Tuning is the human's job, in `data/market_config.tres`.

## Win and Loss
After day 5 the market closes. You win if your gold has reached the target, and lose otherwise.

## Presentation and Platforms
- Platforms: desktop
- Target aspect ratios: 16:9, scaled with `canvas_items`
- Input: mouse
- Camera: none (a single UI screen)
- Art direction: Godot's default UI theme until production art (human-made) replaces it.
- Audio: none yet
- Player settings: none yet

## Glossary
| Term | Meaning |
|---|---|
| Swing | how far the price may move from the base price, as a fraction |

## Open Questions
<!-- Numbered Q<n>, never reused. When one is answered: write the rule into its section, add a line
to design/decisions.md, and delete the question here. -->
**Next:** Q3

- **Q2** · Should unsold grain count toward the final gold when the market closes (for example at the last day's price), or be worth nothing? It changes whether buying on day 5 is ever right.
