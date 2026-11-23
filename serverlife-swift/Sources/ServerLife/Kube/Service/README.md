# Kube/Service — KubeLife's main side (kube-service owner)

Ports `src/main/kube*.js` and `jsonpath-lite.js` (0.30–0.39). The original's
`kube:*` / `kubeconfig:*` IPC handlers in main.js are thin wrappers over those
modules; here they are plain Swift calls. Results keep the original's JSON
shape (`{ok, error, …}` via `kubeOk` / `kubeFail`) so the UI ports read the
same keys. Pushes (`kube:logsEvent`, `kube:watchEvent`, `kube:metricsSample`,
`kube:forwardUpdate`) become main-actor callbacks / an observable list.

Everything takes a `KubeSpec` (the original's `spec`): `contextName`,
`kubeconfigPaths`, `namespace`, `podName`, `containerName`, `shell`, `image`,
`nodeName`, `selector`, `kubeClusterName`, `teleportCluster`, `teleportProxy`,
`source`. `spec.json` / `KubeSpec(json:)` convert. Terminal specs come back as
`KubeCommandSpec {command, args, env}` — hand them to `open-command`
(`exe`/`argv`/`env: fullEnvironment`).

## Files → original modules, and the main.js handler each replaces

| Swift | JS | main.js handlers |
|---|---|---|
| `KubeBin` | kubebin.js | kubectl/tool lookup, `humanizeKubectlError`, `explainMissing`, `KubeRun` |
| `Kube` | kube.js | `kube:contexts` (`listContexts`), `kube:clusters` (`listKubeClusters`), `kube:login`, `kube:useContext`, `kube:deleteContext`, `kube:editContext`, `kube:namespaces`, `kube:pods`, `kube:exec` (`execRun`), `execSpec`/`attachSpec`/`debugSpec`/`nodeDebugSpec`/`logSpec`, `kube:kubeconfigEnv` (`kubeconfigEnvFor`), `kube:installTeleportAgent`, `kube:teleportAgentValues` |
| `KubeResources` (+ `KubeAccess`, `KubeHeartbeat`) | kuberesources.js | `kube:resourceTypes` (`discoverResourceTypes`), `kube:resources` (`getResources`), get/yaml/describe/diff/apply/validate/delete, top, cordon/drain, columns, CRD columns, `canI`/`access`/`whoCan`, `heartbeatState`, `kube:agents` (`kubeAgents`), `kube:cloudInfo`, `kube:detectProvider` |
| `KubeService` | main.js | `kube:heartbeat`, `kube:heartbeatTeleport` — **use these, not the ungated `KubeResources.heartbeat*`**: they apply the `quietRemote` gate (`quietDetail` = "Background commands on servers are off in Settings.") and pass `mfaHosts`. `stopAll()` is quit cleanup |
| `KubeOps` (+ `KubeManifests`) | kubeops.js | scale, rollout (+history), set image/env/resources, cron trigger/suspend, delete many, evict, `manifestFor`, `parseRules`/`parseSubjects`, `groupBinding`, `teleportRoleFor` |
| `KubeHelm` | kubehelm.js | releases, history, values, manifest, rollback, uninstall, repos, install/upgrade, search, readme, schema → `fieldsFromSchema`, test, template |
| `KubeExport`, `KubeKustomize`, `KubeExplain` | kubeexport.js, kubekustomize.js, kubeexplain.js | export JSON/YAML (a `kind: List`, optional `clean`), `kustomize build`, `kubectl explain --recursive` fields. CSV export is renderer-side (kube-ui) |
| `KubeGraph` | kubegraph.js | manifest/cluster graph, Mermaid text |
| `JSONPathLite`, `KubeRelations`, `KubeRBAC` (KubePure.swift) | jsonpath-lite.js, kuberelations.js, kuberbac.js | pure helpers |
| `KubeProvider` | kubeprovider.js | EKS/GKE/AKS/local detection, console URL, node pools, cloud identities, aws-auth |
| `KubeFS` | kubefs.js | `kube:ls/mkdir/rm/rename/readFile/writeFile/downloadPath/uploadPath` |
| `KubeScan`, `KubeLint` | kubescan.js, kubelint.js | the 3D scene (`buildScene`), Popeye scan |
| `KubeTest` | kubetest.js | ServiceAccount self-check pod |
| `KubeLogs.shared`, `KubeWatch.shared`, `KubeMetrics.shared` (KubeStreams.swift) | kubelogs.js, kubewatch.js, kubemetrics.js | `kube:logsStart/Stop`, `kube:watchStart/Stop` (rows already through `rowFrom`, no flicker), `kube:metricsStart/Stop` — `start(…, onEvent/onSample:)` → `{ok, id}` |
| `KubeForward.shared` | kubeforward.js | `kube:forwardStart/Stop/List`; `@Observable forwards` + `onChange` replace `kube:forwardUpdate` |
| `KubeProxy.shared` | kubeproxy.js | `kube:proxyStart` (`ensure`/`startJSON`, one per cluster), `kube:proxyStop`, `kube:proxyStatus` |
| `KubeConfigFiles` | main.js `kubeconfig:*` | `files`, `read`, `check`, `write` (backup to `<file>.serverlife-backup`, mode kept), pure `warnings` |
| `KubeContexts.shared` | renderer contexts cache | `@Observable contexts/loading/loaded/lastError/generation`; `ensureLoaded()`, `reload()`, `onLoaded` |
| `KubeKeys`, `Host.kubeAwarePrefKey` | store.js `hostPrefKey` (0.39) | settings key `kube:<teleportCluster>:<name>`, else `kube:<groupKey>:<name>`, else the id |
| `KubeYAML` | js-yaml usage | `load`, `loadAll`, `dump`, ordered `YAMLValue` |

Settings (same keys/defaults as store.js): `Store.kubeSettingEnabled`
(`kubeEnabled`), `kubeSettingConfigPaths` (`kubeconfigPaths`),
`kubeSettingRefreshSeconds` (`kubeRefreshSeconds`), `kubeSettingQuietRemote`
(`quietRemote`), `kubeSettingMfaHosts` (`mfaHosts`).

## Action ids

Registered (`KubeServiceFeature.install()`):

- `kube-refresh` — reload the kubeconfig contexts (`KubeContexts.shared.reload()`).
- `kube-contexts` — query: `args["reply"]` `(Any?) -> Void` gets `[JSON]` contexts (loads if needed).
- `app-will-quit` — stops every proxy, log, watch, metrics poll and port-forward.

Consumed: none.

## Not done / notes

- `App/Features.installAll` does not call `KubeServiceFeature.install()` yet
  (App is the lead's). Until it does, install happens lazily on the first
  stream/forward/proxy start, and kube-ui should call it from its own
  `install()`. Requested from lead.
- `Host.prefKey` (Core) lacks the 0.39 kube branches; `Host.kubeAwarePrefKey`
  / `KubeKeys.prefKey` provide them. Requested from lead.
- The folders.js half of kubekeys (migrating old kube keys) belongs to hosts;
  kuberequest.test.mjs tests teleport.js (teleport-service).
- Key order: JSON results are sorted by key (the Swift `JSON` type); manifests
  and exports keep kubectl's order through `YAMLValue`.
