import AppKit
import Foundation
import Observation

/// A blank in a macro's command: `{{name}}`, with a default and maybe a list.
struct MacroVar: Equatable {
    var name: String
    var choices: [String]?
    var defaultValue: String
    /// Where to suggest values from ("proxy" | "user") — a free field with
    /// suggestions, unlike `choices`.
    var suggest: String?

    var json: JSON {
        var o: [String: JSON] = ["name": .string(name), "choices": choices.map { JSON($0) } ?? .null,
                                 "default": .string(defaultValue)]
        if let suggest { o["suggest"] = .string(suggest) }
        return .object(o)
    }

    init(name: String, choices: [String]? = nil, defaultValue: String = "", suggest: String? = nil) {
        self.name = name; self.choices = choices; self.defaultValue = defaultValue; self.suggest = suggest
    }

    init?(json j: JSON) {
        guard let n = j["name"].stringish else { return nil }
        name = n
        choices = j["choices"].array.map { $0.compactMap(\.stringish) }
        defaultValue = j["default"].stringish ?? ""
        suggest = j["suggest"].string
    }
}

/// A macro: a command aimed at a job on a host (macros.js). Built-ins live in
/// code; the user's own are store records.
struct Macro: Identifiable, Equatable {
    var id: String
    var name: String
    var description = ""
    var category = "Custom"
    var command = ""
    /// "all" | "hosts" | "beams" | "local" | "kube", or nil for a record saved before scopes.
    var whereScope: String?
    var confirm = false
    /// What running it costs, said in the confirm instead of "Run this on the target host?".
    var warning: String?
    var interactive = false
    var noEnter = false
    /// Declared blanks; nil when the record has none (then `variableSpec` is read).
    var variables: [MacroVar]?
    var variableSpec = ""
    var repeatSeconds = 0
    var builtin = false
    var useCount = 0
    var lastUsed: Double?

    init(id: String, category: String, name: String, description: String, command: String,
         interactive: Bool = false, noEnter: Bool = false, confirm: Bool = false, where w: String? = nil,
         variables: [MacroVar]? = nil, warning: String? = nil) {
        self.id = id; self.category = category; self.name = name; self.description = description
        self.command = command; self.interactive = interactive; self.noEnter = noEnter; self.confirm = confirm
        self.whereScope = w; self.variables = variables; self.warning = warning
    }

    init(json j: JSON, builtin: Bool = false) {
        id = j["id"].stringish ?? ""
        name = j["name"].stringish ?? ""
        description = j["description"].stringish ?? ""
        category = j["category"].stringish ?? "Custom"
        command = j["command"].stringish ?? ""
        whereScope = j["where"].string
        confirm = j["confirm"].truthy
        warning = j["warning"].string?.nilIfEmpty
        interactive = j["interactive"].truthy
        noEnter = j["noEnter"].truthy
        variables = j["variables"].array.map { $0.compactMap(MacroVar.init(json:)) }
        variableSpec = j["variableSpec"].stringish ?? ""
        repeatSeconds = Int(j["repeatSeconds"].double ?? 0)
        self.builtin = builtin
        useCount = j["useCount"].int ?? 0
        lastUsed = j["lastUsed"].double
    }

    /// What the editor saves (`macros:save`'s argument).
    var json: JSON {
        var o: [String: JSON] = [
            "name": .string(name), "description": .string(description), "category": .string(category),
            "command": .string(command), "confirm": .bool(confirm), "interactive": .bool(interactive),
            "noEnter": .bool(noEnter), "variableSpec": .string(variableSpec),
            "variables": .array((variables ?? []).map(\.json)), "repeatSeconds": .number(Double(repeatSeconds)),
        ]
        if let whereScope { o["where"] = .string(whereScope) }
        if let warning { o["warning"] = .string(warning) }
        if !builtin && !id.isEmpty { o["id"] = .string(id) }
        return .object(o)
    }
}

/// A macro ticking on a pane.
struct MacroRepeat: Identifiable {
    var macro: Macro
    var paneId: String
    var every: Int
    var since: Double
    var runs: Int
    var id: String { Macros.repeatKey(paneId, macro.id) }
}

/// Macros: commands you run *on a host*, rather than text you paste.
///
/// Snippets already send text into a terminal. A macro is the same idea aimed
/// at a specific job — "is the agent running", "what is filling the disk" — so
/// it ships with a starter set, carries a description of what it answers, and
/// can be run without a terminal open by showing its output in a dialog.
///
/// The built-ins live here rather than being seeded into the store, so they
/// improve between releases instead of freezing at whatever shipped first.
@MainActor
@Observable
final class Macros {
    static let shared = Macros()

    // MARK: Built-ins

