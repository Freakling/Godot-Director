---
name: godot-director
description: 'Sets up Godot Director in a Godot 4 project: you direct the game design while the AI builds it, design calls come to you as options, and one project check proves every change works. Use when the user asks to install, set up, upgrade or migrate Godot Director, or wants an AI design-and-build workflow for a Godot game.'
license: MIT
compatibility: 'Godot 4.3 or newer, git and bash (Git Bash on Windows). Needs network access to fetch Godot Director from GitHub unless it is already present.'
metadata:
  author: Freakling
  version: 3.3.0
  repository: https://github.com/Freakling/Godot-Director
---

# Godot Director setup

This skill only installs Godot Director. The workflow itself is committed into the game, so it keeps working without this skill.

1. **Find Godot Director (`$GDIR`)**, the folder that holds `ONBOARDING.md` and `install.sh`. Use the first that exists:
   - `${CLAUDE_PLUGIN_ROOT}`, when this skill runs from the Claude Code plugin;
   - a `Godot-Director/` folder in the game's root, for a manual install;
   - otherwise fetch it outside the game, so nothing lands in the game's repository. With bash (Git Bash on Windows):
     ```bash
     GDIR="${TMPDIR:-/tmp}/godot-director"
     if [ -d "$GDIR/.git" ]; then git -C "$GDIR" pull --ff-only; else git clone --depth 1 https://github.com/Freakling/Godot-Director.git "$GDIR"; fi
     ```
     Pulling each time means an upgrade is simply running this skill again.
2. **Read `$GDIR/ONBOARDING.md` and follow it** for the project in the current working directory, with `$GDIR` set to that folder.
