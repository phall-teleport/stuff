# Common brief — 0.15.2 → 0.39.0 sync

You are one of several agents porting the Electron app's 0.16.0 … 0.39.0
changes into the Swift port. Read `CLAUDE.md` first and follow it exactly
(toolchain limits, `@State` ban, mirrors, ownership, Return-key rule, Theme,
Store accessors, Actions).

## Sources

- The original, at 0.39.0: `/Users/paul/git/serverlife-upstream/serverlife`
  (read-only worktree; do not edit or check out anything there).
- What changed in a file since the port was made:
  `git -C /Users/paul/git/serverlife-upstream diff ce8d055 HEAD -- serverlife/<path>`
- New releases' notes: `serverlife/CHANGELOG.md` lines 13–1462 (0.39.0 down
  to 0.16.0). Read **all** of it once and pick out every item that touches
  your files — the list in your brief is a guide, not a ceiling.
- The 0.39.0 GUIDE.md is the spec for wording; the JS wins where they differ.
- `src/main/main.js` and `src/main/preload.js` hold the IPC handlers for most
  main-process features. In Swift there is no IPC: port the handler bodies for
  *your* channels into your own directory (grep `ipcMain.handle('<prefix>`).
- Read every upstream file in your brief **in full** (new files) or its
  whole diff plus surrounding code (changed files) before writing Swift.

## How to work

```sh
cd /Users/paul/git/stuff/serverlife-swift
A="Scripts/agent.sh <name> <owned,paths>"     # from your brief
$A pull; cd "$($A path)"                       # edit ONLY in the mirror
$A build ; $A test --filter <YourArea>
$A publish                                     # whenever it compiles; always at the end
```

- Pull often; others publish as they go. If a dependency (another owner's
  action, type or component) is not published yet, call the documented action
  id anyway (it no-ops until registered) or add a stand-in named
  `_<Owner>StandIn.swift` in your own directory and delete it once the real one
  lands.
- New cross-feature action ids are listed in CLAUDE.md ("New for 0.39").
  Register the ones you own; if you need one that is not listed, name it
  `<area>-<verb>` and document it in your README.
- Put tests in `Tests/ServerLifeTests/<YourArea>/`. Port the upstream unit
  tests for your files (`serverlife/tests/*.test.mjs`) as Swift Testing tests
  where they test pure logic (parsers, formatters, state machines).
- Never connect to real servers, log in, or touch `~/.ssh`, `~/.tsh`, `~/.aws`,
  `~/.kube`. Read-only `tsh status`/`kubectl config view` are fine.
- Look at your UI with `--snapshot` (CLAUDE.md) and Read the PNGs.
- Do not commit or push; the lead does that after merging.

## Done means

1. Every changelog item in your area from 0.16.0–0.39.0 exists, with the
   original's wording, defaults, tooltips and edge cases.
2. `$A build` is clean and `$A test --filter <YourArea>` passes; published.
3. `<your dir>/README.md` updated: public API, action ids registered and
   consumed, what is **not** done yet and why.
4. A final report: what you ported (by release), stand-ins left behind,
   requests for other owners (especially lead: Core/App changes you needed).
