# User stories: Market Day

Whom the game is for, and why each feature is built: the value for each role, the roles, and one table of stories per Design Pillar or system in the GDD. Every feature item in `TASKS.md` names the stories it serves (`Stories:`). The AI drafts stories; the director confirms them.

**Next ID:** US-6 · **Last validated:** 2026-09-28 at `3f9c2a1`

<!-- How this file works (.godot-director/procedures/design.md › User stories):
     - A story is one thing a role does in the game and why, in the role's words: "As a player I <do something>, so <why>". It never says how it's built.
     - Each table sits under the heading of a Design Pillar or a system in the GDD.
     - Confirmed: the date the director last confirmed the story as it reads now, or `unconfirmed` (drafted, not confirmed yet).
     - Next ID: the ID the next story gets; bump it. IDs are never reused: a dropped story's row is deleted.
     - Last validated: `never`, or the date and commit of the last validation, such as 2026-11-14 at `4e1f0c2`
       (the date alone while the repository has no commit yet).
       /next-task proposes the next one after [stories] every built items (tools/check.cfg). -->

## The value in one paragraph per role

- **Player:** a market you can read in a glance and play in a coffee break. Each day asks one question, buy, sell or wait, and the run ends after five days with a clear win or loss you can trace back to your own trades.

## Roles

- **Player:** anyone playing a run.

## One decision a day

| ID | Story | Confirmed |
|---|---|---|
| US-1 | As a player I see the day, today's price, my gold and my grain on one screen, so I can decide to buy, sell or wait at a glance. | 2026-09-29 |
| US-2 | As a player I buy or sell one sack at a time, and a trade I can't make is greyed out, so every press is a choice I meant. | 2026-09-29 |

## Readable luck

| ID | Story | Confirmed |
|---|---|---|
| US-3 | As a player I see yesterday's price next to today's, so I can tell whether today's price is high or low. | 2026-09-28 |
| US-4 | As a player I get the same prices when I replay a run, so I can work out afterwards what I should have done. | 2026-09-29 |

## Two-minute runs

| ID | Story | Confirmed |
|---|---|---|
| US-5 | As a player I finish a run in five days and see at once whether I won, so a whole game fits in a coffee break. | 2026-09-25 |
