# Teleport/Phases (owner: phases)

These files port, from 0.39.0:
- `src/main/phasesetup.js`;
- its IPC handlers in main.js (`phasesetup:*`);
- `phasebuilder.js`, `phaseaddins.js` and `phasepicker.js`;
- the Phase parts of renderer `beams.js` that teleport-ui does not own:
  - the journal and settling;
  - relations and lineage;
  - details;
  - the Phase menu;
  - the New Phase form (base / fork / from);
  - the list views (Folders / List / Relationships).

## Hookup (lead)

`PhasesFeature.install()` must be added to `Features.installAll()`
(App/Main.swift). Until then, none of the `phase-*` ids below are registered.

## Files

| File | What |
|---|---|
| PhaseSetup.swift | The types: `PhaseSetup`, `PhaseSetupField`, `PhaseSetupContext`, `PhaseStage`, `PhaseSetupUse`, `PhaseBuildResult` |
| PhaseSetupCatalog.swift | `SETUPS`: the built-in setups, with their wording |
| PhaseAddinParse.swift | `parseAddin`, `loadAddins`, `addinTemplate`, `addinId` |
| PhaseSetupBuild.swift | `PhaseSetups.build(stages, ctx)` (`buildSetup`), `fromYaml` (`setupFromYaml`), `catalog` |
| PhaseSetupFiles.swift | The `phasesetup:*` IPC handlers: write, open, the saved setups, the add-ins folder, check/save/remove an add-in |
| PhaseJournal.swift | `settings.phaseJournal`: `newEntry`, `judge`, `settle`, `buildsOf`, `originOf` |
| PhaseRuns.swift, PhaseSnapshot.swift | Running a build in a tab (`runPhaseBuild`), and saving a running build from its menu |
| PhaseRelations.swift | `PhaseRelations.of` (`phaseRelations`) and `lineageText` |
| PhaseDetails.swift, PhaseMenu.swift | The details dialog and the Phase context menu |
| PhaseNewForm.swift, PhaseNewPhase.swift | `+ New Phase…`: a new build, which opens in a session on its build Beam |
| PhasePicker.swift | `phasepicker.js` |
| PhaseListViews.swift, PhaseRelationView.swift | Phases shown as Folders / List / Relationships (`PhaseRelLayout.rows`) |
| PhaseBuilder*.swift | "Build a Phase from setups" |
| PhaseAddins*.swift | "My Phase add-ins" |
| PhasesFeature.swift | Registers the action ids |

## Action ids (registered in `PhasesFeature.install()`)

- `phase-new-build`: args `profileKey`, `mode` ("base"/"fork"/"from"), `source`.
- `phase-builder`: args `profileKey` (or `proxy`/`home`/`cluster`), `from`.
- `phase-addins`: opens "My Phase add-ins".
- `phase-picker`: args `profileKey`, `phases`, `value`, `standard`, `typed`, `onChange`. It calls `reply` with an `AnyView`.
- `phase-list-view`: args `profileKey`, `mode` ("folders"/"list"/"relations"). It calls `reply` with an `AnyView`. teleport-ui hosts it in the beams panel.
- `phase-details`: args `profileKey` or `proxy`/`home`, and `name`.
- `phase-edit`: args `profileKey`, `name`.
- `phase-lineage`: args `proxy`, `name`. It replies with the lineage line.
- `phase-list-read`: args `proxy`, `phases` `[BeamPhase]`. It settles the journal against a fresh list.
- `phase-dev-builder`, `phase-dev-addins`: development only (not in any menu). They open the builder or the add-ins on a made-up cluster for `--snapshot`.

## Reused, not duplicated

- teleport-service: `BeamPhase`, `Beams.addSupport`, `phaseAddArgs`, `phaseApplyArgs`, `phaseEditArgs`.
- teleport-ui: `BeamPhaseLists` (`refreshPhases`), `BeamsUI.phaseName`, `phaseNameProblem`, `BeamsUI.regions`.
- Fleet/Kube YAML: `YAMLValue`, `KubeYAML.dump`, `loadAllValues`. This keeps the output js-yaml-shaped.

## Not done / caveats

- `SB2.hostsInGroup` (sidebar) only knows `tp:` and kube group keys. A Phase folder's folder menu may therefore list no hosts.
- The "phase-relations shut" state is kept in the `phaseRelShut` setting.
- tests/phases.test.mjs is beams.js plumbing (args, add support), which is teleport-service's. It is covered in Tests/ServerLifeTests/Teleport/TeleportSync039Tests.swift.