    static let builtins: [Macro] = {
        var list: [Macro] = [
            /* ---- Teleport ---- */
            Macro(id: "b:tp-status", category: "Teleport", name: "Teleport service status",
                  description: "Is the agent running, and since when.",
                  command: "sudo systemctl status teleport --no-pager || sudo service teleport status"),
            /*
             * Running is not the same as connected: the unit can be up for a week while
             * the agent has been failing to reach its proxy the whole time.
             */
            Macro(id: "b:tp-readyz", category: "Teleport", name: "Teleport agent health",
                  description: "Whether the agent is actually connected and ready, not just running. Newer agents only (the debug service).",
                  command: "sudo teleport debug readyz"),
            // Never useful headless: it does not end.
            Macro(id: "b:tp-journal", category: "Teleport", name: "Follow Teleport logs",
                  description: "Live agent log. Ctrl-C to stop.", command: "sudo journalctl -fu teleport", interactive: true),
            Macro(id: "b:tp-journal-recent", category: "Teleport", name: "Teleport errors, last hour",
                  description: "Recent agent problems without following the log.",
                  command: "sudo journalctl -u teleport --since \"1 hour ago\" -p warning --no-pager | tail -n 80"),
            // The next question when a node drops out of the cluster: can it get there?
            Macro(id: "b:tp-reach", category: "Teleport", name: "Can the agent reach its proxy?",
                  description: "Reads the proxy address from /etc/teleport.yaml and pings it: DNS, firewall and TLS in one go.",
                  command: "f=/etc/teleport.yaml; a=$(sudo awk '/^[[:space:]]*(proxy_server|auth_server):/ { print $2; exit } /^[[:space:]]*auth_servers:/ { getline; sub(/^[[:space:]]*-[[:space:]]*/, \"\"); print; exit }' $f | tr -d '\"'); echo \"configured: ${a:-nothing found in $f}\"; [ -n \"$a\" ] && curl -sS --max-time 5 \"https://$a/webapi/ping\" | head -c 600; echo"),
            /*
             * Certificates carry a validity window, so a clock that has drifted reads
             * as "not yet valid" or "expired" — one of the commoner reasons a join or a
             * login fails, and nothing else on the list points at it.
             */
            Macro(id: "b:tp-clock", category: "Teleport", name: "Clock sync",
                  description: "Is this host's clock synchronised? Drift breaks certificate checks.",
                  command: "timedatectl 2>/dev/null || date -u"),
            Macro(id: "b:tp-version", category: "Teleport", name: "Teleport version",
                  description: "Agent build on this host.", command: "teleport version; tsh version 2>/dev/null | head -1"),
            Macro(id: "b:tp-status-session", category: "Teleport", name: "Teleport session status",
                  description: "Who this host is logged in as: cluster, user, roles and how long the certificate lasts.",
                  command: "tsh status"),
            /*
             * The other side of the same question: not who the host is logged in as,
             * but what this session is — its id, the cluster and node it landed on,
             * and the address it came from. Only answers inside a Teleport SSH
             * session, which is where it is asked.
             */
            Macro(id: "b:tp-session-info", category: "Teleport", name: "Teleport ssh session status",
                  description: "This SSH session as Teleport sees it: session id, cluster, host UUID and where you connected from.",
                  command: "teleport status"),
            /*
             * The client commands, which run here rather than on a server.
             *
             * `tsh` is the thing on your own machine that talks to the cluster, so
             * these are marked for the local shell: `tsh ssh` typed into a session you
             * reached *with* `tsh ssh` is not the thing anyone means.
             */
            Macro(id: "b:tsh-ls", category: "Teleport", name: "tsh ls",
                  description: "Every node the current cluster will let you see, with its labels.",
                  command: "tsh ls", where: "local"),
            // The point is to finish the line yourself — the target is the part that
            // changes every time, and it is not worth a variable prompt to type it.
            Macro(id: "b:tsh-ssh", category: "Teleport", name: "tsh ssh…",
                  description: "Pasted at the prompt without Enter, to finish by hand: add `user@node`, "
                      + "then Enter. `tsh ssh --cluster=leaf user@node` for a leaf.",
                  command: "tsh ssh ", noEnter: true, where: "local"),
            Macro(id: "b:tsh-scp", category: "Teleport", name: "tsh scp…",
                  description: "Pasted without Enter, to finish by hand: `./file user@node:/tmp/`, "
                      + "or `-r` for a directory. Either side can be the remote one.",
                  command: "tsh scp ", noEnter: true, where: "local"),
            /*
             * Headless auth has no persisted profile to fall back on — the whole
             * point is a one-off login approved from a second device — so `--proxy`
             * and `--user` are never optional the way they are for an ordinary `tsh
             * ssh` with a profile already active. Both are asked for explicitly
             * rather than guessed at. Not a fixed `choices` list (a bare dropdown
             * would refuse a proxy or user not already logged in from this machine) —
             * suggested from profiles already logged into here, but still freely typed.
             */
            Macro(id: "b:tsh-headless-ssh", category: "Teleport", name: "Headless SSH\u{2026}",
                  description: "tsh ssh with no local session \u{2014} approved from another device (tsh running there, or the web UI). For a CI box or a terminal with no browser of its own.",
                  command: "tsh ssh --headless --proxy={{proxy}} --user={{user}} {{host}}", where: "local",
                  variables: [MacroVar(name: "proxy", suggest: "proxy"), MacroVar(name: "user", suggest: "user"), MacroVar(name: "host")]),
            Macro(id: "b:tsh-headless-kube", category: "Teleport", name: "Headless kubectl\u{2026}",
                  description: "Same headless login, for a Kubernetes cluster: approves from another device, then points kubectl at it.",
                  command: "tsh kube login --headless --proxy={{proxy}} --user={{user}} {{kubeCluster}} && kubectl get pods", where: "local",
                  variables: [MacroVar(name: "proxy", suggest: "proxy"), MacroVar(name: "user", suggest: "user"), MacroVar(name: "kubeCluster")]),
            Macro(id: "b:tp-config", category: "Teleport", name: "Teleport config",
                  description: "The agent\u{2019}s teleport.yaml.", command: "sudo cat /etc/teleport.yaml"),
            Macro(id: "b:tp-restart", category: "Teleport", name: "Restart Teleport",
                  description: "Restarts the agent \u{2014} drops this host\u{2019}s tunnel briefly.",
                  command: "sudo systemctl restart teleport && sleep 2 && sudo systemctl status teleport --no-pager",
                  confirm: true),

            /*
             * ---- Kubernetes ----
             *
             * Only offered inside a kube exec session (macroKindOf reads the pane's
             * kubeExec mark), and nothing else gets these: `kubectl` run from inside
             * the container it would be managing is not a thing anyone means, and a
             * container this minimal usually has no `kubectl` to run anyway. Every
             * command here is plain POSIX sh with a fallback chain — many images
             * ship nothing but BusyBox, some ship nothing but the application
             * itself, and a macro that only works on Debian answers for little of
             * what KubeLife actually connects to.
             */
            Macro(id: "b:kube-identity", category: "Kubernetes", name: "Container identity",
                  description: "Hostname, OS, and architecture \u{2014} what this container actually is.",
                  command: "hostname; echo; cat /etc/os-release 2>/dev/null || cat /etc/alpine-release 2>/dev/null || uname -a", where: "kube"),
            Macro(id: "b:kube-env", category: "Kubernetes", name: "Environment variables",
                  description: "Everything the pod spec, ConfigMaps and Secrets injected \u{2014} sorted.",
                  command: "env | sort", where: "kube"),
            Macro(id: "b:kube-serviceaccount", category: "Kubernetes", name: "Service account",
                  description: "Whether this pod can talk to the Kubernetes API as itself, and as whom.",
                  command: "d=/var/run/secrets/kubernetes.io/serviceaccount; if [ -f \"$d/token\" ]; then echo \"namespace: $(cat \"$d/namespace\" 2>/dev/null)\"; echo \"token: $(wc -c < \"$d/token\") bytes mounted\"; else echo \"No service account token mounted.\"; fi", where: "kube"),
            Macro(id: "b:kube-api-reach", category: "Kubernetes", name: "Can this pod reach the API server?",
                  description: "Hits https://kubernetes.default.svc/healthz \u{2014} DNS, network policy and RBAC all have to let this through.",
                  command: "curl -sS -k --max-time 5 https://kubernetes.default.svc/healthz 2>/dev/null || wget -q -O- --no-check-certificate --timeout=5 https://kubernetes.default.svc/healthz 2>/dev/null || echo \"no curl or wget in this image\"; echo", where: "kube"),
            Macro(id: "b:kube-dns", category: "Kubernetes", name: "Cluster DNS",
                  description: "Resolves kubernetes.default \u{2014} the first thing to doubt when a pod \"can't reach\" another service.",
                  command: "getent hosts kubernetes.default 2>/dev/null || nslookup kubernetes.default 2>/dev/null || echo \"no getent or nslookup; resolv.conf:\"; cat /etc/resolv.conf 2>/dev/null", where: "kube"),
            Macro(id: "b:kube-limits", category: "Kubernetes", name: "Resource limits, from inside",
                  description: "The memory and CPU limits this container actually sees \u{2014} cgroup v2 first, v1 fallback.",
                  command: "echo \"memory.max: $(cat /sys/fs/cgroup/memory.max 2>/dev/null || cat /sys/fs/cgroup/memory/memory.limit_in_bytes 2>/dev/null || echo unknown)\"; echo \"cpu.max: $(cat /sys/fs/cgroup/cpu.max 2>/dev/null || cat /sys/fs/cgroup/cpu/cpu.cfs_quota_us 2>/dev/null || echo unknown)\"", where: "kube"),
            Macro(id: "b:kube-mounts", category: "Kubernetes", name: "Mounted volumes",
                  description: "What is actually mounted \u{2014} ConfigMaps, Secrets, PVCs \u{2014} with the container-runtime plumbing filtered out.",
                  command: "mount 2>/dev/null | grep -Ev \"^(overlay|proc|tmpfs|shm|devpts|sysfs|cgroup|mqueue) \" ; echo; df -h 2>/dev/null", where: "kube"),
            Macro(id: "b:kube-listening", category: "Kubernetes", name: "Listening ports",
                  description: "What this container has bound, and on which interface.",
                  command: "ss -tulpn 2>/dev/null || netstat -tulpn 2>/dev/null || (echo \"no ss or netstat; /proc/net/tcp:\"; cat /proc/net/tcp 2>/dev/null)", where: "kube"),

            /* ---- System ---- */
            // df is df everywhere, so this one is useful in the local shell too.
            Macro(id: "b:disk", category: "System", name: "Disk usage",
                  description: "Filesystems, and inodes when a disk is \"full\" but is not.",
                  command: "df -h; echo; df -i | head -n 20", where: "all"),
            Macro(id: "b:big-files", category: "System", name: "Largest directories in /var",
                  description: "What is filling the disk.",
                  command: "sudo du -xh /var --max-depth=2 2>/dev/null | sort -rh | head -n 20"),
            Macro(id: "b:memory", category: "System", name: "Memory and load",
                  description: "Free memory, swap, uptime and load average.", command: "free -h; echo; uptime"),
            Macro(id: "b:top-procs", category: "System", name: "Top processes",
                  description: "The heaviest processes by memory, then CPU.",
                  command: "ps aux --sort=-%mem | head -n 12; echo; ps aux --sort=-%cpu | head -n 12"),
            Macro(id: "b:listening", category: "System", name: "Listening ports",
                  description: "What is bound, and which process owns it.",
                  command: "sudo ss -tulpn 2>/dev/null || sudo netstat -tulpn"),
            Macro(id: "b:errors", category: "System", name: "Recent system errors",
                  description: "Priority error and above from the journal.",
                  command: "sudo journalctl -p err -n 60 --no-pager"),
            Macro(id: "b:who", category: "System", name: "Who is logged in",
                  description: "Current sessions and recent logins.", command: "who -a; echo; last -n 15"),
            // Already written to fall back to the BSD tools, so it answers on a Mac.
            Macro(id: "b:net", category: "System", name: "Network addresses and routes",
                  description: "Interfaces, addresses and the default route.",
                  command: "ip -brief address 2>/dev/null || ifconfig; echo; ip route 2>/dev/null || netstat -rn", where: "all"),
            Macro(id: "b:os", category: "System", name: "OS and kernel",
                  description: "Distribution, kernel and architecture.",
                  command: "cat /etc/os-release 2>/dev/null | head -n 5; echo; uname -a", where: "all"),
            Macro(id: "b:reboot", category: "System", name: "Pending reboot / updates",
                  description: "Whether the box is waiting on a restart.",
                  command: "[ -f /var/run/reboot-required ] && cat /var/run/reboot-required || echo \"no reboot required\"; "
                      + "echo; (sudo needs-restarting -r 2>/dev/null || true)"),

            /* ---- Beams ---- */
            /*
             * For a beam — Teleport's sandbox VM — and offered only in a beam's
             * session. A beam runs its long-lived processes under `beamctl`, its own
             * service manager, rather than systemd; it can publish one app, on port
             * 8080; it reaches the cluster's LLM gateways through environment it is
             * given; and it comes with examples in ~/examples. Everything here is
             * what the beam's own motd and ~/AGENTS.md point at.
             */
            Macro(id: "b:beam-services", category: "Beams", name: "Services (beamctl list)",
                  description: "The services beamctl is running in this beam, and their state.",
                  command: "beamctl list | grep . || echo \"(no services running under beamctl)\"", where: "beams"),
            Macro(id: "b:beam-service-show", category: "Beams", name: "Show a service",
                  description: "Everything beamctl knows about one service: its command, state and liveness.",
                  command: "beamctl show {{service}}", where: "beams"),
            Macro(id: "b:beam-service-logs", category: "Beams", name: "Service logs",
                  description: "What a service has printed so far.",
                  command: "beamctl logs {{service}} | tail -n 200", where: "beams"),
            Macro(id: "b:beam-service-follow", category: "Beams", name: "Follow service logs",
                  description: "A service\u{2019}s output as it happens. Ctrl-C to stop.",
                  command: "beamctl logs --follow {{service}}", interactive: true, where: "beams"),
            Macro(id: "b:beam-service-start", category: "Beams", name: "Start a service on 8080",
                  description: "Run a command under beamctl as a named service \u{2014} it keeps running after the session ends. 8080 is the port a beam can publish.",
                  command: "beamctl start --name {{service}} --liveness-port 8080 -- {{command}}", confirm: true, where: "beams",
                  variables: [MacroVar(name: "service", defaultValue: "app"), MacroVar(name: "command", defaultValue: "python3 -m http.server 8080")]),
            Macro(id: "b:beam-service-restart", category: "Beams", name: "Restart a service",
                  description: "Stop a service if it is running, and start it again.",
                  command: "beamctl restart {{service}}", confirm: true, where: "beams"),
            Macro(id: "b:beam-service-stop", category: "Beams", name: "Stop a service",
                  description: "Stop one of the beam\u{2019}s services.",
                  command: "beamctl stop {{service}}", confirm: true, where: "beams"),
            Macro(id: "b:beam-service-remove", category: "Beams", name: "Stop and remove a service",
                  description: "Stop it and take it off beamctl\u{2019}s list, so it is not there to restart.",
                  command: "beamctl stop --prune {{service}}", confirm: true, where: "beams"),
            /*
             * Freezing pauses every process in the service where it stands, without
             * stopping it: memory and open connections are kept, and thawing carries on
             * from the same instruction. Cheaper than a restart for "hold that a moment".
             */
            Macro(id: "b:beam-service-freeze", category: "Beams", name: "Freeze a service",
                  description: "Pause all of a service\u{2019}s processes where they are, without stopping it.",
                  command: "beamctl freeze {{service}}", confirm: true, where: "beams"),
            Macro(id: "b:beam-service-thaw", category: "Beams", name: "Thaw a service",
                  description: "Resume a frozen service from where it was paused.",
                  command: "beamctl thaw {{service}}", where: "beams"),
            Macro(id: "b:beam-service-attach", category: "Beams", name: "Attach to a service",
                  description: "Its terminal, live \u{2014} for a service started with --pty.",
                  command: "beamctl attach {{service}}", interactive: true, where: "beams"),
            Macro(id: "b:beam-service-wait", category: "Beams", name: "Wait for a service state",
                  description: "Return once a service reaches a state \u{2014} running after a start, stopped after a stop \u{2014} or give up after the timeout.",
                  command: "beamctl wait --state {{state}} --timeout {{seconds}} {{service}}", where: "beams",
                  variables: [MacroVar(name: "service", defaultValue: "app"), MacroVar(name: "state", choices: ["running", "stopped", "exited", "frozen", "stopping"], defaultValue: "running"), MacroVar(name: "seconds", defaultValue: "60")]),
            Macro(id: "b:beam-publish", category: "Beams", name: "Publish the app on 8080",
                  description: "Make what listens on port 8080 a Teleport app \u{2014} https://<name>.<cluster>. One app at a time.",
                  command: "tsh beams publish \"$BEAM_ALIAS\"", confirm: true, where: "beams"),
            Macro(id: "b:beam-publish-tcp", category: "Beams", name: "Publish port 8080 as TCP",
                  description: "The same, for a TCP service rather than HTTP.",
                  command: "tsh beams publish --tcp \"$BEAM_ALIAS\"", confirm: true, where: "beams"),
            Macro(id: "b:beam-unpublish", category: "Beams", name: "Unpublish the app",
                  description: "Take the published app down again; what listens on 8080 keeps running.",
                  command: "tsh beams unpublish \"$BEAM_ALIAS\"", confirm: true, where: "beams"),
            Macro(id: "b:beam-identity", category: "Beams", name: "Who this beam is",
                  description: "Its alias, id, cluster and Teleport identity.",
                  command: "echo \"beam:    $BEAM_ALIAS ($BEAM_ID)\"; echo \"cluster: $TELEPORT_CLUSTER\"; echo; tsh status", where: "beams"),
            Macro(id: "b:beam-resources", category: "Beams", name: "What it can reach",
                  description: "The apps, databases, GitHub orgs, SSH nodes and Kubernetes clusters this beam\u{2019}s identity is allowed.",
                  command: "echo \"== apps\"; tsh apps ls; echo; echo \"== databases\"; tsh db ls; echo; echo \"== GitHub orgs\"; tsh git ls 2>&1; echo; echo \"== SSH nodes\"; tsh ls; echo; echo \"== Kubernetes\"; tsh kube ls", where: "beams"),
            Macro(id: "b:beam-ai-env", category: "Beams", name: "AI gateway settings",
                  description: "The Anthropic and OpenAI addresses this beam is given \u{2014} the cluster\u{2019}s gateways, not the public APIs. Keys are hidden.",
                  command: "env | grep -E \"^(ANTHROPIC|OPENAI)_\" | sed -E \"s/^([A-Z_]*(KEY|TOKEN))=.*/\\1=<set>/\" | sort", where: "beams"),
            Macro(id: "b:beam-ai-hello", category: "Beams", name: "Try the AI gateway",
                  description: "Runs the beam\u{2019}s own hello-world against Anthropic, through the gateway.",
                  command: "cd ~/examples && sh anthropic_hello.sh", where: "beams"),
            Macro(id: "b:beam-examples", category: "Beams", name: "Examples and guide",
                  description: "What came with the beam: ~/AGENTS.md and the examples folder.",
                  command: "cat ~/AGENTS.md; echo; ls ~/examples", where: "beams"),
            /*
             * Inside a build beam — the console `tsh phase add` and `tsh phase edit`
             * open — where the beam's own tsh saves the image. Offered in every beam's
             * session; outside a build tsh says there is no build to save.
             */
            Macro(id: "b:beam-phase-add", category: "Beams", name: "Start a new Phase build",
                  description: "tsh phase add: a new Phase, built in a console on a new build beam \u{2014} install what it needs, then save and end the build.",
                  command: "tsh phase add {{name}}", confirm: true, where: "beams",
                  variables: [MacroVar(name: "name")],
                  warning: "This starts a new Phase build on the cluster: a build beam is created, and this terminal becomes its console until the build is saved and ended."),
            Macro(id: "b:beam-phase-snapshot", category: "Beams", name: "Save this build (Phase snapshot)",
                  description: "In a Phase build console: save the files so far to the Phase and keep working.",
                  command: "tsh phase snapshot", where: "beams"),
            Macro(id: "b:beam-phase-final", category: "Beams", name: "Save and end this build",
                  description: "In a Phase build console: save the snapshot and end the build. Changes after it are discarded.",
                  command: "tsh phase snapshot --final", confirm: true, where: "beams",
                  warning: "This saves the snapshot and ends the build: the build console closes, and anything changed after this snapshot is discarded."),
            Macro(id: "b:beam-phase-fork", category: "Beams", name: "Fork this build into a new Phase",
                  description: "In a Phase build console: start a new Phase from this build beam\u{2019}s files as they are now.",
                  command: "tsh phase add {{name}} --fork", confirm: true, where: "beams",
                  variables: [MacroVar(name: "name")],
                  warning: "This creates a new Phase on the cluster from this build beam\u{2019}s files as they are now."),
            Macro(id: "b:beam-version", category: "Beams", name: "beamctl version",
                  description: "The beam\u{2019}s service manager and init, and the image it runs.",
                  command: "beamctl version; echo; . /etc/os-release && echo \"$PRETTY_NAME\"", where: "beams"),
        ]
        /*
         * `where` is left off above and filled in here: every built-in is aimed at a
         * server — systemd, journalctl, `ss -tulpn`, /etc/teleport.yaml — and none of
         * them means anything typed into a Mac's own shell. The handful that fall
         * back to something portable say so for themselves.
         */
        for i in list.indices {
            list[i].builtin = true
            if list[i].whereScope == nil { list[i].whereScope = "hosts" }
        }
        return list
    }()

