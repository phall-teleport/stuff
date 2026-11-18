# Brief: sessions

Read `Briefs/_common.md` and `CLAUDE.md` first. Wave 2.

```sh
A="Scripts/agent.sh sessions Sources/ServerLife/Sessions,Tests/ServerLifeTests/Sessions"
$A pull && cd "$($A path)"      # then: $A build · $A test --filter Sessions · $A publish
```

## Upstream files (`serverlife/…` in the original)

- `src/renderer/js/sessions.js` (changed, +962/−54)
- `src/renderer/js/term.js` (changed, +14/−2)
- `src/renderer/js/workspace.js` (changed, +65/−1)
- `src/renderer/js/paneclose.js` (NEW, +330/−0)
- `src/renderer/js/panestyle.js` (NEW, +279/−0)
- `src/renderer/js/monitor.js` (NEW, +220/−0)
- `src/renderer/js/index.js` (changed, +440/−24)
- `src/renderer/js/aiwaiting.js` (NEW, +44/−0)

## What to port (from the 0.16.0–0.39.0 changelog — check it for more)

- A look per pane (panestyle.js, 0.17) — `pane-style-menu`.
- ↻ Reconnect on the pane (0.20); ⚡ Teleport button in the pane header (0.32).
- Short, skippable pane-close animation (paneclose.js, `paneCloseAnimations`, 0.25).
- Focus follows the mouse into panes (0.25/0.26); splitting with nothing focused; a new local shell
  opens where the last one was; closing a tab (0.26).
- Cursor style setting applied to terminals (`cursorStyle`, 0.24).
- Live stats bar under a pane, one per machine per tab (monitor.js; data from connections) (0.29/0.34)
  — `live-stats-toggle`. Redraw (0.34).
- Closing a tmux pane closes it in tmux (0.29); layouts reattach tmux, beam tmux tabs reopen after
  restart, kube tabs come back after a restart (calls kube-ui) (0.31/0.38).
- index.js glue that belongs to sessions (keyboard handling, startup restore).
