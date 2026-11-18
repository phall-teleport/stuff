# Brief: misc

Read `Briefs/_common.md` and `CLAUDE.md` first. Wave 1.

```sh
A="Scripts/agent.sh misc Sources/ServerLife/Misc,Tests/ServerLifeTests/Misc"
$A pull && cd "$($A path)"      # then: $A build · $A test --filter Misc · $A publish
```

## Upstream files (`serverlife/…` in the original)

- `src/renderer/js/settingsnav.js` (NEW, +100/−0)
- `src/renderer/js/themes.js` (changed, +5/−0)
- `src/renderer/js/tour.js` (changed, +113/−9)
- `src/renderer/js/fonts.js` (NEW, +90/−0)
- `src/renderer/js/bundledfonts.js` (NEW, +59/−0)
- `src/renderer/js/versions.js` (changed, +1/−1)
- `src/renderer/js/search.js` (NEW, +359/−0)
- `src/renderer/js/index.js` (changed, +440/−24)
- `src/renderer/js/guide.js` (unchanged — read for context)
- `src/renderer/js/changelog.js` (unchanged — read for context)

## What to port (from the 0.16.0–0.39.0 changelog — check it for more)

- Settings dialog (index.js `openSettings` diff): sections with a dropdown and a search (settingsnav.js,
  0.34), opens with Teleport homes and Locate tsh/ssh… → Browse… (0.28), checkbox-in-field fix,
  every new setting from StoreDefaults (`cursorStyle`, `paneCloseAnimations`, `quietRemote`,
  `aiKeys`, `kubeEnabled`, `kubeconfigPaths`, `kubeRefreshSeconds`, `detectTeleportOnSsh`, …),
  No background commands on servers (0.29), Azure CLI (0.34) if it's a setting/version.
- Themes: Matrix (0.27), Thug Life skin (0.28). Fonts: font picker with bundled + installed fonts
  (fonts.js; registration is lead's). A reminder at launch (0.28). Tour changes (+113).
- Search everything (search.js, 0.17) — `search-everything`, keyboard shortcut as upstream;
  "Ask the AI" hands off to `ai-ask`. versions.js: tsh and cluster versions (0.17).
