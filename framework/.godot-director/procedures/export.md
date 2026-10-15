<!-- Godot Director · framework-owned: replaced on upgrade. -->
# Export

Produce the game's binaries with Godot's own export. Godot calls this exporting: the export presets in `export_presets.cfg`, the export templates, and `--export-release` and `--export-debug` on the command line.

Two readers:
- **You were asked to export** (`/export`, "export the game", "make a build"): read "Export the game".
- **You're setting exports up** (onboarding, or the setup item a skipped onboarding step left): read "Set up exports".

## Export the game
Exporting changes no source file and commits nothing. It writes builds to `builds/`, which is gitignored.

1. **Find Godot.** The path is the first line of `tools/godot_bin.local` (written by `bash tools/setup-clone.sh`), or `$GODOT_BIN`. If neither exists, run `bash tools/setup-clone.sh --skip-hook`. Below, `$GODOT_BIN` stands for that path.
2. **Find the presets.** Read `export_presets.cfg` in the project root and list each `[preset.N]` with its `name=` and `platform=`.
   - No file or no presets: say so, and point to GDD › Open Questions (a question about export platforms means the setup was skipped: offer `/design Q<n>`) or to "Set up exports" below. Stop.
   - A request for one platform or preset exports only that one; otherwise export every preset that isn't marked `runnable=false` for a reason you can see, and skip none silently.
3. **Check the export templates.** `"$GODOT_BIN" --version` prints the version, such as `4.3.stable.official.77dcf97d8`; the template folder name is that output up to and including the status word (`4.3.stable`, `4.2.1.stable`, or `4.4.rc.1`). A preset needs that folder under the export templates directory:
   - Windows: `%APPDATA%\Godot\export_templates\<version>\`
   - macOS: `~/Library/Application Support/Godot/export_templates/<version>/`
   - Linux: `~/.local/share/godot/export_templates/<version>/`

   If the folder is missing or empty, don't try the export. Say how to install them, and stop: in the editor, Editor > Manage Export Templates > Download and Install; or download `Godot_v<version>_export_templates.tpz` from Godot's release page, then Install From File in the same dialog. A machine without a display can unzip the `.tpz` into that folder, so its `templates/` contents sit directly in `<version>/`.
4. **Export each preset** from the project root, release unless the human asked for debug:

   ```
   "$GODOT_BIN" --headless --path . --export-release "<preset name>" "builds/<preset name>/<file name>"
   ```

   The file name comes from the preset's `export_path` (keep its extension: `.exe`, `.x86_64`, `.zip`, `.html`, `.apk`, ...). Create `builds/<preset name>/` first. For a debug build use `--export-debug` and a folder name ending in `-debug`. Use the Windows `*_console.exe` Godot where there is a choice, so the output reaches you.
5. **Report** per preset: the output file and its size, or the failing lines of Godot's output and what they point to (a missing template, a missing Android SDK or keystore, an unset icon, a script error). Say where the builds are. The report is the record; write nothing to TASKS.md.

Exporting doesn't run the check (`bash tools/check.sh`). If an export fails on a script error, say so and offer to run it.

## Set up exports
Used by onboarding step 6 and by the setup item. Ask in short rounds, options with a recommendation, and let the human pick. Ask only for what Godot doesn't already have: read `export_presets.cfg` and GDD › Presentation and Platforms first, and skip what they answer.

1. **Target platforms.** Which platforms the game ships to (Windows, Linux, macOS, Web, Android, iOS), and for each what Godot needs that the project can't supply:
   - Web: the renderer must be `gl_compatibility` for broad browser support; say so if the project uses another one.
   - Android: a Java SDK, the Android SDK and a keystore, set in the editor's settings, not in the project.
   - macOS and iOS: signing needs the platform's tools and an Apple developer account; say what is needed before promising a build.
2. **Where exports run.** One of:
   - **This machine.** `/export` runs here with the Godot already recorded in `tools/godot_bin.local`. The simplest option, and the others use the same command.
   - **A build container,** on this machine or in the cloud. A container image with the same Godot version and its export templates installed runs the command in "Export the game" step 4. Walk the human through choosing or building the image; the version must match the project's.
   - **A hosted service such as GitHub Actions.** The same command runs in a job on a Godot image with the templates. Explain what the job needs: the project checked out, the Godot version, and the templates. Offer to write the workflow file only if the human asks for it now.
3. **Write it down.**
   - `export_presets.cfg`: one preset per target platform, named after it (`Windows Desktop`, `Linux`, `Web`, ...), with `export_path="builds/<preset name>/<game>.<ext>"`. Create it only for platforms the human named; the editor's Project > Export dialog can refine it later. Keep secrets (keystore passwords, signing identities) out of it: Godot keeps them in `.godot/export_credentials.cfg`, which stays ignored.
   - GDD › Presentation and Platforms: the platforms, as the current design. `design/decisions.md`: one line for the platforms and one for where exports run.
   - AGENTS.md › Project rules: where exports run, in one line (for example "Exports run on GitHub Actions; `/export` runs them locally too").
   - `.gitignore` has `/builds/` (the installer adds it).
4. **Try it.** Run "Export the game" for one preset and report the result, including a missing-templates message if that's what comes back. A game that exports once is set up.

**When the human skips it.** Add the open question and the item, and nothing else:
- GDD › Open Questions: `- **Q<n>** · Export: which platforms does the game export to, and where do exports run (this machine, a build container, or a hosted service such as GitHub Actions)? Answering it sets up exports: /design Q<n> runs the "Set up exports" step.` Bump `Next`.
- TASKS.md:

  ```
  ### T<n> · Set up exports · todo · M · agent
  - Depends on: Q<n>
  - Touches: export_presets.cfg (new), AGENTS.md, design/gdd.md
  - Done when: `export_presets.cfg` has a preset for each platform Q<n>'s decision names, and `/export` exports one of them (check)
  - GDD: Presentation and Platforms
  ```

  The item is ready when Q<n> is no longer in Open Questions, so `/design Q<n>` runs the step above and records the decision, and `/next-task` builds the setup. Changing exports later is a design session too.
