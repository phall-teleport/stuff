# Misc

Settings, themes, the guide, the tour, version history, About, the backup
dialogs and the ui.js pieces App/ does not have. Ports index.js
`openSettings`/`locateTsh`/`openAbout`, themes.js (+ the skin/accent blocks of
styles.css and term.js `activeTheme`), guide.js, tour.js, changelog.js,
versions.js, backup.js (renderer), ui.js leftovers — and, new for 0.39, settingsnav.js
(Settings sections + search), fonts.js/bundledfonts.js, search.js (Search everything),
tshenv.js (the tsh variables editor), index.js `remindCustomTeleport` and the homes dialog.

## Action ids (registered in `MiscFeature.install`)

| id | does | args |
|---|---|---|
| `settings` | Settings dialog | — |
| `locate-tools` | "Command-line tools" (tsh/ssh path overrides) | — |
| `about` | About box | — |
| `version-history` | Version history from Resources/CHANGELOG.md | — |
| `guide` | Guide panel (Resources/GUIDE.md) | `topic` String: scroll to the first section whose title contains it |
| `tour` | Start the guided tour in the window | — |
| `backup-export` | Export all / macros to a JSON file | `what` "all"/"macros", `ids` [String] (macros subset) |
| `backup-import` | Pick a file, show its contents, merge or replace | `reply` `(Bool) -> Void` (true when imported) |
| `search-everything` | Put the keyboard in the title bar's search box (also ⌘P, a key monitor) | — |
| `search-data` | search.js `searchData` for an agent (MCP `serverlife_search`) | `query`, `limit` Int, `kinds` [String], `reply: (Any?) -> Void` → JSON `{query,total,groups:[{kind,title,next,more,results}]}` |

Actions Misc **calls** (owners please register):

- `highlights` [sessions] — "Edit the highlights…" (highlight.js `openHighlightSettings`).
- `ssh-config-files` [sidebar] — "SSH config files…" (sidebar.js `openSshConfigDialog`).
- `refresh` [sidebar] — after tsh homes or tool paths change, and after an import.
- `s3-reload` [automation] — after an import.
- `automation-status` — args `reply: (JSON) -> Void`; JSON `{enabled, socketPath, tokenFile, mcpCommand, bridge}`.
- `automation-toggle` — args `enabled: Bool`, `reply: (JSON) -> Void` (new status fields, or `{error}`).
- `automation-rotate` — args `reply: (JSON) -> Void`.
- `automation-copy-command` — args `what: "mcp" | "bridge"` (copies to the clipboard).
  Unregistered automation actions → the section says "not available in this build".
- Search everything calls: `open-host-from-list` (host), `launch-profile` (`profile`), `beam-open`
  (`beam`), `teleport-panel`, `snippets`, every menu id in `MiscSearch.commands`, and the [ai] ids
  below (it is empty / a no-op until they exist):
  - `ai-saved-prompts`, `ai-saved-responses` — query actions, `reply: (Any?) -> Void` with `[JSON]`
    (`{name,text}` / `{title,file,path,mtime}`), ai.js `savedPrompts()` / `ai:savedList`.
  - `ai-ask` with args `text`, `send: true` (a saved prompt is sent); `ai-saved-open` (ai.js `openSavedResponses`).
- `ai-clients` [ai] — Settings → Assistants "AI clients…" button.

## Hooks (`MiscHooks`, set from your `install()`)

- `teleportHomes: () async -> JSON` [teleport-service] — the original's `teleport:homes` answer
  (`{tsh:{found,searched}, homes:[{path,name,default,exists,error,profiles:[{cluster,expired}]}]}`), for "Check what they hold".
- `connectAnimPreview: (String) -> AnyView` [sessions] — preview of a connect animation id under the setting.
- `windowHasSessions: (WindowModel) -> Bool` [sessions] — a window with restored tabs is not offered the tour.
- `settingsSaved: [(before, after) -> Void]` — after Save (font size to panes only if `fontSize` changed,
  restart refresh loops, redraw explorers…). `Store.onSettingsChanged` fires too.

## Settings

