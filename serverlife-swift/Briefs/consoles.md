# Brief: consoles

Read `Briefs/_common.md` and `CLAUDE.md` first. Wave 2.

```sh
A="Scripts/agent.sh consoles Sources/ServerLife/Devices/UI,Sources/ServerLife/Devices/Service,Tests/ServerLifeTests/Devices,Tests/ServerLifeTests/Consoles"
$A pull && cd "$($A path)"      # then: $A build · $A test --filter Devices · $A publish
```

## Upstream files (`serverlife/…` in the original)

- `src/renderer/js/tmux.js` (changed, +94/−6)
- `src/renderer/js/vnc.js` (changed, +1/−0)
- `src/main/tmuxctl.js` (changed, +14/−2)

## What to port (from the 0.16.0–0.39.0 changelog — check it for more)

- tmux attach fixes (0.18), tmux inside a beam offered beam macros (0.19), closing a tmux pane
  closes it in tmux (0.29, with sessions), reopening a layout reattaches tmux sessions (0.38),
  a tmux tab on a beam reopens after restart (0.38.1). tmuxctl.js (+14), vnc.js (+1).
