# Data

Owner: data. Ports `src/main/store.js` (record methods) and `src/main/backup.js`.

## Store records — `StoreRecords.swift`

`extension Store` (main actor), one implementation per collection. Records are
`JSON` objects, not Codable structs, so updates merge exactly like store.js's
`{ ...existing, ...patch }` and fields this build does not know survive an
edit. Feature code may wrap them (e.g. `DownloadHistory.Row`).

| Collection | Methods | Rules |
|---|---|---|
| profiles | `listProfiles` `getProfile` `upsertProfile` `deleteProfile` `markProfileUsed` (store.js `markUsed`) | id `p_`; new record gets store.js's full shape (0.39: `sshExtraOptions`, `kube`, `icon`); append |
| folders | `listFolders` `upsertFolder` `deleteFolder` | id `f_`; delete unfiles its profiles |
| history | `startHistory` `endHistory` `listHistory(limit: 200)` `listRecent(limit: 20)` `Store.listRecent(_:limit:)` `clearHistory` | id `h_`; newest first, cap 500; ends once; recent = one per type+cluster+node/target/label+login+home+direct port |
| workspaces | `saveWorkspace(_:slot:)` `getWorkspace` `listWorkspaces` `Store.workspaceList` `clearWorkspace` | `workspace` mirrors slot w1; list skips empty, slot-number order |
| layouts | `listLayouts` (adds `isDefault`) `getLayout` `saveLayout(id:name:workspace:)` `deleteLayout` `setDefaultLayout` `getDefaultLayout` | id `l_`; overwrite by id, else by name (case-insensitive) |
| snippets | `listSnippets` `upsertSnippet` `deleteSnippet` `markSnippetUsed` | id `s_`; name = first line, 40 UTF-16 units |
| macros | `listMacros` → `{macros, hidden, categoryOrder, order, pins}` `upsertMacro` `deleteMacro` `setMacroPin` `setMacroHidden` `setMacroCategoryOrder` `setMacroOrder` (`macros:arrange`) `markMacroUsed` | id `m_`; `where`/pin scope ∈ all, hosts, **beams**, local; pins append, re-pin keeps place, icon ≤ 8, scope default hosts; delete unpins; hidden is an ordered set; `macroOrder` = dragged ids, deduped, empties dropped |
| s3Targets | `listS3Targets` `getS3Target` `upsertS3Target` `deleteS3Target` | id `s3_`; whole record rewritten, `createdAt` kept |
| downloads | `addDownload` `listDownloads` `deleteDownload` `clearDownloads` | id `dl_`; one per localPath (merged, moved to top); cap 300; list newest `at` first |
| execRuns | `addExecRun` `listExecRuns` `deleteExecRun` `clearExecRuns` | id `mx_`; same command + same host set replaces; hosts ≤ 60; cap 40 |
| netRequests | `listNetRequests` `saveNetRequest` `deleteNetRequest` | id `req_`; update keeps first `savedAt`; sorted by `lastRunAt || savedAt` |
| netRuns | `addNetRun` `listNetRuns` `clearNetRuns` | id `run_`; cap 25; summary ≤ 160; same tool + target + host (id or label) replaces |
| forwardFavorites | `listForwardFavorites` `addForwardFavorite` (throws) `updateForwardFavorite` `markForwardFavoriteUsed` `deleteForwardFavorite` | id `fwd_`; one per host.id + bindPort + kind |
| sessionNotes | `listSessionNotes` `upsertSessionNote` `deleteSessionNote` | keyed by `sid`; no flag and blank note deletes; newest `updatedAt` first |
| tshLogins | `listTshLogins` `upsertTshLogin` `deleteTshLogin` `markTshLoginUsed` | id `tl_`; one per proxy + user + home; `showInHosts` (keep its Hosts group when tsh no longer lists it); sorted by `lastUsed || updatedAt` |
| requestTemplates | `listRequestTemplates(proxy:cluster:)` `upsertRequestTemplate` `deleteRequestTemplate` `markRequestTemplateUsed` `Store.trimRequestResources` | id `rq_`; filter proxy *or* cluster; resources trimmed to id/kind/name/cluster |

JS helpers (module-level): `dOr` (`a || b`), `dStr` (`String(x || '')`),
`dNum` (`Number(x) || n`), `dSlice` (UTF-16 `.slice`), `dTime`, `dSortedDesc`
(stable, like `Array.prototype.sort`).

`Store.hostPrefKey(_ host: JSON)` (`HostPrefKey.swift`) — store.js
`hostPrefKey` on a JSON descriptor, with the 0.30+ kube branches:
`kube:<teleportCluster>:<name>`, else `kube:<groupKey>:<name>` (uuid still
wins). `Host.prefKey` in Core does not have the kube branches yet (lead).

Settings keys (`macroOrder` top level; `hostsPaneProfiles`, `hostsPaneSort`,
`aiKeys`, `cursorStyle`, `paneCloseAnimations`, `notBeamProxies`,
`quietRemote`, `detectTeleportOnSsh`, `kubeEnabled`, `kubeconfigPaths`,
`kubeRefreshSeconds`, `watchedKubeClusters`) come from
`Core/StoreDefaults.swift`; each feature declares its typed accessor.

store.js's `emit('changed')` has no counterpart: `Store` is `@Observable`.

## Backup — `Backup.swift`

`macroOrder` is part of a full backup and of a macro export (empty when
only some ids are exported), and merges/replaces like `macroCategoryOrder`.
`Backup.exportAll(store)`, `exportMacros(store, ids)`, `parse(text)` (throws
the original's messages), `describe(doc)`, `applyImport(store, doc, mode:)`,
`envelope`, `fullKeys`, `listKeys`. `Misc/BackupOps` forwards here.

## Forwarders elsewhere

`SBData` (Sidebar), `HostsData` (Hosts), `FleetStore` (Fleet), `NetSaved`
(NetTools), `TUIData` (Teleport/UI), `Store.auto…` (Automation),
`DownloadHistory` (Files/Service), `WorkspaceStore` (Sessions),
`Inventory.savedLogins/markSavedLoginUsed` (Teleport/Service),
`SessionsWindow.markProfileUsed`, `ConnectionManager.defaultStart/EndHistory`.

## Multi-exec file options — `MultiExecFileOptions.swift`

multiexecfile.js itself is ported in `Fleet/Formats/MultiExecFile.swift`
(fleet's path). Its 0.17 additions are here as pure helpers for fleet to call:
`MXFileOptions.Extras { stages: Stages?, retries, retryDelaySeconds }`,
`MXFileOptions.yamlEntries(_:)` (append to `options` after `stopOnError`;
null stages is stripped by `MultiExecFile.stripNulls`) and
`MXFileOptions.parse(options:)` (stages first `||1`, batch `||5`,
pause/stopOnFail `!== false`; retries floor, 0…10; delay `?? 10`, 0…3600 s).

## Not done

- Folding `MXFileOptions` into `MultiExecFile.toYaml/fromYaml/Options` — the
  file belongs to fleet.
- `Host.prefKey` kube branches and `macroOrder` in `Store.apply`'s
  must-be-array list — Core belongs to lead (`Store.hostPrefKey` is the JSON
  equivalent; `recs` treats a missing `macroOrder` as empty).
- ansible.js is not part of this pass.

Tests: `Tests/ServerLifeTests/Data/StoreRecordsTests.swift` (throwaway `Store(dir:)`).
