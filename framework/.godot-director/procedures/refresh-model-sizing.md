<!-- Godot Director · framework-owned: replaced on upgrade. -->
# Refresh model sizing

Scan the current assistant environment, propose a model-to-task-size mapping for all five sizes, confirm it with the human, and write it to AGENTS.md › Project rules.

## 1. Detect the environment

**Claude Code:** state the model this session is running on (from your system context). Then list the Claude models you know are currently available:

| Model ID | Character | Notes |
|---|---|---|
| `claude-haiku-4-5-20251001` | Fast, low-cost | Suitable for small, well-scoped changes |
| `claude-sonnet-5-5` | Balanced | Good judgment at moderate speed |
| `claude-opus-5-5` | Most capable | Best for complex reasoning; requires an Opus-enabled plan |
| `claude-fable-5-1` | Coding-optimised | Alternative to Opus for large items; available on Claude platform or with usage credits |

Note any models the human is unlikely to have: Opus requires a plan that includes it; Fable requires Claude platform access or usage credits.

**Other tools:** ask the human which models are available and what their IDs are, then list what they say.

## 2. Read the current mapping

Read AGENTS.md › Project rules. Report whether model sizing is on or off, and if it's on, the current per-size assignments.

## 3. Propose a mapping

Recommend one model for each of the five item sizes, with a one-line reason per row. Default Claude Code recommendations:

| Size | Model | Why |
|---|---|---|
| `XS` | `claude-haiku-4-5-20251001` | Single value or label; speed is the priority |
| `S` | `claude-haiku-4-5-20251001` | Small self-contained change; Haiku handles it reliably |
| `M` | `claude-sonnet-5-5` | Moderate scope; needs judgment, not raw horsepower |
| `L` | `claude-opus-5-5` | Large change; complex cross-file reasoning benefits from Opus |
| `XL` | `claude-opus-5-5` | Cross-cutting; `claude-fable-5-1` is an alternative for Claude platform users |

Adjust the proposal when a model isn't available (e.g. no Opus access → use Sonnet for L and XL).

## 4. Ask the human

Present the proposed mapping as a table. Ask:
- Are there any models on this list you don't have access to?
- Is there any size you want mapped differently?

Wait for their response and adjust accordingly.

## 5. Write to AGENTS.md

In AGENTS.md › Project rules, replace the existing model sizing block (or add one) so it reads exactly:

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
