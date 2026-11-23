import Foundation

/// The kube side of Teleport and of plain kubeconfig files (kube.js):
/// `tsh kube ls` / `tsh kube login`, the contexts in the kubeconfig files,
/// and the one place (`kubectlArgsFor`) that branches between talking to a
/// cluster directly and through Teleport.
///
/// Results are JSON objects with the original's keys (`{ok, error, …}`), so
/// the UI reads them the way the renderer did.
enum Kube {
    // MARK: - tsh kube

    /// Global tsh flags that have to precede the subcommand.
    static func base(proxy: String?, jumphost: String? = nil) -> [String] {
        var args: [String] = []
        if let proxy, !proxy.isEmpty { args.append("--proxy=" + proxy) }
        if let jumphost, !jumphost.isEmpty { args.append("--jumphost=" + jumphost) }
        return args
    }

    /// `tsh … kube <sub> …`, with the flags tsh insists come first.
    static func argsFor(_ sub: String, _ rest: [String] = [], proxy: String? = nil, jumphost: String? = nil) -> [String] {
        base(proxy: proxy, jumphost: jumphost) + ["kube", sub] + rest
    }

    static func runTsh(_ args: [String], home: String?, timeout: TimeInterval = 60) async -> ProcResult {
        await Teleport.run(args, home: home, timeout: timeout)
    }

    /// Whether this cluster serves Kubernetes at all — so a cluster that has
    /// none (or a tsh too old) never grows an empty Kubernetes branch.
    static func supported(proxy: String?, home: String?) async -> JSON {
        let r = await runTsh(argsFor("ls", ["--format=json"], proxy: proxy), home: home, timeout: 45)
        let out = kubePlain(r.out)
        if r.ok && (out.hasPrefix("[") || out == "null" || out.hasPrefix("{")) { return kubeOk() }
        let error = kubeOr(kubeOr(kubePlain(r.err), out), "tsh kube ls said nothing")
        return ["ok": false, "error": .string(error),
                "unsupported": .bool(TPText.test("no kubernetes clusters|not implement this feature|unknown command", error, .caseInsensitive))]
    }

    /// One `tsh kube ls` entry as a sidebar descriptor.
    static func toKubeCluster(_ c: JSON, proxy: String?, home: String?) -> JSON {
        let kubeName = c["kube_cluster_name"].kStr, clusterName = c["cluster_name"].kStr
        let name = kubeOr(kubeName, clusterName)
        let labels = c["labels"].object.map(JSON.object) ?? [:]
        let h = home?.nilIfEmpty
        return [
            "provider": KubeProvider.combine(KubeProvider.fromLabels(labels), KubeProvider.fromName(name)) ?? .null,
            "id": .string("kube:tsh:\(proxy ?? "")\(h.map { ":" + $0 } ?? ""):\(kubeOr(clusterName, kubeName))"),
            "kind": "kube",
            "source": "teleport",
            "name": .string(name),
            "cluster": .string(clusterName),
            "proxy": .string(proxy ?? ""),
            "home": JSON(h),
            "labels": labels,
            "requestable": true,
        ]
    }

    static func listKubeClusters(proxy: String?, home: String?) async -> JSON {
        let r = await runTsh(argsFor("ls", ["--format=json"], proxy: proxy), home: home, timeout: 45)
        let out = kubePlain(r.out)
        if out == "null" || out == "[]" { return kubeOk(["clusters": []]) }
        if let at = out.firstIndex(of: "["), let data = try? JSON.parse(String(out[at...])), let list = data.array {
            return kubeOk(["clusters": .array(list.map { toKubeCluster($0, proxy: proxy, home: home) })])
        }
        return kubeFail(kubeOr(kubeOr(kubePlain(r.err), out), "Could not read the Kubernetes cluster list"), ["clusters": []])
    }

    /// `tsh kube login <cluster>`: writes the per-cluster kubeconfig kubectlArgsFor() points at.
    static func loginKubeCluster(proxy: String?, home: String?, cluster: String) async -> JSON {
        let r = await runTsh(argsFor("login", [cluster], proxy: proxy), home: home, timeout: 60)
        if !r.ok { return kubeFail(kubeOr(kubeOr(kubePlain(r.err), kubePlain(r.out)), "tsh kube login failed")) }
        return kubeOk()
    }

