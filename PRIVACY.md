# Privacy policy

Godot Director is a set of files and instructions that runs on your own machine. There is no Godot Director service, account or server.

**What it reads.** Only your game's project: its design documents, task list, code, settings and git history, so the AI assistant you use can work on the game. It doesn't collect personal data such as names, emails or addresses. Your git name and email are used only by git itself, in your own commits.

**What it writes.** Files in your game's repository (the workflow files, design records and code the assistant builds), git commits you approve, and the project check's logs under the game's `.godot/` folder. Everything stays on your machine, in your repository. A game built with it also keeps a play log on the machine it runs on (`user://logs/play/`), with the OS user name, the home path and the install id scrubbed out; Godot Director never sends it anywhere.

**What it sends.** Nothing. Godot Director has no telemetry or analytics, and sends nothing to us or to any other service.

**Downloads.** When the installer skill runs without a local copy of Godot Director (for example after `npx skills add`), it downloads Godot Director from `https://github.com/Freakling/Godot-Director` with `git clone`. That is a download from GitHub, under GitHub's own terms; no project data is uploaded.

**Your AI assistant.** The assistant you use (for example Claude Code) sends your conversation and the files it reads to its own provider, under that provider's terms and privacy policy. Godot Director doesn't change what your assistant shares.

**Retention.** Godot Director keeps nothing outside your repository. Delete the files to remove it.

**Contact.** Open an issue at https://github.com/Freakling/Godot-Director/issues.