    // MARK: Loading

    /// Built-ins the user has not dismissed, plus their own, in the order
    /// they were dragged into (`loadMacros`).
    var all: [Macro] {
        let hidden = Set(FleetStore.hiddenMacros())
        return Macros.arranged(Macros.builtins.filter { !hidden.contains($0.id) } + FleetStore.savedMacros().map { Macro(json: $0) },
                               FleetStore.macroOrder())
    }

    /**
     * Macros in the order they were dragged into. One not yet placed keeps its
     * default position behind the placed ones, so a new macro or a new built-in
     * turns up at the end of its category rather than reshuffling it.
     */
    nonisolated static func arranged(_ macros: [Macro], _ order: [String]) -> [Macro] {
        var at: [String: Int] = [:]
        for (i, id) in order.enumerated() { at[id] = i }
        var ranked: [(m: Macro, rank: Int, i: Int)] = []
        for (i, m) in macros.enumerated() { ranked.append((m, at[m.id] ?? order.count + i, i)) }
        ranked.sort { (a, b) -> Bool in a.rank != b.rank ? a.rank < b.rank : a.i < b.i }
        return ranked.map { $0.m }
    }

    /**
     * Drop a macro before or after another, and remember it.
     *
     * Landing in another category moves it there: your own macro is saved with
     * the new category. A built-in's category is part of the shipped set, so it
     * only moves within its own.
     *
     * Like the category order, the saved order is rewritten from the whole list
     * as it now stands, so the first drag fixes everything where it already was.
     */
    @discardableResult
    func moveMacro(_ id: String, _ targetId: String, after: Bool = false) -> Bool {
        var list = all
        guard let from = list.firstIndex(where: { $0.id == id }), let target = list.first(where: { $0.id == targetId }),
              id != targetId else { return false }
        var moving = list[from]
        let category = target.category.nilIfEmpty ?? "Custom"
        if (moving.category.nilIfEmpty ?? "Custom") != category {
            if moving.builtin {
                StatusBus.shared.toast("A built-in macro stays in its own category \u{2014} drag it within that group", kind: .error)
                return false
            }
            moving.category = category
            _ = FleetStore.upsertMacro(moving.json)
        }
        list.remove(at: from)
        let to = (list.firstIndex { $0.id == targetId } ?? list.count) + (after ? 1 : 0)
        list.insert(moving, at: to)
        FleetStore.setMacroOrder(list.map(\.id))
        Macros.headersChanged()
        return true
    }