    // MARK: - kubeconfig contexts

    /// `$KUBECONFIG` split, or `~/.kube/config`.
    static func defaultKubeconfigPaths() -> [String] {
        if let env = ProcessInfo.processInfo.environment["KUBECONFIG"], !env.trimmed.isEmpty {
            return env.split(separator: ":").map { String($0).trimmed }.filter { !$0.isEmpty }
        }
        return [NSHomeDirectory() + "/.kube/config"]
    }

    /// A kubeconfig user written by `tsh kube login`: `{kubeCluster, cluster, proxy}`.
    static func teleportOriginOf(_ user: JSON) -> (kubeCluster: String, cluster: String, proxy: String)? {
        guard let args = user["exec"]["args"].array?.map({ $0.stringish ?? "" }) else { return nil }
        let cmd = user["exec"]["command"].kStr
        guard !cmd.isEmpty, TPText.test(#"tsh(\.exe)?$"#, cmd, .caseInsensitive) else { return nil }
        guard args.count >= 2, args[0] == "kube", args[1] == "credentials" else { return nil }
        func flag(_ name: String) -> String {
            guard let hit = args.first(where: { $0.hasPrefix("--\(name)=") }) else { return "" }
            return String(hit.dropFirst(name.count + 3))
        }
        let kubeCluster = flag("kube-cluster"), cluster = flag("teleport-cluster"), proxy = flag("proxy")
        if kubeCluster.isEmpty || cluster.isEmpty { return nil }
        return (kubeCluster, cluster, kubeOr(proxy, cluster))
    }

    static func teleportOriginJSON(_ user: JSON) -> JSON {
        guard let o = teleportOriginOf(user) else { return .null }
        return ["kubeCluster": .string(o.kubeCluster), "cluster": .string(o.cluster), "proxy": .string(o.proxy)]
    }

    /// kubectl itself, or — when there is none — `tsh kubectl`, which tsh ships.
    static func kubectlCommand() -> (bin: String, prefix: [String], missing: Bool, viaTsh: Bool) {
        if KubeBin.kubectlAvailable() { return (KubeBin.findKubectl(), [], false, false) }
        if Tools.tshAvailable { return (Tools.tsh, ["kubectl"], false, true) }
        return (KubeBin.findKubectl(), [], true, false)
    }

    static func execBin(_ bin: String, _ args: [String], env: [String: String?], timeout: TimeInterval = 15) async -> KubeRun {
        await KubeBin.run(bin, args, env: env, timeout: timeout)
    }

    static func execKubectl(_ args: [String], env: [String: String?], timeout: TimeInterval = 15) async -> KubeRun {
        let c = kubectlCommand()
        return await execBin(c.bin, c.prefix + args, env: env, timeout: timeout)
    }

    private static func kubeconfigEnv(_ paths: [String]) -> [String: String?] {
        KubeBin.kubectlEnv(["KUBECONFIG": paths.joined(separator: ":")])
    }

    /// Every context in the kubeconfig files: the default ones plus `extraPaths`.
    static func listContexts(extraPaths: [String] = []) async -> JSON {
        let paths = (defaultKubeconfigPaths() + extraPaths).filter { !$0.isEmpty && FileManager.default.fileExists(atPath: $0.expandingTilde) }
        if paths.isEmpty { return kubeOk(["contexts": [], "paths": []]) }
        if kubectlCommand().missing { return kubeFail(KubeBin.kubectlMissingMessage(), ["contexts": [], "paths": JSON(paths)]) }
        let r = await execKubectl(["config", "view", "-o", "json"], env: kubeconfigEnv(paths))
        if !r.ok { return kubeFail(kubeOr(kubePlain(r.stderr), "kubectl config view failed"), ["contexts": [], "paths": JSON(paths)]) }
        guard let data = try? JSON.parse(r.stdout) else {
            return kubeFail("Could not read the kubeconfig as JSON", ["contexts": [], "paths": JSON(paths)])
        }
        var usersByName: [String: JSON] = [:]
        var clustersByName: [String: JSON] = [:]
        for cl in data["clusters"].items {
            clustersByName[cl["name"].kStr] = cl["cluster"].truthy ? cl["cluster"] : [:]
        }
        // The last of duplicate names wins, as with `new Map(...)`.
        for u in data["users"].items { usersByName[u["name"].kStr] = u["user"] }
        let current = data["current-context"].string
        let contexts: [JSON] = data["contexts"].items.map { c in
            let name = c["name"].kStr
            let ctxCluster = c["context"]["cluster"].kStr
            let user = usersByName[c["context"]["user"].kStr] ?? .null
            let tp = teleportOriginOf(user)
            let provider = KubeProvider.combine(
                KubeProvider.fromKubeconfig(contextName: name, clusterName: ctxCluster,
                                            server: clustersByName[ctxCluster]?["server"].kStr ?? "",
                                            exec: user["exec"]),
                KubeProvider.fromName(tp?.kubeCluster ?? name))
            return [
                "provider": provider ?? .null,
                "id": .string(tp.map { "kube:tsh:\($0.proxy):\($0.cluster):\($0.kubeCluster)" } ?? "kube:direct:\(name)"),
                "kind": "kube",
                "source": .string(tp != nil ? "teleport" : "direct"),
                "name": .string(name),
                "contextName": .string(name),
                "cluster": .string(ctxCluster),
                "namespace": .string(c["context"]["namespace"].kStr),
                "kubeconfigPaths": JSON(paths),
                "current": .bool(current == name),
                "requestable": false,
                "teleportProxy": JSON(tp?.proxy),
                "teleportCluster": JSON(tp?.cluster),
                "kubeClusterName": JSON(tp?.kubeCluster),
            ]
        }
        return kubeOk(["contexts": .array(contexts), "paths": JSON(paths)])
    }

    /// `kubectl config use-context` — what plain kubectl in a terminal then uses.
    static func useContext(contextName: String?, kubeconfigPaths: [String] = []) async -> JSON {
        guard let contextName, !contextName.isEmpty else { return kubeFail("No context given") }
        let r = await execKubectl(["config", "use-context", contextName], env: kubeconfigEnv(kubeconfigPaths))
        return r.ok ? kubeOk() : kubeFail(kubeOr(kubePlain(r.stderr), "kubectl config use-context failed"))
    }

    /// Remove a context, and its user and cluster entries when nothing else uses them.
    static func deleteContext(contextName: String?, kubeconfigPaths: [String] = [], dryRun: Bool = false) async -> JSON {
        guard let contextName, !contextName.isEmpty else { return kubeFail("No context given") }
        let env = kubeconfigEnv(kubeconfigPaths)
        let view = await execKubectl(["config", "view", "-o", "json"], env: env)
        if !view.ok { return kubeFail(kubeOr(kubePlain(view.stderr), "kubectl config view failed")) }
        guard let data = try? JSON.parse(view.stdout) else { return kubeFail("Could not read the kubeconfig as JSON") }
        guard let ctx = data["contexts"].items.first(where: { $0["name"].string == contextName }) else {
            return kubeFail("No context \"\(contextName)\" in the kubeconfig")
        }
        let others = data["contexts"].items.filter { $0["name"].string != contextName }
        let cu = ctx["context"]["user"].kStr, cc = ctx["context"]["cluster"].kStr
        let user: String? = !cu.isEmpty && !others.contains { $0["context"]["user"].string == cu } ? cu : nil
        let cluster: String? = !cc.isEmpty && !others.contains { $0["context"]["cluster"].string == cc } ? cc : nil
        let wasCurrent = data["current-context"].string == contextName
        var plan: [String: JSON] = ["context": .string(contextName), "user": JSON(user), "cluster": JSON(cluster), "wasCurrent": .bool(wasCurrent)]
        if dryRun { return kubeOk(plan) }
        let del = await execKubectl(["config", "delete-context", contextName], env: env)
        if !del.ok { return kubeFail(kubeOr(kubePlain(del.stderr), "kubectl config delete-context failed")) }
        var warnings: [String] = []
        if let user {
            let r = await execKubectl(["config", "delete-user", user], env: env)
            if !r.ok { warnings.append(kubeOr(kubePlain(r.stderr), "Could not remove user \(user)")) }
        }
        if let cluster {
            let r = await execKubectl(["config", "delete-cluster", cluster], env: env)
            if !r.ok { warnings.append(kubeOr(kubePlain(r.stderr), "Could not remove cluster \(cluster)")) }
        }
        if wasCurrent { _ = await execKubectl(["config", "unset", "current-context"], env: env) }
        plan["warnings"] = JSON(warnings)
        return kubeOk(plan)
    }

    /// Rename a context and/or set its default namespace (`namespace` nil = leave it).
    static func editContext(contextName: String?, kubeconfigPaths: [String] = [], newName: String? = nil, namespace: String? = nil) async -> JSON {
        guard let contextName, !contextName.isEmpty else { return kubeFail("No context given") }
        let env = kubeconfigEnv(kubeconfigPaths)
        if let namespace {
            let r = await execKubectl(["config", "set-context", contextName, "--namespace=" + namespace.trimmed], env: env)
            if !r.ok { return kubeFail(kubeOr(kubePlain(r.stderr), "kubectl config set-context failed")) }
        }
        let name = (newName ?? "").trimmed
        if !name.isEmpty && name != contextName {
            let r = await execKubectl(["config", "rename-context", contextName, name], env: env)
            if !r.ok { return kubeFail(kubeOr(kubePlain(r.stderr), "kubectl config rename-context failed")) }
        }
        return kubeOk()
    }

    // MARK: - kubectl for a spec

    /// `{bin, baseArgs, env}` for one spec: the single place that branches
    /// between a direct and a Teleport context, and that sets KUBECONFIG.
    static func kubectlArgsFor(_ spec: KubeSpec) -> (bin: String, baseArgs: [String], env: [String: String?]) {
        let env = kubeconfigEnv(spec.kubeconfigPaths)
        let c = kubectlCommand()
        var args = c.prefix
        if let ctx = spec.contextName, !ctx.isEmpty { args.append("--context=" + ctx) }
        if let ns = spec.namespace, !ns.isEmpty { args += ["-n", ns] }
        return (c.bin, args, env)
    }

    static func kubeconfigEnvFor(_ spec: KubeSpec) -> [String: String?] { kubectlArgsFor(spec).env }

    /// Namespaces in one context — `kubectl get namespaces -o json`.
    static func listNamespaces(_ spec: KubeSpec) async -> JSON {
        let k = kubectlArgsFor(spec.with(namespace: nil))
        let r = await execBin(k.bin, k.baseArgs + ["get", "namespaces", "-o", "json"], env: k.env, timeout: 15)
        if !r.ok { return kubeFail(kubeOr(kubePlain(r.stderr), "kubectl get namespaces failed"), ["namespaces": []]) }
        guard let data = try? JSON.parse(r.stdout) else { return kubeFail("Unexpected output from kubectl", ["namespaces": []]) }
        let names = data["items"].items.compactMap { $0["metadata"]["name"].string?.nilIfEmpty }
        return kubeOk(["namespaces": JSON(names)])
    }

    /// Pods in one namespace (or every namespace) of one context — `kubectl get pods -o json`.
    static func listPods(_ spec: KubeSpec) async -> JSON {
        let ns = spec.namespace?.nilIfEmpty
        let k = kubectlArgsFor(spec.scoped(namespace: ns))
        let scope = ns != nil ? [] : ["-A"]
        let r = await execBin(k.bin, k.baseArgs + ["get", "pods"] + scope + ["-o", "json"], env: k.env, timeout: 15)
        if !r.ok { return kubeFail(kubeOr(kubePlain(r.stderr), "kubectl get pods failed"), ["pods": []]) }
        guard let data = try? JSON.parse(r.stdout) else { return kubeFail("Unexpected output from kubectl", ["pods": []]) }
        let pods: [JSON] = data["items"].items.map { i in
            let cs = i["status"]["containerStatuses"].items
            return [
                "name": .string(i["metadata"]["name"].kStr),
                "namespace": .string(kubeOr(i["metadata"]["namespace"].string, ns ?? "")),
                "phase": .string(kubeOr(i["status"]["phase"].string, "Unknown")),
                "ready": JSON(cs.filter { $0["ready"].truthy }.count),
                "total": JSON(cs.count),
                "restarts": .number(cs.reduce(0) { $0 + $1["restartCount"].kNum }),
                "containers": JSON(i["spec"]["containers"].items.map { $0["name"].kStr }),
                "node": .string(i["spec"]["nodeName"].kStr),
                "labels": i["metadata"]["labels"].object.map(JSON.object) ?? [:],
            ]
        }
        return kubeOk(["pods": .array(pods)])
    }

    /// `kubectl exec -it <pod> [-c c] -- <shell>` for a terminal pane.
    static func execSpec(_ spec: KubeSpec) -> KubeCommandSpec {
        let k = kubectlArgsFor(spec)
        var args = k.baseArgs + ["exec", "-it", spec.podName ?? ""]
        if let c = spec.containerName, !c.isEmpty { args += ["-c", c] }
        args += ["--", kubeOr(spec.shell, "/bin/sh")]
        return KubeCommandSpec(command: k.bin, args: args, env: k.env)
    }

    /// One non-interactive command in a pod: `kubectl exec <pod> -- sh -c <command>`.
    static func execRun(_ spec: KubeSpec, _ command: String?, timeout: TimeInterval = 20) async -> JSON {
        guard let pod = spec.podName, !pod.isEmpty else { return ["ok": false, "error": "No pod given", "stdout": "", "stderr": ""] }
        let cmd = (command ?? "").trimmed
        if cmd.isEmpty { return ["ok": false, "error": "No command given", "stdout": "", "stderr": ""] }
        let k = kubectlArgsFor(spec)
        var args = k.baseArgs + ["exec", pod]
        if let c = spec.containerName, !c.isEmpty { args += ["-c", c] }
        args += ["--", "sh", "-c", cmd]
        let r = await execBin(k.bin, args, env: k.env, timeout: timeout)
        let error: JSON = r.ok ? .null : .string(kubeOr(kubeOr(kubePlain(r.stderr), r.errMessage ?? ""), "kubectl exec failed"))
        return ["ok": .bool(r.ok), "stdout": .string(r.stdout), "stderr": .string(r.stderr), "error": error]
    }

    /// `kubectl attach <pod> [-c c] -i` — deliberately `-i` and not `-it`:
    /// the pane is the terminal, and a tty request on a container started
    /// without one fails.
    static func attachSpec(_ spec: KubeSpec) -> KubeCommandSpec {
        let k = kubectlArgsFor(spec)
        var args = k.baseArgs + ["attach", spec.podName ?? ""]
        if let c = spec.containerName, !c.isEmpty { args += ["-c", c] }
        args.append("-i")
        return KubeCommandSpec(command: k.bin, args: args, env: k.env)
    }

    /// An ephemeral debug container beside the pod's own.
    static func debugSpec(_ spec: KubeSpec) throws -> KubeCommandSpec {
        guard let pod = spec.podName, !pod.isEmpty else { throw AppError("No pod to debug.") }
        guard let image = spec.image, !image.isEmpty else { throw AppError("No debug image given.") }
        let k = kubectlArgsFor(spec)
        var args = k.baseArgs + ["debug", "-it", pod, "--image=" + image]
        if let c = spec.containerName, !c.isEmpty { args.append("--target=" + c) }
        args += ["--", kubeOr(spec.shell, "/bin/sh")]
        return KubeCommandSpec(command: k.bin, args: args, env: k.env)
    }

    /// A debugging pod on a node: `kubectl debug node/<name> -it --image=…`.
    static func nodeDebugSpec(_ spec: KubeSpec) throws -> KubeCommandSpec {
        guard let node = spec.nodeName, !node.isEmpty else { throw AppError("No node to debug.") }
        guard let image = spec.image, !image.isEmpty else { throw AppError("No debug image given.") }
        let k = kubectlArgsFor(spec)
        let args = k.baseArgs + ["debug", "node/" + node, "-it", "--image=" + image, "--", kubeOr(spec.shell, "/bin/sh")]
        return KubeCommandSpec(command: k.bin, args: args, env: k.env)
    }

    /// `kubectl logs` for a pod (or every pod matching a selector).
    static func logArgs(_ spec: KubeSpec, follow: Bool = true, previous: Bool = false, tail: Int? = 200,
                        allContainers: Bool = false) throws -> (bin: String, args: [String], env: [String: String?]) {
        let pod = spec.podName?.nilIfEmpty, selector = spec.selector?.nilIfEmpty
        if pod == nil && selector == nil { throw AppError("No pod or label selector to read logs from.") }
        if pod != nil && selector != nil { throw AppError("A pod name and a label selector cannot both be given.") }
        let k = kubectlArgsFor(spec)
        var args = k.baseArgs + ["logs"]
        if let selector {
            args += ["-l", selector, "--all-containers=true", "--prefix"]
        } else if let pod {
            args.append(pod)
            if let c = spec.containerName, !c.isEmpty { args += ["-c", c] }
            if allContainers { args += ["--all-containers=true", "--prefix"] }
        }
        if follow { args.append("-f") }
        if previous { args.append("-p") }
        if let tail { args.append("--tail=\(tail)") }
        args.append("--timestamps")
        return (k.bin, args, k.env)
    }

    static func logSpec(_ spec: KubeSpec, follow: Bool = true, previous: Bool = false, tail: Int? = 200,
                        allContainers: Bool = false) throws -> KubeCommandSpec {
        let a = try logArgs(spec, follow: follow, previous: previous, tail: tail, allContainers: allContainers)
        return KubeCommandSpec(command: a.bin, args: a.args, env: a.env)
    }

    // MARK: - helm and the Teleport agent

    /// One argv word, quoted for a POSIX shell only where it has to be — so the preview reads like a command someone would type.
    static func shellQuote(_ word: String) -> String {
        TPText.test(#"^[A-Za-z0-9_@%+=:,./-]+$"#, word) ? word : "'" + word.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// The exact helm commands, as text someone could paste.
    static func commandPreview(_ steps: [(args: [String], stdin: String?)], env: [String: String?] = [:]) -> String {
        let kc = (env["KUBECONFIG"] ?? nil) ?? ""
        let prefix = kc.isEmpty ? "" : "KUBECONFIG=\(shellQuote(kc)) "
        return steps.map { step in
            let cmd = prefix + (["helm"] + step.args).map(shellQuote).joined(separator: " ")
            guard let stdin = step.stdin, !stdin.isEmpty else { return cmd }
            let body = stdin.hasSuffix("\n") ? stdin : stdin + "\n"
            return "\(cmd) <<'VALUES'\n\(body)VALUES"
        }.joined(separator: "\n")
    }

    /// helm's context flag is `--kube-context=`, not kubectl's `--context=`.
    static func helmArgsFor(_ spec: KubeSpec) -> (env: [String: String?], contextArgs: [String]) {
        let k = kubectlArgsFor(spec)
        let ctx = k.baseArgs.filter { $0.hasPrefix("--context=") }.map { "--kube-context=" + $0.dropFirst("--context=".count) }
        return (k.env, ctx)
    }

    /// The agent's services: kube always makes sense here; app and discovery find and publish what runs in the cluster.
    static let agentRoles = ["kube", "app", "discovery"]

    /// The values.yaml for teleport-kube-agent.
    static func teleportAgentValues(proxy: String?, token: String?, clusterName: String?, roles: [String] = ["kube"],
                                    labels: [String: String] = [:], releaseName: String = "teleport-agent",
                                    namespace: String = "teleport-agent", header: Bool = true, autoUpdate: Bool = true) -> String {
        let picked = agentRoles.filter { roles.contains($0) }
        let rolesText = picked.isEmpty ? "kube" : picked.joined(separator: ",")
        var values: [(String, YAMLValue)] = [
            ("roles", .string(rolesText)),
            ("proxyAddr", .string(kubeOr(proxy, "<proxy-address:443>"))),
            ("authToken", .string(kubeOr(token, "<join-token>"))),
            ("kubeClusterName", .string(kubeOr(clusterName, "<cluster-name>"))),
        ]
        let clean = labels.filter { !$0.key.isEmpty }.sorted { $0.key < $1.key }
        if !clean.isEmpty { values.append(("labels", .map(clean.map { ($0.key, .string($0.value)) }))) }
        if autoUpdate { values.append(("updater", .map([("enabled", .bool(true))]))) }
        let body = KubeYAML.dump(.map(values))
        if !header { return body }
        var head = [
            "# teleport-kube-agent values — written by ServerLife",
            "#",
            "#   helm repo add teleport https://charts.releases.teleport.dev && helm repo update teleport",
            "#   helm install \(releaseName) teleport/teleport-kube-agent --create-namespace --namespace \(namespace) -f values.yaml",
        ]
        if (token ?? "").isEmpty {
            head += ["#", "# authToken is a placeholder. Make one (valid 1h) with:", "#   tctl tokens add --type=\(rolesText) --ttl=1h"]
        } else {
            head += ["#", "# authToken is a real join token: treat this file as a secret until it expires."]
        }
        return head.joined(separator: "\n") + "\n\n" + body
    }

    static let dnsLabel = #"^[a-z0-9]([-a-z0-9]{0,61}[a-z0-9])?$"#

    /// helm-install teleport-kube-agent into the cluster `spec` points at (or only preview the commands).
    static func installTeleportAgent(_ spec: KubeSpec, proxy: String?, token: String?, clusterName: String?,
                                     dryRun: Bool = false, preview: Bool = false, roles: [String] = ["kube"],
                                     labels: [String: String] = [:], releaseName: String = "teleport-agent",
                                     namespace: String = "teleport-agent", autoUpdate: Bool = true) async -> JSON {
        guard let proxy, !proxy.isEmpty, let token, !token.isEmpty, let clusterName, !clusterName.isEmpty else {
            return kubeFail("Missing proxy, token or cluster name.")
        }
        if !TPText.test(dnsLabel, releaseName) {
            return kubeFail("\"\(releaseName)\" is not a valid release name — lowercase letters, digits and \"-\", up to 63.")
        }
        if !TPText.test(dnsLabel, namespace) {
            return kubeFail("\"\(namespace)\" is not a valid namespace — lowercase letters, digits and \"-\", up to 63.")
        }
        let picked = agentRoles.filter { roles.contains($0) }
        if picked.isEmpty { return kubeFail("Pick at least one role.") }
        let h = helmArgsFor(spec)
        let valuesYaml = teleportAgentValues(proxy: proxy, token: token, clusterName: clusterName, roles: picked,
                                             labels: labels, header: false, autoUpdate: autoUpdate)
        let installArgs = ["install", releaseName, "teleport/teleport-kube-agent"] + h.contextArgs
            + ["--create-namespace", "--namespace", namespace, "-f", "-"] + (dryRun ? ["--dry-run"] : [])
        if preview {
            return kubeOk(["command": .string(commandPreview([
                (["repo", "add", "teleport", "https://charts.releases.teleport.dev"], nil),
                (["repo", "update", "teleport"], nil),
                (installArgs, valuesYaml),
            ], env: h.env))])
        }
        if !KubeBin.toolAvailable("helm") {
            return kubeFail("helm was not found on this machine. Install it first (e.g. \"brew install helm\"), then try again.")
        }
        let helm = KubeBin.findTool("helm")
        let addRepo = await KubeBin.run(helm, ["repo", "add", "teleport", "https://charts.releases.teleport.dev"], env: h.env, timeout: 20, explain: false)
        if !addRepo.ok && !TPText.test("already exists", addRepo.stderr, .caseInsensitive) {
            return kubeFail(kubeOr(kubePlain(addRepo.stderr), "helm repo add failed"))
        }
        _ = await KubeBin.run(helm, ["repo", "update", "teleport"], env: h.env, timeout: 30, explain: false)
        let r = await KubeBin.run(helm, installArgs, env: h.env, timeout: 90, stdin: valuesYaml, explain: false)
        return r.ok ? kubeOk(["output": .string(kubePlain(r.stdout))]) : kubeFail(kubeOr(kubePlain(r.stderr), "helm install failed"))
    }
}
