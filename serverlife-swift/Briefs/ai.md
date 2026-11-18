# Brief: ai

Read `Briefs/_common.md` and `CLAUDE.md` first. Wave 1.

```sh
A="Scripts/agent.sh ai Sources/ServerLife/AI,Tests/ServerLifeTests/AI"
$A pull && cd "$($A path)"      # then: $A build · $A test --filter AI · $A publish
```

## Upstream files (`serverlife/…` in the original)

- `src/renderer/js/ai.js` (NEW, +1107/−0)
- `src/main/aiclients.js` (NEW, +373/−0)
- `src/renderer/js/aiwaiting.js` (NEW, +44/−0)
- `tests/aiclients.test.mjs` (NEW, +176/−0)

## What to port (from the 0.16.0–0.39.0 changelog — check it for more)

- AI assistant panel on the right (`Slots.rightPanel`, `rightPanelShown`, `toggle-ai`), the
  check before it opens, how each tool runs, assistant at startup (0.16); several sessions of one
  assistant, named sessions, pick up a past conversation, saved prompts, saved responses,
  "Ask the AI about this" (`ai-ask`), Show terminal (0.17); Esc/↑/↓/Enter buttons (0.18);
  a choice of pane when an assistant asks to type (0.21, `ai-type-request`); focus follows the
  mouse into the panel (0.25); closing the panel leaves no blank workspace (0.28); `aiKeys`.
- aiclients.js: detecting installed CLIs (claude, codex, …), custom tools. The assistant runs in a
  terminal backend — use sessions' `open-backend`/PTYBackend for its terminal. Port aiclients tests.
