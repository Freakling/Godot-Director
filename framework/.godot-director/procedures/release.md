<!-- Godot Director · framework-owned: replaced on upgrade. -->
# Release

Get the game's builds to the platforms. Godot Director knows no store: the human supplies one upload command per export preset for UAT (the platform's test branch or channel) and one for production, and `tools/release.sh` runs them. Never upload without the check passing, and never to production unless the human asks.

Two readers:
- **You were asked to release** (`/release`, "push a build to UAT", "promote to production"): read "Release the game".
- **You're setting release up** (onboarding, or the setup item a skipped onboarding step left): read "Set up release".

## Release the game
The request names the stage: `uat` (the default) or `production`, and optionally one preset.

1. **Ready?** `release.cfg` exists (if not, say so, point to GDD › Open Questions or to "Set up release" below, and stop), the working tree is clean, and `bash tools/check.sh` passes. If the check fails, stop: the build isn't worth shipping.
2. **UAT.**
   1. Export the presets with `export.md` › "Export the game" (`/export`). Stop if an export fails.
   2. Run `bash tools/release.sh uat [preset] --dry-run` and show the human which commands it would run.
   3. Run `bash tools/release.sh uat [preset]`. It uploads `builds/<preset>/` with each preset's `uat` command, after checking that every secret named in `release.cfg` is set in the environment. It stops before running anything if one isn't: say which names are missing, and that they come from the CI's secrets or the human's own shell, never from the repo or the chat.
3. **Production.** Only when the human asks to promote in this request, and after a passing UAT upload of the same commit (ask the human if you can't tell). Show the dry run, get a yes, then run `bash tools/release.sh production [preset]`. Production credentials belong to the human: if the environment lacks them, give the exact command and let the human run it.
4. **Report** per preset: the command that ran (never a secret value), its result, and the stage. The report is the record; write nothing to TASKS.md.

On GitHub Actions, the workflow in `.godot-director/templates/release-workflow.yml` runs the same commands: export on every change, UAT on `main`, and production behind a protected GitHub Environment the human approves. Any other CI can run the export command from `export.md` and then `bash tools/release.sh uat`.

## Set up release
Used by onboarding step 6 and by the setup item. Set exports up first if the game has none (`export.md` › "Set up exports"). Ask in short rounds, options with a recommendation, and let the human pick. Skip what `release.cfg` already answers.

1. **The upload commands.** For each export preset: the command that uploads `builds/<preset>/` to its UAT branch or channel, and the command for production. Any command that runs in a shell from the project root will do (a store's command-line tool, `rsync`, a script of the game's). Don't assume a store, and don't promise the tool is installed where the command will run. A preset with no production command is never promoted.
2. **Credentials.** Say what the commands need, and ask for the names of the environment variables that hold them (for example `STEAM_USER`, `ITCH_API_KEY`). Values are CI secrets only: the human sets them in the CI's secrets, never in the repo, `export_presets.cfg`, `release.cfg` or the chat. List the names back as the secrets to set.
3. **Write it down.**
   - `release.cfg` in the project root, committed: one section per preset, named exactly like the preset.

     ```
     [Web]
     uat = <command that uploads builds/Web to UAT>
     production = <command that uploads builds/Web to production>
     secrets = NAME_ONE, NAME_TWO
     ```

     Only names go in `secrets`; the commands read the values from the environment.
   - If the human uses GitHub Actions: copy `.godot-director/templates/release-workflow.yml` to `.github/workflows/release.yml` and fill in its marked lines (the Godot image for the project's version, the secrets under `env:`, a step that installs the upload tool). Tell the human to create a GitHub Environment named `production` with themselves as required reviewer, so the production job waits for their approval. Other CI services run the same commands.
   - `design/decisions.md`: one line for the release targets and one for where credentials live. AGENTS.md › Project rules: one line (for example "Release: `release.cfg` names the upload commands; secrets are CI secrets; `/release` promotes only when asked").
4. **Try it.** Run `bash tools/release.sh uat --dry-run` and report the commands it would run. Upload nothing during setup.

**When the human skips it.** Add the open question and the item, and nothing else:
- GDD › Open Questions: `- **Q<n>** · Release: what command uploads each export preset's build to UAT and to production, and which CI secrets does it need? Answering it sets up release: /design Q<n> runs the "Set up release" step.` Bump `Next`.
- TASKS.md:

  ```
  ### T<n> · Set up release · todo · M · agent
  - Depends on: Q<n>
  - Touches: release.cfg (new), AGENTS.md, .github/workflows/release.yml (new, if the human uses GitHub Actions)
  - Done when: `release.cfg` names an upload command for each preset Q<n>'s decision names, and `bash tools/release.sh uat --dry-run` lists them (check)
  - GDD: (none)
  ```

  The item is ready when Q<n> is no longer in Open Questions, so `/design Q<n>` runs the step above and records the decision, and `/next-task` builds the setup.