`SettingsDialog.open(window)`. Writes one `Store.updateSettings` patch with the original keys:
theme, accent, skin, terminalPalette, x11, mfaMode, connectAnim, recentLimit, tshHomes, refreshSeconds,
nodeRefreshSeconds, staleNodeMinutes, sidebarHostLimit, fontSize, sidebarFontSize, fontFamily, scrollback,
cursorBlink, followTerminalFolder, showHiddenFiles, showFileDetails, foldersFirst, show3dView, externalEditor,
highlight, showShellInTitle, showPaneNetIcon, showTabActivity, confirmLinkOpen, confirmQuitWithSessions,
confirmCloseWithSessions, tmuxDefault, tmuxSessionName, requestMonitorAutoOpen, showWatchMark, agentForward,
starredMode, autoFlagLocal, autoFlagHost, plus the 0.39 keys: cursorStyle, heartbeatStyle,
showServerIcon, liveStats, localStats, statsOncePerTab, quietRemote, paneCloseAnimations,
confirmLoginToConnect, focusFollowsMouse, detectTeleportOnSsh, kubeEnabled, aiStartup, aiWorkdir,
aiLauncher, aiKeys, expiredListMode/expiredListHours, automationTyping, tshHomeEnv (home → variables).
"Stop watching all" clears `watchedHosts`. `fontSize` is always in the patch; panes compare with the
before value (`settingsSaved`). Keys not in `StoreDefaults` are read with the original's defaults in code.

