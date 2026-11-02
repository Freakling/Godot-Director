<!-- Godot Director user stories template · framework-owned: replaced on upgrade. Turning the stories on copies it to design/user-stories.md without this line (.godot-director/procedures/design.md › User stories); the copy is the game's own. -->
# User stories: {{PROJECT_NAME}}

Whom the game is for, and why each feature is built: the value for each role, the roles, and one table of stories per Design Pillar or system in the GDD. Every feature item in `TASKS.md` names the stories it serves (`Stories:`). The AI drafts stories; the director confirms them.

**Next ID:** US-6 · **Last validated:** never

<!-- How this file works (.godot-director/procedures/design.md › User stories):
     - A story is one thing a role does in the game and why, in the role's words: "As a player I <do something>, so <why>". It never says how it's built.
     - Each table sits under the heading of a Design Pillar or a system in the GDD.
     - Confirmed: the date the director last confirmed the story as it reads now, or `unconfirmed` (drafted, not confirmed yet).
     - Next ID: the ID the next story gets; bump it. IDs are never reused: a dropped story's row is deleted.
     - Last validated: `never`, or the date and commit of the last validation, such as 2026-11-14 at `4e1f0c2`
       (the date alone while the repository has no commit yet).
       /next-task proposes the next one after [stories] every built items (tools/check.cfg).
     The roles and stories below are a worked example, a small fishing game. Turning the stories on replaces them with this game's own. -->

## The value in one paragraph per role

- **Player:** a quiet evening at the pond. Every cast teaches you something about where the fish are, and the evening ends at sunset with a catch to sell and a reason to come back tomorrow.
- **Streamer:** a calm game that reads well on stream. Viewers can follow each cast and each bite, and every evening ends on a moment to react to.

## Roles

- **Player:** anyone playing the game.
- **Streamer:** a player who plays it live for an audience.

## Every cast teaches

| ID | Story | Confirmed |
|---|---|---|
| US-1 | As a player I see where my line lands and what bit, so I learn the pond with each cast. | 2026-11-01 |
| US-2 | As a player I feel a bite as a tug on the rod before I see the fish, so I strike at the right moment. | 2026-11-01 |
| US-3 | As a player I look up the fish I've caught and where I caught them, so I can plan where to cast next. | unconfirmed |

## Ten-minute evenings

| ID | Story | Confirmed |
|---|---|---|
| US-4 | As a player I sell my catch at the dock when the sun sets, so each evening ends with a clear result. | 2026-11-01 |
| US-5 | As a streamer I show the evening's catch on one screen at sunset, so my viewers get a moment to react to. | unconfirmed |
