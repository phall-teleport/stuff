# Brief: lead

Read `Briefs/_common.md` and `CLAUDE.md` first. Wave 1.

```sh
A="Scripts/agent.sh lead Sources/ServerLife/Core,Sources/ServerLife/App,Package.swift,Scripts,Resources,Tests/ServerLifeTests/CoreTests.swift"
$A pull && cd "$($A path)"      # then: $A build · $A test --filter Core · $A publish
```

## Upstream files (`serverlife/…` in the original)

- `src/main/main.js` (changed, +1426/−37)
- `src/main/preload.js` (changed, +228/−3)
- `src/renderer/index.html` (changed, +29/−2)
- `src/renderer/styles.css` (changed, +942/−54)
- `src/renderer/js/util.js` (changed, +36/−0)
- `src/renderer/js/state.js` (changed, +25/−2)
- `src/renderer/js/ui.js` (changed, +67/−6)
- `src/renderer/js/csv.js` (NEW, +16/−0)
- `src/renderer/js/textdiff.js` (NEW, +36/−0)
- `src/renderer/js/yamleditor.js` (NEW, +93/−0)
- `src/renderer/js/yamlview.js` (NEW, +43/−0)
- `src/renderer/js/cmtheme.js` (NEW, +49/−0)
- `src/renderer/js/sshconfigeditor.js` (NEW, +85/−0)
- `src/renderer/js/bundledfonts.js` (NEW, +59/−0)
- `src/renderer/fonts/README.md` (NEW, +59/−0)

## What to port (from the 0.16.0–0.39.0 changelog — check it for more)

- **First, publish a shared code editor** in `App/Components/CodeEditor.swift` (others wait on it):
  an NSTextView-backed SwiftUI view with syntax colouring for YAML and ssh_config
  (yamleditor.js, sshconfigeditor.js, cmtheme.js — colours from `Theme.shared.p`),
  line numbers, monospace, and Escape handled the way 0.34's fix says ("Escape in a
  code editor inside a dialog"). Also a read-only `YamlView` (yamlview.js). Document it in
  App's README section of CLAUDE.md or a comment block.
- Shared helpers: `toCsv` (csv.js), `diffLines` (textdiff.js) in Core/Util; anything new in
  util.js / ui.js / state.js that more than one owner needs.
- **Bundled fonts (0.28)**: `Resources/fonts/` is already copied (51 .ttf + licences). Register
  them at launch with `CTFontManagerRegisterFontsForURL(.process)` and make sure
  `Scripts/bundle.sh` ships them. Expose `BundledFonts.list` (bundledfonts.js) for misc's picker.
- main.js app-level changes: menu label "Network and Certificate Tools…"; anything in main.js
  that is window/app plumbing rather than a feature (quit handling of helpers — call an action
  `app-will-quit` that owners can register for, e.g. kube-service stops `tsh proxy kube`).
- `Core/StoreDefaults.swift` has already been regenerated from 0.39's store.js; keep it so.
- `Slots.rightPanel`, `Slots.rightPanelShown`, `Slots.sidebarSections` and the ✦ toggle-ai
  titlebar button already exist; tidy them if needed (keep the names).
- At the very end (after the others have published): replace `Resources/GUIDE.md`,
  `Resources/CHANGELOG.md`, `Resources/MCP.md` with 0.39.0's and bump `VERSION` to 0.39.0.
  Leave this to the lead (the human-run coordinator) if others are still running.
