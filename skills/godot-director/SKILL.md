---
name: godot-director
description: 'Sets up Godot Director in a Godot 4 project: you direct the game design while the AI builds it, design calls come to you as options, and one project check proves every change works. Use when the user asks to install, set up, upgrade or migrate Godot Director, or wants an AI design-and-build workflow for a Godot game.'
license: MIT
compatibility: 'Godot 4.5 or newer, git and bash (Git Bash on Windows). Needs network access to fetch Godot Director from GitHub unless it is already present.'
metadata:
  author: Freakling
  version: 4.6.0
  repository: https://github.com/Freakling/Godot-Director
---

# Godot Director setup

This skill only installs Godot Director. The workflow itself is committed into the game, so it keeps working without this skill.

1. **Find Godot Director (`$GDIR`)**, the folder that holds `ONBOARDING.md` and `install.sh`. Use the first that exists:
   - `${CLAUDE_PLUGIN_ROOT}`, when this skill runs from the Claude Code plugin;
   - a `Godot-Director/` folder in the game's root, for a manual install;
   - otherwise clone this skill's release into a temporary folder outside the game, so nothing lands in the game's repository. With bash (Git Bash on Windows):
     ```bash
     dir="$(mktemp -d)" && git -c advice.detachedHead=false clone -q --depth 1 --branch v4.6.0 https://github.com/Freakling/Godot-Director.git "$dir/Godot-Director" && echo "$dir/Godot-Director"
     ```
     `$GDIR` is the folder it prints. If the clone fails (no network, no git), tell the human and stop. Each version of this skill clones its own release, so an upgrade is installing the skill again (`npx skills add Freakling/Godot-Director`) and running it.
2. **Read `$GDIR/ONBOARDING.md` and follow it** for the project in the current working directory, with `$GDIR` set to that folder. When onboarding is done, delete a temporary clone.