    var categoryOrder: [String] { FleetStore.macroCategoryOrder() }
    var pins: [JSON] { FleetStore.macroPins() }

    func macro(_ id: String) -> Macro? { all.first { $0.id == id } }

    // MARK: Scopes

    /// Where a pinned button is allowed to appear.
    static let pinScopes: [(value: String, label: String)] = [
        ("all", "Every session and the local shell"),
        ("hosts", "Host sessions only"),
        ("beams", "Beam sessions only"),
        ("local", "The local shell only"),
        ("kube", "Kubernetes exec sessions only"),
    ]

    /**
     * Where a macro can be run at all — a property of the macro, not of its
     * button. The same three words as the pin scopes, deliberately: one
     * vocabulary.
     */
    static let runScopes: [(value: String, label: String)] = [
        ("all", "Hosts and the local shell"),
        ("hosts", "Hosts only"),
        // A beam is a host too, so "hosts" macros run in one; these run nowhere else.
        ("beams", "Beams only"),
        ("local", "The local shell only"),
        // A kube exec session is 'local'-kind underneath (see macroKindOf) but
        // runs inside a container, not on this machine — kubectl/env/cgroup
        // checks belong here and nowhere else.
        ("kube", "Kubernetes exec sessions only"),
    ]

    static func scopeLabel(_ w: String?) -> String {
        (pinScopes.first { $0.value == (w?.nilIfEmpty ?? "hosts") } ?? pinScopes[1]).label
    }

