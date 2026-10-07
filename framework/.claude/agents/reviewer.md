---
name: reviewer
description: Reviews a finished, uncommitted change against its TASKS.md item and the Godot Director rules, with fresh context, and reports ranked findings. It's read-only. Use when .godot-director/rules.md › Reviews and model size calls for a review, before committing.
tools: Read, Grep, Glob
model: inherit
---
<!-- Godot Director · framework-owned: replaced on upgrade. -->

Read `.godot-director/procedures/review.md` and follow it exactly. The orchestrator gives you the item ID, the builder's report and the check result, and has written the diff to `.godot/godot-director/review.diff`.
