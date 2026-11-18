# Brief: fleet

Read `Briefs/_common.md` and `CLAUDE.md` first. Wave 1.

```sh
A="Scripts/agent.sh fleet Sources/ServerLife/Fleet,Tests/ServerLifeTests/Fleet"
$A pull && cd "$($A path)"      # then: $A build · $A test --filter Fleet · $A publish
```

## Upstream files (`serverlife/…` in the original)

- `src/renderer/js/dock.js` (changed, +732/−52)
- `src/renderer/js/macros.js` (changed, +548/−17)
- `src/renderer/js/macrorecord.js` (NEW, +256/−0)
- `src/renderer/js/mxschedule.js` (NEW, +105/−0)
- `src/main/multiexec.js` (changed, +270/−34)
- `src/renderer/js/snippets.js` (unchanged — read for context)

## What to port (from the 0.16.0–0.39.0 changelog — check it for more)

- Record a macro (macrorecord.js, 0.17/0.18) — `macro-record-start/stop`; drag macros into order
  (`macroOrder`, 0.19); Teleport macros, macro menu listed in full when it fits, Saved → Macros
  toolbar (0.27); beam macros (0.17/0.28); careful macro says what it costs (0.29); macro menu tests.
- Multi-exec: retries, scheduled (mxschedule.js), staged, Run as (0.17); follows the ticks; running
  from multi-exec fix (0.38.1); multiexec.js main (+270).
- dock.js (+732): dock settles to its content (0.22), Transfers dock fixed small height (0.27),
  anything else in the diff.
