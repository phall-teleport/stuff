# Brief: teleport-service

Read `Briefs/_common.md` and `CLAUDE.md` first. Wave 1.

```sh
A="Scripts/agent.sh teleport-service Sources/ServerLife/Teleport/Service,Tests/ServerLifeTests/Teleport"
$A pull && cd "$($A path)"      # then: $A build · $A test --filter Teleport · $A publish
```

## Upstream files (`serverlife/…` in the original)

- `src/main/teleport.js` (changed, +477/−19)
- `src/main/beams.js` (changed, +296/−2)
- `src/main/sshconfig.js` (changed, +130/−9)
- `src/main/vnet.js` (NEW, +192/−0)

## What to port (from the 0.16.0–0.39.0 changelog — check it for more)

- VNet per cluster (vnet.js, 0.16) — register `vnet-start`/`vnet-stop`.
- Login method in the Teleport tab (0.16), cluster version in tsh status (0.21), per-cluster Refresh.
- Expired-cluster inventory: what an expired cluster still lists (0.26); deliberate logout
  believed immediately (0.25); "Logging out could log straight back in" fix.
- tsh environment per cluster / tsh variables, tools version from a tsh variable (0.29).
- A tsh picked in Settings or TSH_PATH runs as itself (0.28).
- beams.js main changes (+296): beams by name, beams.sh/beams.run clusters default to beams
  clusters (0.28), Phase build plumbing that is not phasesetup.js (coordinate with phases).
- sshconfig.js: delete/comment out a host, New host in this config (0.18), plain alias with its own
  IdentityFile (0.21), Install Teleport on an SSH host (0.32, the remote install command).
- Kubernetes inventory from `tsh kube ls` if it lives in teleport.js — expose it for kube-service.
