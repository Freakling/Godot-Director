<!-- Godot Director · framework-owned: replaced on upgrade. -->
# Research domain: Godot games

Read this when the question concerns the engine and its docs, plugins and assets, export and store requirements, or how other games solve a design problem. It adds to `procedures/research.md` and never repeats it. A question outside this domain stays technology-neutral, and every option gets the same evidence standard.

## The engine and its docs
- Use the Godot documentation for the engine version the project uses. Read the version from the project (`config/features` in `project.godot`, and AGENTS.md › Project facts), and check that a claim holds for that version, not only the latest one.
- Say when a feature differs between versions, and give the version each statement applies to.
- The official documentation and class reference are Tier 2. The engine's release notes and its issue tracker show known problems and changes.

## Plugins and assets
- For each plugin or asset, check how it is maintained, whether it works with the project's engine version, and its licence.
- Read the licence from the licence file or the listing you actually inspected, with the version it applies to. Include attribution and notice duties, and whether the licence allows the way the game is distributed.
- A plugin that is unmaintained, or built for another engine version, is a risk to name together with what it would cost the game.

## Export and store requirements
- Cover the export templates and settings for each target platform, for the project's engine version.
- Cover the terms the game must meet to be published: technical requirements, age ratings, and privacy and data declarations. Read them from the store's current published text; they are Tier 1 binding requirements.

## Comparable games as design references
- Look at how similar games solve the problem, in devlogs, postmortems, talks and reviews.
- Label them design references, not proof of what works for this game, and give them Low or Medium confidence.
- Note which Design Pillar each option serves or strains. If an idea contradicts a pillar, say so plainly; the human decides which gives way.