    static func runScopeLabel(_ w: String?) -> String {
        let s = runScopeOf(w)
        return (runScopes.first { $0.value == s } ?? runScopes[0]).label
    }

    /// A macro's run scope, with the default for one that does not carry it:
    /// `all`, because a macro saved before this existed was offered everywhere.
    static func runScopeOf(_ w: String?) -> String {
        ["all", "hosts", "beams", "local", "kube"].contains(w ?? "") ? w! : "all"
    }

    /**
     * Does this macro belong in a pane of this kind? `kind` is "local",
     * "remote" (a host), "kube", or "beam" — a host that is also a beam, which
     * takes the host macros as well as its own.
     */
    nonisolated static func runsOn(_ m: Macro, _ kind: String = "remote") -> Bool {
        runsOn(where: m.whereScope, kind)
    }

    nonisolated static func runsOn(where ws: String?, _ kind: String = "remote") -> Bool {
        let w = ["all", "hosts", "beams", "local", "kube"].contains(ws ?? "") ? ws! : "all"
        if w == "all" { return true }
        if kind == "local" { return w == "local" }
        if kind == "kube" { return w == "kube" }
        if w == "beams" { return kind == "beam" }
        return w == "hosts"
    }

    /// The pin scopes shown for a pane of this kind.
    nonisolated static func pinScopesFor(_ kind: String) -> [String] {
        kind == "local" ? ["all", "local"]
            : kind == "kube" ? ["all", "kube"]
            : kind == "beam" ? ["all", "hosts", "beams"] : ["all", "hosts"]
    }

    /// The macros that can run in a pane of this kind, in the stored order.
    func macrosFor(_ kind: String = "remote", _ macros: [Macro]? = nil) -> [Macro] {
        (macros ?? all).filter { Macros.runsOn($0, kind) }
    }

