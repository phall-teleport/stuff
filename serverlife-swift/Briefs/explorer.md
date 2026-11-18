# Brief: explorer

Read `Briefs/_common.md` and `CLAUDE.md` first. Wave 2.

```sh
A="Scripts/agent.sh explorer Sources/ServerLife/Files/Explorer,Tests/ServerLifeTests/Explorer"
$A pull && cd "$($A path)"      # then: $A build · $A test --filter Explorer · $A publish
```

## Upstream files (`serverlife/…` in the original)

- `src/renderer/js/explorer.js` (changed, +274/−39)
- `src/renderer/js/files.js` (changed, +7/−0)
- `src/renderer/js/watch.js` (changed, +86/−15)

## What to port (from the 0.16.0–0.39.0 changelog — check it for more)

- Free space in the file browser footer (0.26).
- Connect-failure text instead of raw OpenSSH output; the "approve MFA" click-to-load gate fix (0.25).
- watch.js (+86) changes; anything else in the explorer diff.
