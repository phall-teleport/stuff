# Brief: automation

Read `Briefs/_common.md` and `CLAUDE.md` first. Wave 2.

```sh
A="Scripts/agent.sh automation Sources/ServerLife/Automation,Tests/ServerLifeTests/Automation"
$A pull && cd "$($A path)"      # then: $A build · $A test --filter Automation · $A publish
```

## Upstream files (`serverlife/…` in the original)

- `src/renderer/js/automation.js` (changed, +433/−33)
- `mcp/serverlife-mcp.mjs` (changed, +160/−15)
- `src/main/awsproxy.js` (changed, +1/−1)

## What to port (from the 0.16.0–0.39.0 changelog — check it for more)

- automation.js (+433) and serverlife-mcp.mjs (+160): `serverlife_get_settings` /
  `serverlife_set_settings`, `serverlife_close_session` asks first, `open_session` split fix and
  plain path fix (0.24), beams by name (0.18), automation opening a beam (0.18), KubeLife from
  MCP (0.31, call kube-service), assistants typing into sessions with approval / reading a pane
  (0.16, coordinate with ai: the approval UI is ai's `ai-type-request`). Update Resources/MCP.md
  content in your README for the lead to copy.