    /// The pinned macros for one kind of pane, in button order. A pin whose
    /// macro is hidden or gone is not drawn (the pin stays, so restoring the
    /// macro brings its button back); nor is one where its macro would not run.
    func pinnedMacros(kind: String) -> [(macro: Macro, icon: String, where: String)] {
        let byId = Dictionary(all.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let wanted = Macros.pinScopesFor(kind)
        return pins.compactMap { p in
            let w = p["where"].string?.nilIfEmpty ?? "hosts"
            guard wanted.contains(w), let id = p["id"].string, let m = byId[id], Macros.runsOn(m, kind) else { return nil }
            return (m, p["icon"].string?.nilIfEmpty ?? "\u{25B6}", w)
        }
    }

    func isPinned(_ id: String) -> Bool { pins.contains { $0["id"].string == id } }

    /// The icon a macro is pinned with, or "" when it is not pinned at all.
    func pinnedIconFor(_ id: String) -> String {
        guard let p = pins.first(where: { $0["id"].string == id }) else { return "" }
        return p["icon"].string?.nilIfEmpty ?? "\u{25B6}"
    }

    /// Where a macro's button is shown, or "" when it is not pinned.
    func pinnedScopeFor(_ id: String) -> String {
        guard let p = pins.first(where: { $0["id"].string == id }) else { return "" }
        return p["where"].string?.nilIfEmpty ?? "hosts"
    }

    func setPinned(_ id: String, pinned: Bool = true, icon: String = "", where w: String? = nil) {
        FleetStore.setMacroPin(id, pinned: pinned, icon: icon, where: w)
        Macros.headersChanged()
    }

    /// Pinning a macro adds its button to every session already open.
    static func headersChanged() { PaneHeaderItems.shared.revision += 1 }

    // MARK: Categories

    /**
     * Categories in the order the user has arranged them. Anything not yet
     * placed falls in behind what is — Teleport first, then alphabetically —
     * which means a new category appears somewhere sensible without the saved
     * order having to know about it.
     */
    func categories(_ macros: [Macro]) -> [(String, [Macro])] {
        var byCat: [(String, [Macro])] = []
        for m in macros {
            let key = m.category.nilIfEmpty ?? "Custom"
            if let i = byCat.firstIndex(where: { $0.0 == key }) { byCat[i].1.append(m) } else { byCat.append((key, [m])) }
        }
        let order = categoryOrder
        func rank(_ k: String) -> Int {
            if let i = order.firstIndex(of: k) { return i }
            return order.count + (k == "Teleport" ? 0 : k == "Custom" ? 2 : 1)
        }
        return byCat.enumerated().sorted { a, b in
            let ra = rank(a.element.0), rb = rank(b.element.0)
            if ra != rb { return ra < rb }
            let c = a.element.0.localizedCompare(b.element.0)
            if c != .orderedSame { return c == .orderedAscending }
            return a.offset < b.offset
        }.map(\.element)
    }

    /// Move a category one place up or down and remember it. The saved order
    /// is rewritten from what is on screen, so the first move on an untouched
    /// list pins every category where it already appeared.
    @discardableResult
    func moveCategory(_ name: String, _ delta: Int) -> Bool {
        var current = categories(all).map(\.0)
        guard let from = current.firstIndex(of: name) else { return false }
        let to = from + delta
        guard to >= 0, to < current.count else { return false }
        current.insert(current.remove(at: from), at: to)
        FleetStore.setMacroCategoryOrder(current)
        return true
    }

    // MARK: Variables

    /// `{{ name }}` in a command.
    nonisolated static let varRe = try! NSRegularExpression(pattern: "\\{\\{\\s*([A-Za-z0-9_.-]+)\\s*\\}\\}")
    nonisolated static let varNameRe = try! NSRegularExpression(pattern: "^[A-Za-z0-9_.-]+$")

    /**
     * The declaration block, one variable per line:
     *
     *   service = teleport
     *   level = info | warn | error
     *   lines =
     *
     * An `=` with nothing after it means "no default, ask me". A `|` list is a
     * choice; the first is the default unless one is marked with `*`.
     */
    nonisolated static func parseVarSpec(_ text: String?) -> [MacroVar] {
        var out: [MacroVar] = []
        for raw in (text ?? "").components(separatedBy: "\n") {
            let line = raw.replacingOccurrences(of: "\r", with: "").trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            let eq = line.firstIndex(of: "=")
            let name = (eq.map { String(line[..<$0]) } ?? line).trimmingCharacters(in: .whitespaces)
            guard varNameRe.matches(name) else { continue }
            let rest = eq.map { String(line[line.index(after: $0)...]).trimmingCharacters(in: .whitespaces) } ?? ""
            if rest.contains("|") {
                let parts = rest.components(separatedBy: "|").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
                // A starred entry is the default; otherwise the first one is.
                let starred = parts.first { $0.hasPrefix("*") }
                let unstar: (String) -> String = { s in
                    (s.hasPrefix("*") ? String(s.dropFirst()) : s).trimmingCharacters(in: .whitespaces)
                }
                out.append(MacroVar(name: name, choices: parts.map(unstar), defaultValue: unstar(starred ?? parts.first ?? "")))
            } else {
                out.append(MacroVar(name: name, choices: nil, defaultValue: rest))
            }
        }
        return out
    }

    nonisolated static func renderVarSpec(_ vars: [MacroVar]?) -> String {
        (vars ?? []).map { v in
            if let c = v.choices, !c.isEmpty {
                return "\(v.name) = " + c.map { $0 == v.defaultValue ? "*" + $0 : $0 }.joined(separator: " | ")
            }
            return "\(v.name) = \(v.defaultValue)"
        }.joined(separator: "\n")
    }

    /// The `{{names}}` a command uses, in order of first use.
    nonisolated static func usedNames(_ command: String) -> [String] {
        let ns = command as NSString
        var out: [String] = []
        for m in varRe.matches(in: command, range: NSRange(location: 0, length: ns.length)) {
            let n = ns.substring(with: m.range(at: 1))
            if !out.contains(n) { out.append(n) }
        }
        return out
    }

    /**
     * Every variable this macro needs: the declared ones first, then any
     * `{{placeholder}}` in the command that was never declared — treated as a
     * variable with no default rather than left in the command as literal text.
     * A declared variable the command never mentions is not asked for.
     */
    nonisolated static func varsOf(command: String, variables: [MacroVar]?, variableSpec: String) -> [MacroVar] {
        let declared = variables ?? parseVarSpec(variableSpec)
        return usedNames(command).map { name in declared.first { $0.name == name } ?? MacroVar(name: name) }
    }

    static func varsOf(_ m: Macro) -> [MacroVar] {
        varsOf(command: m.command, variables: m.variables, variableSpec: m.variableSpec)
    }

    nonisolated static func expand(_ command: String, _ values: [String: String]) -> String {
        let ns = command as NSString
        var out = ""
        var last = 0
        for m in varRe.matches(in: command, range: NSRange(location: 0, length: ns.length)) {
            out += ns.substring(with: NSRange(location: last, length: m.range.location - last))
            let name = ns.substring(with: m.range(at: 1))
            out += values[name] ?? ns.substring(with: m.range)
            last = m.range.location + m.range.length
        }
        out += ns.substring(from: last)
        return out
    }

    /**
     * The macro as it will actually run. `ask` forces the dialog even when
     * every blank has a default — which is what the submenu entry is for.
     * Without it, a macro whose variables all have defaults runs on one click,
     * and one with a blank still asks, because there is nothing sensible to
     * put there.
     */
    func resolve(_ m: Macro, ask: Bool = false, window: WindowModel?) async -> Macro? {
        let vars = Macros.varsOf(m)
        if vars.isEmpty { return m }
        let needed = vars.contains { $0.defaultValue.isEmpty }
        var out = m
        if !ask && !needed {
            out.command = Macros.expand(m.command, Dictionary(vars.map { ($0.name, $0.defaultValue) }, uniquingKeysWith: { a, _ in a }))
            return out
        }
        guard let values = await MacroDialogs.askVars(m, vars, window: window) else { return nil }
        out.command = Macros.expand(m.command, values)
        return out
    }

    // MARK: Running

    private func allowed(_ m: Macro, window: WindowModel?) async -> Bool {
        if !m.confirm { return true }
        // What running it costs, where the macro says: "Run this?" is no warning
        // for a command that ends a build and discards its changes.
        return await MiscUI.confirm(window, title: m.name, message: m.warning ?? "Run this on the target host?", detail: m.command,
                                    confirmLabel: "Run", danger: true)
    }

    func markUsed(_ m: Macro) {
        if !m.builtin { FleetStore.markMacroUsed(m.id) }
    }

    /**
     * The kind of pane, as macros see it: "local", "beam", "kube" or "remote"
     * (`macroKindOf`). A console or a tmux pane takes the same commands a host
     * does. A kube exec pane is local-kind underneath (kubectl runs the way a
     * local shell runs a program, with no connection behind it) but has its
     * own macro set, not a local shell's: kube-ui marks it with
     * `attachments["kubeExec"]`.
     */
    static func paneKind(_ p: SessionPane) -> String {
        if p.attachments["kubeExec"] != nil { return "kube" }
        if p.kind == .local { return "local" }
        if let id = p.connId, ConnectionManager.shared.connection(id)?.type == "beam" { return "beam" }
        return "remote"
    }

    /// "the local shell", "a beam session", "a host session" — what the wrong pane is.
    static func kindPhrase(_ kind: String) -> String {
        ["local": "the local shell", "beam": "a beam session"][kind] ?? "a host session"
    }

    private func sessions(_ window: WindowModel?) -> SessionsWindow? {
        (window ?? WindowManager.shared.focused)?.feature(SessionsWindow.self)
    }

    /// Type it into the focused terminal (or every remote pane in the tab) —
    /// the default, and the only way to follow a log.
    func send(_ mIn: Macro, all: Bool = false, window wIn: WindowModel?) async {
        let window = wIn ?? WindowManager.shared.focused
        guard let s = sessions(window) else { return }
        let targets: [SessionPane] = all
            ? s.panesOf(s.activeTabId).compactMap { s.pane($0) }.filter { $0.hasTerm && $0.kind == .remote }
            : [s.activePane].compactMap { $0 }.filter { $0.hasTerm }
        guard !targets.isEmpty else {
            StatusBus.shared.toast("Open a session first, or use \u{201C}Run and show output\u{201D}", kind: .error)
            return
        }
        /*
         * A macro can reach a pane it is not meant for — the sidebar's
         * double-click sends to whatever is focused, and the focused thing may be
         * the local shell. Asked rather than refused: the scope is a default
         * about where it belongs, not a lock.
         */
        let wrong = targets.filter { !Macros.runsOn(mIn, Macros.paneKind($0)) }
        if !wrong.isEmpty {
            let detail = wrong.count == targets.count
                ? "The focused pane is \(Macros.kindPhrase(Macros.paneKind(wrong[0])))."
                : "\(wrong.count) of \(targets.count) panes are not what it is set for."
            let ok = await MiscUI.confirm(window, title: "Run it here?",
                                          message: "\u{201C}\(mIn.name)\u{201D} is set to run in \(Macros.runScopeLabel(mIn.whereScope).lowercased()).",
                                          detail: detail, confirmLabel: "Run it anyway")
            if !ok { return }
        }
        guard let m = await resolve(mIn, window: window) else { return }
        guard await allowed(m, window: window) else { return }
        // A macro with an interval of its own starts ticking rather than running once.
        if m.repeatSeconds > 0 && !m.interactive && !m.noEnter {
            for p in targets { await startRepeat(m, seconds: m.repeatSeconds, paneId: p.id, window: window, askFirst: false) }
            return
        }
        // Normally the newline is the point — the macro runs. A macro marked
        // `noEnter` is one you mean to finish by hand, so it is left on the prompt.
        let text = m.noEnter ? Macros.trimTrailingNewlines(m.command) : Macros.trimTrailingNewlines(m.command) + "\n"
        for p in targets { Macros.sendText(text, to: p, window: window) }
        markUsed(m)
        let n = targets.count
        StatusBus.shared.show(m.noEnter
            ? "\(m.name) \u{2192} \(n) pane\(n == 1 ? "" : "s") \u{2014} press Enter to run"
            : "\(m.name) \u{2192} \(n) pane\(n == 1 ? "" : "s")")
    }

    nonisolated static func trimTrailingNewlines(_ s: String) -> String {
        var t = s
        while t.hasSuffix("\n") { t.removeLast() }
        return t
    }

    /// Into a pane's shell, exactly as typed (`sendToPane`).
    static func sendText(_ text: String, to p: SessionPane, window: WindowModel?) {
        Actions.shared.perform("send-text", window: p.owner?.window ?? window, paneId: p.id,
                               args: ["text": text, "enter": false])
    }

    // MARK: Repeating

    /**
     * Macros that finish can be put on a timer: watch a queue drain, keep an eye
     * on load, poll a service coming back up. Only commands that end are
     * eligible. A repeat belongs to a pane, not to the macro: the same macro
     * can tick on two hosts at once, and closing a pane takes its repeats with it.
     */
    private(set) var repeats: [String: MacroRepeat] = [:]
    @ObservationIgnored private var timers: [String: Timer] = [:]

    nonisolated static func repeatKey(_ paneId: String, _ macroId: String) -> String { "\(paneId):\(macroId)" }

    func repeatsOnPane(_ paneId: String) -> [MacroRepeat] {
        repeats.values.filter { $0.paneId == paneId }.sorted { $0.since < $1.since }
    }

    func isRepeating(_ paneId: String, _ macroId: String) -> Bool { repeats[Macros.repeatKey(paneId, macroId)] != nil }

    /// Seconds as a human would say them: 45s, 2m, 1h 30m.
    nonisolated static func fmtEvery(_ seconds: Double) -> String {
        let s = max(1, Int(seconds.rounded()))
        if s < 60 { return "\(s)s" }
        if s < 3600 { return s % 60 != 0 ? "\(s / 60)m \(s % 60)s" : "\(s / 60)m" }
        let h = s / 3600
        let m = Int((Double(s % 3600) / 60).rounded())
        return m != 0 ? "\(h)h \(m)m" : "\(h)h"
    }

    private func pane(_ id: String) -> SessionPane? { SessionsCore.owner(ofPane: id)?.pane(id) }

    @discardableResult
    func startRepeat(_ m: Macro, seconds: Int, paneId: String?, window: WindowModel?, askFirst: Bool = true) async -> Bool {
        guard let paneId, let p = pane(paneId), p.hasTerm else {
            StatusBus.shared.toast("Open a session first", kind: .error); return false
        }
        if m.interactive { StatusBus.shared.toast("\u{201C}\(m.name)\u{201D} follows a log \u{2014} it cannot repeat", kind: .error); return false }
        if m.noEnter { StatusBus.shared.toast("\u{201C}\(m.name)\u{201D} is left at the prompt \u{2014} it cannot repeat", kind: .error); return false }
        let every = max(1, seconds)
        if askFirst { guard await allowed(m, window: window) else { return false } }
        stopRepeat(paneId, m.id)
        let text = Macros.trimTrailingNewlines(m.command) + "\n"
        let key = Macros.repeatKey(paneId, m.id)
        repeats[key] = MacroRepeat(macro: m, paneId: paneId, every: every, since: nowMs(), runs: 0)
        let tick: @MainActor () -> Void = { [weak self] in
            guard let self else { return }
            // The pane went away, or its shell did: stop rather than write into nothing.
            guard let p = self.pane(paneId), p.hasTerm else { self.stopRepeat(paneId, m.id); return }
            Macros.sendText(text, to: p, window: window)
            self.repeats[key]?.runs += 1
        }
        tick()
        // In the common modes, so it keeps ticking through scrolling, drags and alerts.
        let timer = Timer(timeInterval: Double(every), repeats: true) { _ in
            MainActor.assumeIsolated { tick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        timers[key] = timer
        markUsed(m)
        refreshPaneButtons()
        let paneName = SessionsCore.paneTitle(p).nilIfEmpty ?? "this pane"
        StatusBus.shared.show("\(m.name) every \(Macros.fmtEvery(Double(every))) on \(paneName)")
        return true
    }

    @discardableResult
    func stopRepeat(_ paneId: String, _ macroId: String) -> Bool {
        let key = Macros.repeatKey(paneId, macroId)
        guard repeats[key] != nil else { return false }
        timers.removeValue(forKey: key)?.invalidate()
        repeats.removeValue(forKey: key)
        refreshPaneButtons()
        return true
    }

    /// Everything a pane had on a timer — called when the pane closes.
    @discardableResult
    func stopRepeatsForPane(_ paneId: String) -> Int {
        var n = 0
        for (key, r) in repeats where r.paneId == paneId {
            timers.removeValue(forKey: key)?.invalidate()
            repeats.removeValue(forKey: key)
            n += 1
        }
        if n > 0 { refreshPaneButtons() }
        return n
    }

    /// Mark the panes with a macro on a timer. The run button is where the
    /// repeat was started and where it is stopped, so it is where the fact belongs.
    func refreshPaneButtons() {
        for s in SessionsCore.allWindows() {
            for p in s.panes.values {
                let running = repeatsOnPane(p.id)
                p.macroRepeating = !running.isEmpty
                p.macroButtonTitle = running.isEmpty ? nil
                    : running.map { "\($0.macro.name) \u{2014} every \(Macros.fmtEvery(Double($0.every)))" }.joined(separator: "\n")
                        + "\n\nClick to stop or run another"
            }
        }
    }

    // MARK: Headless

    /**
     * Run without a terminal and show what came back. Refuses the macros that
     * never finish, since a headless exec would simply hang until its timeout.
     */
    func runOnHost(_ mIn: Macro, host: Host, login: String?, window: WindowModel?) async {
        if mIn.interactive {
            StatusBus.shared.toast("\u{201C}\(mIn.name)\u{201D} follows a log \u{2014} send it to a terminal instead", kind: .error); return
        }
        // Running it headless is precisely the thing this macro asked not to happen.
        if mIn.noEnter {
            StatusBus.shared.toast("\u{201C}\(mIn.name)\u{201D} is meant to be edited before running \u{2014} send it to a terminal", kind: .error); return
        }
        /*
         * This path is a host by definition — it is reached by picking one — so a
         * macro set for the local shell is being sent somewhere it does not belong.
         * Asked rather than refused, the same as sending one to the wrong pane.
         */
        if !Macros.runsOn(mIn, "remote") {
            let ok = await MiscUI.confirm(window, title: "Run it on a host?",
                                          message: "\u{201C}\(mIn.name)\u{201D} is set to run in \(Macros.runScopeLabel(mIn.whereScope).lowercased()).",
                                          detail: "It is about to run on a server instead.", confirmLabel: "Run it anyway")
            if !ok { return }
        }
        guard let m = await resolve(mIn, window: window) else { return }
        guard await allowed(m, window: window) else { return }
        markUsed(m)
        FleetRunCommand.open(host: host, login: login, command: m.command, title: m.name, window: window)
    }

    /// The host behind the focused pane, when there is one (`activeHost`).
    func activeHost(_ window: WindowModel?) -> (id: String?, label: String)? {
        guard let s = sessions(window), let connId = s.activeConnId, let c = ConnectionManager.shared.connection(connId) else { return nil }
        let label = SessConnRecords.shared.label(connId) ?? c.label
        return (c.hostId, label.isEmpty ? (c.remoteHostname ?? "") : label)
    }

    /**
     * What the Saved → Macros list does on double-click: send to the focused
     * terminal; with nothing focused, offer to run it on a host the user picks
     * and show the output.
     */
    func runHere(_ m: Macro, window: WindowModel?) async {
        if let s = sessions(window), s.activePane?.hasTerm == true {
            await send(m, window: window)
            return
        }
        guard let host = await FleetHostPicker.pick(window, title: "Run on which host?", visibleOnly: true) else { return }
        await runOnHost(m, host: host, login: FleetHooks.preferredLogin(host), window: window)
    }

    // MARK: Editing

    /// Hide a built-in (they cannot be deleted) or delete one of your own.
    @discardableResult
    func delete(_ m: Macro, window: WindowModel?) async -> Bool {
        if m.builtin {
            let ok = await MiscUI.confirm(window, title: "Hide built-in macro", message: "Hide \u{201C}\(m.name)\u{201D}?",
                                          detail: "Built-in macros cannot be deleted, only hidden. Restore them from the Macros menu.",
                                          confirmLabel: "Hide")
            if !ok { return false }
            FleetStore.setMacroHidden(m.id, true)
        } else {
            let ok = await MiscUI.confirm(window, title: "Delete macro", message: "Delete \u{201C}\(m.name)\u{201D}?",
                                          confirmLabel: "Delete", danger: true)
            if !ok { return false }
            FleetStore.deleteMacro(m.id)
        }
        Macros.headersChanged()
        return true
    }

    /// Bring back every dismissed built-in.
    func restoreBuiltins() {
        let hidden = FleetStore.hiddenMacros()
        if hidden.isEmpty { StatusBus.shared.show("No hidden macros"); return }
        for id in hidden { FleetStore.setMacroHidden(id, false) }
        Macros.headersChanged()
        StatusBus.shared.show("Restored \(hidden.count) built-in macro\(hidden.count == 1 ? "" : "s")")
    }

    /**
     * Pin or unpin from a menu, asking for an icon on the way in. Unpinning
     * asks nothing: it is instantly reversible.
     */
    func togglePin(_ m: Macro, window: WindowModel?) async {
        if isPinned(m.id) {
            setPinned(m.id, pinned: false)
            StatusBus.shared.show("Unpinned \(m.name)")
            return
        }
        guard let opts = await MacroDialogs.pinOptions(name: m.name, window: window) else { return }
        setPinned(m.id, pinned: true, icon: opts.icon, where: opts.where)
        StatusBus.shared.show("\(m.name) is now a button \u{2014} \(Macros.scopeLabel(opts.where).lowercased())")
    }

    /// The full list: the sidebar's Saved tab, on its Macros view.
    static func openManager(window: WindowModel?) {
        guard let w = window ?? WindowManager.shared.focused else { return }
        w.sidebarVisible = true
        let sw = w.feature(SidebarWindow.self)
        sw.tab = "saved"
        sw.savedView = "macros"
    }
}
