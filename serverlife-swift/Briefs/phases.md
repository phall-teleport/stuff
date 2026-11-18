# Brief: phases

Read `Briefs/_common.md` and `CLAUDE.md` first. Wave 2.

```sh
A="Scripts/agent.sh phases Sources/ServerLife/Teleport/Phases,Tests/ServerLifeTests/TeleportPhases"
$A pull && cd "$($A path)"      # then: $A build · $A test --filter TeleportPhases · $A publish
```

## Upstream files (`serverlife/…` in the original)

- `src/main/phasesetup.js` (NEW, +777/−0)
- `src/renderer/js/phasebuilder.js` (NEW, +378/−0)
- `src/renderer/js/phaseaddins.js` (NEW, +135/−0)
- `src/renderer/js/phasepicker.js` (NEW, +116/−0)
- `src/renderer/js/beams.js` (changed, +938/−7)
- `tests/phasesetup.test.mjs` (NEW, +298/−0)
- `tests/phases.test.mjs` (NEW, +181/−0)
- `tests/fixtures/tsh-help/v18.11.7-phase.txt` (NEW, +152/−0)

## What to port (from the 0.16.0–0.39.0 changelog — check it for more)

- Phases (0.28): what a Phase is, `tsh` phase commands (see the tsh-help fixture), History.
- Phases from setups, Open/Edit a phase.yaml in the builder (colour-coded, uses lead's CodeEditor),
  your own add-ins (phaseaddins.js), copy files into a new Phase, replace command file/copied files,
  save a running build from its menu, New Phase points to the setup builder, choose a Phase from
  folders or search (phasepicker.js) (0.34).
- Start a new Phase build (0.29); a new build opens in a session on its build Beam (0.38).
- Phases in Folders/List/Relationships, name checked as typed, lineage while building (0.38.1).
- Register `phase-builder`, `phase-picker`, `phase-addins`, `phase-new-build` and provide the
  Phase list views teleport-ui hosts in the beams panel. Port tests/phasesetup + phases tests.
