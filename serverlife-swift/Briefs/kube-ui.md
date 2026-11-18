# Brief: kube-ui

Read `Briefs/_common.md` and `CLAUDE.md` first. Wave 2.

```sh
A="Scripts/agent.sh kube-ui Sources/ServerLife/Kube/UI,Tests/ServerLifeTests/KubeUI"
$A pull && cd "$($A path)"      # then: $A build · $A test --filter KubeUI · $A publish
```

## Upstream files (`serverlife/…` in the original)

- `src/renderer/js/kubebrowser.js` (NEW, +3809/−0)
- `src/renderer/js/kubepanel.js` (NEW, +2237/−0)
- `src/renderer/js/kube3d.js` (NEW, +722/−0)
- `src/renderer/js/kubecloud.js` (NEW, +266/−0)
- `src/renderer/js/kubeconfigedit.js` (NEW, +186/−0)
- `src/renderer/js/kubeheartbeat.js` (NEW, +189/−0)
- `src/renderer/js/kubelogviewer.js` (NEW, +143/−0)
- `src/renderer/js/kubenamespaces.js` (NEW, +50/−0)
- `src/renderer/js/alerts.js` (NEW, +47/−0)
- `src/renderer/js/yamlform.js` (NEW, +49/−0)
- `src/renderer/js/yamlpath.js` (NEW, +61/−0)

## What to port (from the 0.16.0–0.39.0 changelog — check it for more)

- The cluster browser (kubebrowser.js, 3.8k lines): overview (pods by phase), resources, details,
  CRD columns, metrics, security/RBAC, editing (CodeEditor), Helm, navigation, many clusters,
  alerts (crash loops, stalled rollouts — no re-firing), export, click a workload to its pods,
  My access, stars, ☁ Cloud view, typed namespaces, toolbar (0.39), run a command in a pod.
- kubepanel.js (2.2k): the Kubernetes rows in the sidebar (`Slots.sidebarSections["kube"]`),
  the cluster right-click menu (`kube-host-menu`), pod exec/logs/attach/debug, node shell, port
  forwards, Install Teleport agent wizard, Map a Teleport group to a ClusterRole…, reconnect
  after login, kube tabs restored after restart.
- kube3d.js diagrams (SceneKit or a 2D fallback — see how City/ draws), kubecloud badges,
  kubeconfig editor, kubeheartbeat, log viewer, namespaces prompt.
- Build on kube-service's API (stand-in until it publishes). Register `kube-browser`,
  `kube-host-menu`, `kube-pod-exec`, `kube-pod-logs`, `kube-port-forward`.
