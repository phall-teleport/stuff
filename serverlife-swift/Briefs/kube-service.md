# Brief: kube-service

Read `Briefs/_common.md` and `CLAUDE.md` first. Wave 1.

```sh
A="Scripts/agent.sh kube-service Sources/ServerLife/Kube/Service,Tests/ServerLifeTests/KubeService"
$A pull && cd "$($A path)"      # then: $A build · $A test --filter KubeService · $A publish
```

## Upstream files (`serverlife/…` in the original)

- `src/main/kube.js` (NEW, +673/−0)
- `src/main/kubebin.js` (NEW, +280/−0)
- `src/main/kubeexplain.js` (NEW, +64/−0)
- `src/main/kubeexport.js` (NEW, +147/−0)
- `src/main/kubeforward.js` (NEW, +117/−0)
- `src/main/kubefs.js` (NEW, +163/−0)
- `src/main/kubegraph.js` (NEW, +280/−0)
- `src/main/kubehelm.js` (NEW, +285/−0)
- `src/main/kubekustomize.js` (NEW, +33/−0)
- `src/main/kubelint.js` (NEW, +73/−0)
- `src/main/kubelogs.js` (NEW, +70/−0)
- `src/main/kubemetrics.js` (NEW, +94/−0)
- `src/main/kubeops.js` (NEW, +340/−0)
- `src/main/kubeprovider.js` (NEW, +286/−0)
- `src/main/kubeproxy.js` (NEW, +126/−0)
- `src/main/kuberbac.js` (NEW, +60/−0)
- `src/main/kuberelations.js` (NEW, +34/−0)
- `src/main/kuberesources.js` (NEW, +949/−0)
- `src/main/kubescan.js` (NEW, +126/−0)
- `src/main/kubetest.js` (NEW, +138/−0)
- `src/main/kubewatch.js` (NEW, +137/−0)
- `src/main/jsonpath-lite.js` (NEW, +81/−0)
- `tests/kuberesources.test.mjs` (NEW, +302/−0)
- `tests/kubeops.test.mjs` (NEW, +184/−0)
- `tests/kubegraph.test.mjs` (NEW, +176/−0)
- `tests/kubeprovider.test.mjs` (NEW, +169/−0)

## What to port (from the 0.16.0–0.39.0 changelog — check it for more)

- The whole KubeLife main side (0.30–0.39), ~4.9k lines: kubectl/helm/k9s/minikube lookup (kubebin),
  kubeconfig contexts, resources/list/watch (live rows, no flicker), metrics, RBAC, ops (workload
  actions, debugging, run a command in a pod), helm, logs, port-forward, export CSV/JSON/YAML,
  graph/relations for diagrams, provider/cloud detection (EKS/GKE/AKS), lint/explain/kustomize,
  `tsh proxy kube` for MFA clusters (one start per cluster, stopped on quit — register
  `app-will-quit`), heartbeats data, settings keyed by Teleport cluster name (0.39).
- Grep main.js for the `kube:` IPC handlers and port their bodies here.
- Publish a typed Swift API early (README) — kube-ui, sidebar, hosts and automation build on it.
  Register `kube-refresh`, `kube-contexts`. Port the kube*.test.mjs tests. Never run kubectl against
  a real cluster that changes anything; read-only `kubectl config view` is fine.
