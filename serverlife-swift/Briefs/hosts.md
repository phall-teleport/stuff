# Brief: hosts

Read `Briefs/_common.md` and `CLAUDE.md` first. Wave 2.

```sh
A="Scripts/agent.sh hosts Sources/ServerLife/Hosts,Tests/ServerLifeTests/Hosts"
$A pull && cd "$($A path)"      # then: $A build · $A test --filter Hosts · $A publish
```

## Upstream files (`serverlife/…` in the original)

- `src/renderer/js/hostspane.js` (changed, +688/−63)
- `src/renderer/js/profiles.js` (changed, +163/−11)
- `src/renderer/js/addserver.js` (changed, +61/−8)
- `src/renderer/js/folders.js` (changed, +79/−0)
- `src/renderer/js/quickconnect.js` (changed, +3/−2)
- `src/renderer/js/history.js` (unchanged — read for context)
- `src/renderer/js/sshoptions.js` (NEW, +295/−0)
- `src/renderer/js/sshpresets.js` (NEW, +237/−0)

## What to port (from the 0.16.0–0.39.0 changelog — check it for more)

- hostspane.js (+688): Saved group of every saved profile (0.22), K8s clusters in the pane (0.31),
  heartbeats + sortable Heartbeat column, All/SSH/K8s, "Open this list in a pane" (0.37),
  Export… CSV/JSON/YAML if it applies here, `hostsPaneProfiles`/`hostsPaneSort`.
- profiles.js: SFTP profile type, colour and icon (0.22), split right/down for a profile,
  SSH options on SSH/Teleport profiles (0.32), Kubernetes profiles (0.32, with kube-ui), Profile… (0.17).
- addserver.js, folders.js (+79), quickconnect.js ("null" fix 0.36), history.js.
- sshoptions.js + sshpresets.js UI: SSH options dialog, common options picker, ssh config editor
  (uses lead's CodeEditor) — register `ssh-options`, `ssh-config-edit`.
