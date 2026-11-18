# Brief: sidebar

Read `Briefs/_common.md` and `CLAUDE.md` first. Wave 2.

```sh
A="Scripts/agent.sh sidebar Sources/ServerLife/Sidebar,Tests/ServerLifeTests/Sidebar"
$A pull && cd "$($A path)"      # then: $A build · $A test --filter Sidebar · $A publish
```

## Upstream files (`serverlife/…` in the original)

- `src/renderer/js/sidebar.js` (changed, +1859/−147)
- `src/renderer/js/hostactions.js` (changed, +206/−34)
- `src/renderer/js/heartbeat.js` (changed, +33/−8)
- `src/renderer/js/narrowed.js` (changed, +26/−3)
- `src/renderer/js/tags.js` (changed, +28/−1)
- `src/renderer/js/requestable.js` (changed, +16/−0)
- `src/renderer/js/clustermarks.js` (changed, +2/−2)
- `src/renderer/js/pinned.js` (NEW, +42/−0)
- `src/renderer/js/hosticons.js` (NEW, +25/−0)

## What to port (from the 0.16.0–0.39.0 changelog — check it for more)

- sidebar.js (+1859) — read the whole diff. All / SSH / K8s kind filter (`sb-kind-filter`),
  Kubernetes rows (drawn via `Slots.sidebarSections["kube"]` from kube-ui, capped per group like SSH),
  sidebar tab colours (0.18), closed groups/folders stay closed (0.18).
- Pinned saved clusters on the Hosts tab (pinned.js, 0.27); Tags…/Show tags/Heartbeats/Quiet/
  Folders on the Hosts tab (0.27); requestable watches keep `req` + `? unchecked <age>` (0.27).
- Server icon on SSH host rows (hosticons.js, 0.34); cert close to expiring tag (0.20).
- ⚡ Add to Teleport (0.32) — `add-to-teleport`; Install Teleport on an SSH host entry point.
- hostactions.js (+206): run-a-command remembers what it last ran (0.22), startup command per host,
  Connect with tsh ssh fixes, SSH options… entry (calls `ssh-options`).
- heartbeat.js / narrowed.js / tags.js / clustermarks.js / requestable.js changes; MFA-marked host
  keeps its mark (0.26); watched node that lapsed logs itself back in (0.24).
