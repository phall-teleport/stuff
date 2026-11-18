# Brief: files-service

Read `Briefs/_common.md` and `CLAUDE.md` first. Wave 2.

```sh
A="Scripts/agent.sh files-service Sources/ServerLife/Files/Service,Tests/ServerLifeTests/Files"
$A pull && cd "$($A path)"      # then: $A build · $A test --filter Files · $A publish
```

## Upstream files (`serverlife/…` in the original)

- `src/main/transfers.js` (changed, +82/−6)
- `src/main/crosstransfer.js` (changed, +28/−5)
- `src/main/local.js` (changed, +35/−2)
- `src/main/sftp.js` (unchanged — read for context)

## What to port (from the 0.16.0–0.39.0 changelog — check it for more)

- transfers.js (+82), crosstransfer.js (+28), local.js filesystem half (+35).
- The free-space query explorer needs (local `statfs` and remote `df`) — check main.js handlers.
- SFTP profile type support on the service side (0.22).
