<!-- Godot Director · framework-owned: replaced on upgrade. -->
# Refresh model sizing

Check whether this assistant supports model sizing, propose a per-size model mapping, confirm it with the human, and write it to AGENTS.md › Project rules.

## 0. Capability check

Model sizing requires the assistant to do two things:
1. **Spawn subagents** — run the builder in a separate context for each item.
2. **Select the model per subagent** — specify a different model ID for each call.

Assess your own tool honestly before continuing.

**Claude Code:** both are supported. Continue to step 1.

**Any other tool:** state which of the two capabilities your tool has. If either is missing, tell the human:

> Model sizing requires an assistant that can both spawn subagents and select their model per call. [Tool] doesn't support that combination, so the feature is skipped — every build runs on whichever model this session uses.

Stop here. Do not write a model sizing block to AGENTS.md. The human may want to add a note in Project rules such as `Model sizing: not supported ([Tool])` so future sessions don't ask again.

If the tool genuinely supports both capabilities, continue to step 1 using the tool's own model IDs and naming conventions wherever the Claude-specific examples appear below.

---

## 1. Read the current mapping

Read AGENTS.md › Project rules. Report whether model sizing is on or off and, if it's on, the current per-size assignments.

## 2. Propose a mapping

Recommend one model for each of the five item sizes with a one-line reason.

**Claude Code — hard defaults:**

| Size | Model ID | Why |
|---|---|---|
| `XS` | `claude-haiku-4-5-20251001` | Single value or label; speed is the priority |
| `S` | `claude-haiku-4-5-20251001` | Small self-contained change; Haiku handles it reliably |
| `M` | `claude-sonnet-5-5` | Moderate scope; needs judgment, not raw horsepower |
| `L` | `claude-opus-5-5` | Large change; complex cross-file reasoning benefits from Opus |
| `XL` | `claude-opus-5-5` | Cross-cutting; `claude-fable-5-1` is an alternative for Claude platform / usage-credit users |

Note any models the human may not have access to: Opus requires a plan that includes it; Fable requires Claude platform access or usage credits. Adjust the proposal if access is limited (e.g. no Opus → use `claude-sonnet-5-5` for L and XL).

**Other tools:** state the session model this tool is running on, then list the available model IDs you know about with a short description. Apply the same tier logic (fast/low-cost for XS and S; balanced for M; most capable for L and XL) using those IDs.

## 3. Ask the human

Present the proposed mapping as a table. Ask:
- Are there any models on this list you don't have access to?
- Is there any size you want mapped differently?

Wait for their response and adjust accordingly.

## 4. Write to AGENTS.md

In AGENTS.md › Project rules, replace the existing model sizing block (or add one) so it reads:

```
Model sizing: on
- XS: <model-id>
- S: <model-id>
- M: <model-id>
- L: <model-id>
- XL: <model-id>
```

If model sizing was off, ask whether to turn it on before writing the block.

Report the final mapping in a table.
