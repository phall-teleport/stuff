# Upstream sync: 0.15.2 → 0.39.0

The Swift port matches the original at **0.15.2** (`ce8d055`, 2026-10-07).
Upstream `origin/main` (`329dcb1`) is at **0.39.0** (2026-11-17), 24 releases later.

Delta in `serverlife/` (excluding fonts): **~34.8k lines added in src/ + mcp/**,
~8.9k in tests, +1.5k in GUIDE.md and +1.4k in CHANGELOG.md. The full list:

```sh
cd ~/git/teleport-toys-internal
git diff --stat ce8d055 origin/main -- serverlife
git show origin/main:serverlife/CHANGELOG.md | sed -n '13,1462p'   # 0.16.0 … 0.39.0
```

## Work packages by owner

Line counts are lines added upstream. "new" = file did not exist at 0.15.2.

| Owner | Upstream files | Main features (release) |
|---|---|---|
| lead | main.js +1426, preload.js +228, index.html, styles.css +942, util.js, state.js, ui.js, csv.js new, textdiff.js new, alerts.js new, store.js defaults (regen StoreDefaults) | IPC for everything below; 51 bundled fonts (0.28) → Resources/fonts + CTFontManager registration; Redraw (0.34); focus follows mouse (0.25/0.26) |
| **ai** (new: `AI/`) | ai.js 1107 new, aiclients.js 373 new, aiwaiting.js new, search.js 359 new | AI assistant panel, check before open, assistant at startup, type into sessions with approval, read a pane (0.16); Search everything, Ask the AI, saved prompts/responses, past conversations, named sessions, several sessions (0.17); Esc/↑/↓/Enter buttons (0.18); pane picker for typing (0.21) |
| **kube-service** (new: `Kube/Service/`) | kube.js 673, kubebin, kubeexplain, kubeexport, kubeforward, kubefs, kubegraph, kubehelm, kubekustomize, kubelint, kubelogs, kubemetrics, kubeops 340, kubeprovider 286, kubeproxy, kuberbac, kuberelations, kuberesources 949, kubescan, kubetest, kubewatch, jsonpath-lite — all new (~4.9k) | KubeLife (0.30–0.39): cluster browser data, Helm, metrics, RBAC, workload actions, export CSV/JSON/YAML, cloud detection EKS/GKE/AKS, heartbeats, `tsh proxy kube` for MFA clusters, run a command in a pod |
| **kube-ui** (new: `Kube/UI/`) | kubebrowser.js 3809, kubepanel.js 2237, kube3d.js 722, kubecloud, kubeconfigedit, kubeheartbeat, kubelogviewer, kubenamespaces, yamleditor/yamlform/yamlpath/yamlview, cmtheme — all new (~7.8k) | Cluster browser, My access, diagrams, stars, details, editing, live rows, ☁ Cloud view, kubeconfig editor, Kubernetes profiles, kube tabs restored |
| connections | connections.js +446, sshbin.js +66, sshoptions.js 251 new (main), localmonitor.js 161 new, local.js +35 | SSH options per host (0.16); MFA mid-run, orphan master kill, changed host key fix (0.22); access-denied login fix (0.24); live stats incl. local (0.29/0.34); one login at a time (0.39) |
| teleport-service | teleport.js +477, beams.js +296, sshconfig.js +130, vnet.js 192 new, phasesetup.js 777 new | VNet per cluster, login method (0.16); cluster version (0.21); expired-cluster listing (0.26); Phases + setups (0.28/0.34/0.38); tsh env per cluster (0.29); install Teleport on SSH host (0.32) |
| teleport-ui | teleportpanel.js +454, beams.js +938, requestpicker +162, recordings +92, reqmonitor, tshenv.js 149 new, phasebuilder 378 new, phaseaddins 135 new, phasepicker 116 new | Phase builder/add-ins/picker, Phases in Folders/List/Relationships (0.38.1); Start a beam → Start from; beam macros; login-in-flight box (0.25); Connect cluster (0.20); recordings for kube/app/db (0.31) |
| sessions | sessions.js +962, term.js, workspace.js +65, paneclose.js 330 new, panestyle.js 279 new | Look per pane (0.17); ↻ Reconnect on pane (0.20); pane-close animation (0.25); split with nothing focused, new local where last was (0.26); tmux pane close closes in tmux (0.29); layouts reattach tmux, beam tmux tabs reopen (0.38) |
| sidebar | sidebar.js +1859, hostactions +206, heartbeat, narrowed, tags, requestable, clustermarks, pinned.js new, hosticons.js new | All/SSH/K8s filter, kube rows, pinned clusters (0.27), server icon (0.34), ⚡ Add to Teleport (0.32), per-cluster Refresh (0.21), cert-expiry tag (0.20) |
| hosts | hostspane.js +688, profiles +163, addserver +61, folders.js +79, quickconnect, sshoptions.js 295 new (UI), sshpresets.js 237 new, sshconfigeditor.js 85 new | Saved group, SFTP profiles, colour/icon (0.22); heartbeats + Heartbeat column, All/SSH/K8s (0.37); ssh config editor + common options (0.32); delete/comment host, New host in this config (0.18) |
| explorer | explorer.js +274, watch.js +86, files.js | Free space footer (0.26); connect-failure text, MFA gate fix (0.25) |
| files-service | transfers.js +82, crosstransfer.js +28 | (follow-ups for the above) |
| fleet | dock.js +732, macros.js +548, macrorecord.js 256 new, mxschedule.js 105 new, multiexec.js (main) +270 | Record a macro, retries, scheduled/staged multi-exec, Run as (0.17); drag macros (0.19); dock fits content (0.22); Teleport macros (0.27); careful macro cost (0.29) |
| nettools | nettools.js main +535 / renderer +1035, decoders.js 601 new, sockets.js 246 new, keys.js +82, sshkeys.js +180 | Subnet calc, URL enc/dec, SSH cert/JWT/SVID decoders (0.18); Readable/Raw (0.19); runnable command per tool (0.23); CAA/SOA/NAPTR, IP family, STARTTLS, curl --resolve, sockets panel, PKCS#11 (0.25) |
| consoles | tmux.js +94, vnc.js | tmux attach fixes (0.18), reattach (0.38) |
| misc | settingsnav.js 100 new, themes.js, tour.js +113, fonts.js 90 new, bundledfonts.js 59 new, versions.js | Settings in sections with search (0.34); Matrix theme (0.27); Thug Life skin, launch reminder (0.28); cursor style (0.24); No background commands (0.29) |
| automation | automation.js +433, mcp/serverlife-mcp.mjs +160 | get/set settings, close_session asks (0.24); beams by name (0.18); KubeLife over MCP (0.31) |
| data | store.js +81, multiexecfile.js +16, backup.js +3 | New store methods/keys for all of the above |

Resources (lead): replace `Resources/GUIDE.md` and `Resources/CHANGELOG.md` with
0.39.0's once the features exist; add `Resources/fonts/` (51 .ttf + licences).

## Suggested order

1. lead: refresh StoreDefaults from store.js, fonts, preload/main IPC surface,
   new Action ids (ai-*, kube-*, phase-*), Resources.
2. In parallel: connections, teleport-service, data, nettools, fleet, misc,
   automation (mostly self-contained).
3. Then sessions, sidebar, hosts, explorer, teleport-ui (depend on 2).
4. New owners ai, kube-service, kube-ui last (largest, most self-contained).
