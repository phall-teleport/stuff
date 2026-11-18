# Brief: teleport-ui

Read `Briefs/_common.md` and `CLAUDE.md` first. Wave 2.

```sh
A="Scripts/agent.sh teleport-ui Sources/ServerLife/Teleport/UI,Tests/ServerLifeTests/TeleportUI"
$A pull && cd "$($A path)"      # then: $A build · $A test --filter TeleportUI · $A publish
```

## Upstream files (`serverlife/…` in the original)

- `src/renderer/js/teleportpanel.js` (changed, +454/−44)
- `src/renderer/js/beams.js` (changed, +938/−7)
- `src/renderer/js/requestpicker.js` (changed, +162/−4)
- `src/renderer/js/recordings.js` (changed, +92/−27)
- `src/renderer/js/reqmonitor.js` (changed, +2/−2)
- `src/renderer/js/tshenv.js` (NEW, +149/−0)
- `src/renderer/js/requestwatch.js` (unchanged — read for context)

## What to port (from the 0.16.0–0.39.0 changelog — check it for more)

- teleportpanel.js (+454): login method, cluster list sharing the Hosts tab's filter box (0.25),
  Refresh next to Status (0.21), cluster version, login-in-flight box fixed low on the right (0.25),
  "Log in to … ?" before an automatic login (0.26), Connect cluster (0.20), pinned saved clusters (0.27),
  Login settings… fix (0.27), "Log out of <cluster>?" defaults (0.25), Add a tsh home dialog (0.34).
- tshenv.js: environment for tsh per cluster (0.29) — register `tsh-env-edit`.
- requestpicker.js: access requests for a namespace or a pod (0.31), bulk "Request access to N
  selected nodes…" (0.26), MFA-before-access mark (0.20), a cluster your role cannot ask (0.37).
- recordings.js: kube/app/db playback, look back more than a day, pick any cluster (0.31).
- beams.js (renderer, +938): everything **except** the Phase builder/picker/add-ins (owner
  `phases`). Start a beam… → Start from, beam macros hook-up, History, + New Phase… entry points
  (call `phase-*` actions), "Start a beam says the beam can't be saved as a Phase" (0.34),
  Phases in Folders/List/Relationships views (0.38.1) — agree with phases who draws what: phases
  provides the views, you host them in the beams panel.