Sections and search (settingsnav.js, `SettingsNav`): the groups get titled sections, a "Show"
picker for one section and a search box that keeps only matching settings; `SettingsDialog.open(window,
query:)` opens it filtered (Search everything's "Search settings for …" row).

Teleport homes: each home has a dialog (`MiscHomeDialog.run`) with Browse… (packages browsable as
folders), the resolved path line (`MiscTshEnv.homeNote`) and its own tsh variables (`MiscEnvBox`).
`MiscTshEnv` reads/checks the variable text; applying it is Teleport/Service's `TshEnv`.
`MiscEnvBox(text:placeholder:)` is the variables editor with Insert example — reusable by
teleport-ui's `tsh-env-edit` dialog.

Fonts (`MiscFonts`): `stack(setting)` (fonts.js `fontStack`), `font(setting, size:)` → NSFont
(the first family of the stack that exists), `registerBundled()` (Resources/fonts, 51 OFL fonts, done
lazily by Settings' font picker and by `font`), `choices()` for a picker.

Launch reminder (`MiscTeleportReminder`): once at install, outside `--snapshot`.

`SettingsDialog.apply(patch)` = main.js `settings:set`: writes, and applies `tshHomes` → `Tools.homes`,
`tshPath`/`sshPath` → `Tools.setTshPath/setSshPath`. Use it when you change those keys.

Theme/accent/skin preview live while the dialog is open (`MiscThemes.preview`); Cancel restores.

## Themes

`Theme.shared.p` and `Theme.shared.terminal` reflect theme/accent/skin/terminalPalette (resolver installed
first in `Theme.shared.resolvers`). 38 named themes (`MiscThemes.appThemes`, matrix new), 10 skins
(Thug Life new; `MiscThemes.skinDisplayFont(size:)` gives its UnifrakturMaguntia heading font, nil otherwise), 7 accents,
terminal palettes (`MiscThemes.terminalPalettes`: app, Solarized dark/light, Gruvbox, Nord, Dracula, High
contrast, plus every theme with its own colours). Precedence as the original: skin > accent > named theme
for the window; for the terminal named palette > named theme (unless a skin) > skin-derived > plain dark/light.
"auto" follows the system (`Theme.systemIsDark`; the shell refreshes on system changes).

`Theme.shared.terminal` keys (hex `#rrggbb`, selection `#rrggbbaa`):
`background foreground cursor cursorAccent selectionBackground selection` (alias) and the 16 ANSI
`black red green yellow blue magenta cyan white brightBlack brightRed brightGreen brightYellow brightBlue
brightMagenta brightCyan brightWhite`. `Theme.shared.terminalNSColor(key)` gives an NSColor (alpha included).

## Tour anchors

Tag the view a step points at with `.tourAnchor("id")` (records its frame per window; a view
that is hidden or smaller than 4×4 is skipped and the step is shown centred).

| id | what (original selector) | owner |
|---|---|---|
| `sidebar` | the whole host list (`#sidebar`) | **tagged by Misc** (wraps `Slots.sidebar`) |
| `panes` | the workspace (`#panes`) | **tagged by Misc** (wraps `Slots.workspace`) |
| `titlebar` | title bar (`#titlebar`) | built-in fallback (top 38 pt) |
| `host-filter` | sidebar filter field (`#host-filter`) | sidebar |
| `btn-folders` | Folders button (`#btn-folders`) | sidebar / hosts |
| `btn-heartbeats` | Heartbeats button (`#btn-heartbeats`) | sidebar |
| `teleport-tab` | sidebar's Teleport tab (`.sb-tab[data-tab=teleport]`) | sidebar |
| `keys` | sidebar "SSH keys" item (`[data-tour=keys]`) | sidebar |
| `nettools` | sidebar "Network tools" item (`[data-tour=nettools]`) | sidebar |
| `tab-add` | the + new-tab button (`#tab-add`) | sessions (tab strip) |
| `toggle-files` | title-bar explorer button | whoever fills `Slots.titlebarActions` |
| `toggle-multiexec` | title-bar multi-exec button | 〃 |
| `toggle-transfers` | title-bar transfers/dock button | 〃 |
| `global-search` | the Search everything box (`#global-search`) | **tagged by Misc** |
| `toggle-ai` | the ✦ AI button | whoever draws it |
| `sb-kind-filter` | the sidebar's kind filter (servers / Kubernetes) | sidebar — **not tagged yet** (centred) |

Four 0.39 steps (cluster browser, Helm, port-forwarding, 3D view) point at things inside the
Kubernetes browser, which is not open when the tour runs; they are centred cards (`target: nil`).

The tour is offered once per `Tour.version` (settings.`tourSeenVersion` = 6) via
`WindowManager.didOpen` 1.5 s after the first window opens, not in a second window, not when
`windowHasSessions`, never under `--snapshot`. Escape / ←/→/Return drive it.

## Shared UI (ui.js leftovers)

- `CtxMenu.show([CtxItem])` / `CtxMenu.build` — context menus with `icon`, `sub` (second line),
  `key` ("⌘⇧D"), `help` (`CtxHelp(answers:command:notes:)` → tooltip card), `.heading("…")`, `.sep`,
  `submenu`, `disabled`, `title`.
- `MiscUI.prompt(title:label:value:placeholder:confirmLabel:validate:)` — inline error from `validate`.
- `MiscUI.confirm(title:message:detail:confirmLabel:danger:)`.
- `MiscUI.pickIcon(title:subtitle:value:)` — EmojiPicker as a dialog (nil = cancelled, "" = none).
- Form pieces: `MiscField(label:hint:)`, `MiscCheck(label:isOn:note:)`, `MiscHint`, `MiscRule`,
  `OptionPicker(options:selection:)` (ui.js `select`).

## Backup

`BackupUI.exportSettings / importSettings / reloadAfterImport`. The envelope functions in
`BackupOps.swift` are a faithful stand-in for main/backup.js because Data/ had not published them;
when Data/ publishes, each `BackupOps` function should forward to Data's.

## Not done / differences

- About omits the Electron/Chromium/Node rows (not applicable); adds Build and macOS.
- Guide search marks every occurrence (the original marked the first per DOM text node) and a hit under
  a `###` heading marks its enclosing section in the list.
- Settings shows an extra `ssh:` line next to the `tsh:` line.
- Search everything's "Search settings for …" opens Settings filtered (Settings' own "No setting
  matches."); the original's status line "No setting mentions “…”" and the row flash are not ported.
- Resources/CHANGELOG.md and Resources/GUIDE.md (lead's) still end at 0.15.2: Version history and the
  guide show the old text until they are copied from upstream.
- The bundled fonts are registered lazily from Misc (`MiscFonts.registerBundled`), not at launch;
  the terminal uses `fontFamily` only if Sessions resolves it with `MiscFonts.font`.
