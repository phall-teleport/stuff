# Brief: data

Read `Briefs/_common.md` and `CLAUDE.md` first. Wave 1.

```sh
A="Scripts/agent.sh data Sources/ServerLife/Data,Tests/ServerLifeTests/Data"
$A pull && cd "$($A path)"      # then: $A build · $A test --filter Data · $A publish
```

## Upstream files (`serverlife/…` in the original)

- `src/main/store.js` (changed, +81/−4)
- `src/main/multiexecfile.js` (changed, +16/−0)
- `src/main/backup.js` (changed, +3/−2)

## What to port (from the 0.16.0–0.39.0 changelog — check it for more)

- Port every new/changed store.js method and record type (+81 lines): new collections
  (`macroOrder`, …), new per-host/per-cluster keys, kube-related records, phase history,
  saved AI prompts/responses if stored there, `hostsPaneProfiles`/`hostsPaneSort`.
- multiexecfile.js and backup.js changes.
- Publish early — most owners call your Store extensions. Document each new method in README.
