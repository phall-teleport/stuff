import Foundation

// The built-in setups (phasesetup.js SETUPS). Each: where it goes (`stage`:
// commands, files, or any), the fields it asks for, and what it adds to its
// stage. `expand` gets the field values and returns any of commands,
// services, files, homePaths.

extension PhaseSetups {
    static let setups: [PhaseSetup] = packages + cloud + settingsSetups + servicesSetups + filesSetups + yourOwn

    private static let packages: [PhaseSetup] = [
        PhaseSetup(id: "apt", group: "Packages and languages", label: "Debian packages",
                   help: "Any packages from Debian 13 (trixie), which the Beam image is built on.", stage: "commands",
                   fields: [PhaseSetupField(key: "packages", label: "Packages", placeholder: "ripgrep fd-find jq", required: true)]) { v, _ in
            let p = words(v["packages"]).joined(separator: " ")
            return PhaseSetupOutput(commands: [m(("comment", s("Install \(p)")), ("shell", s(apt(p))), ("env", aptEnv))])
        },
        PhaseSetup(id: "build-tools", group: "Packages and languages", label: "Compilers and build tools",
                   help: "gcc, make, pkg-config, unzip — what native modules and source builds expect.", stage: "commands") { _, _ in
            PhaseSetupOutput(commands: [m(("comment", s("Install compilers and build tools")),
                                          ("shell", s(apt("build-essential pkg-config unzip"))), ("env", aptEnv))])
        },
        PhaseSetup(id: "go", group: "Packages and languages", label: "Go",
                   help: "The official release from go.dev. Rebuilds pick up a new release when the version is left empty.", stage: "commands",
                   fields: [PhaseSetupField(key: "version", label: "Version", placeholder: "Latest — or e.g. 1.25.4")]) { v, _ in
            let ver = v["version"] ?? ""
            return PhaseSetupOutput(commands: [m(
                ("comment", s("Install Go \(ver.isEmpty ? "(latest release)" : ver)")),
                ("shell", s([
                    "set -eu",
                    #"v="${GO_VERSION:-}""#,
                    #"[ -n "$v" ] || v=$(curl -fsSL "https://go.dev/VERSION?m=text" | head -n 1)"#,
                    #"case "$v" in go*) ;; *) v="go$v" ;; esac"#,
                    "rm -rf /usr/local/go",
                    #"curl -fsSL "https://go.dev/dl/$v.linux-$(dpkg --print-architecture).tar.gz" | tar -xz -C /usr/local"#,
                    "ln -sf /usr/local/go/bin/go /usr/local/go/bin/gofmt /usr/local/bin/",
                    "go version",
                ].joined(separator: "\n"))),
                ("env", ver.isEmpty ? nil : env("GO_VERSION", ver.trimmed)))])
        },
        PhaseSetup(id: "rust", group: "Packages and languages", label: "Rust",
                   help: "rustup with a toolchain in /usr/local, so every user and service finds cargo and rustc on the PATH.", stage: "commands",
                   fields: [PhaseSetupField(key: "toolchain", label: "Toolchain", placeholder: "stable", defaultValue: "stable")]) { v, _ in
            let tc = or(v["toolchain"], "stable")
            return PhaseSetupOutput(commands: [m(
                ("comment", s("Install Rust (\(tc))")),
                ("shell", s([
                    "set -eu",
                    "export RUSTUP_HOME=/usr/local/rustup CARGO_HOME=/usr/local/cargo",
                    #"curl -fsSL https://sh.rustup.rs | sh -s -- -y --no-modify-path --profile minimal --default-toolchain "$RUST_TOOLCHAIN""#,
                    #"chmod -R a+rX "$RUSTUP_HOME" "$CARGO_HOME""#,
                    // The proxies look for RUSTUP_HOME, which a service or a plain
                    // `beams exec` never sets: a small wrapper for each sets it.
                    #"for b in "$CARGO_HOME"/bin/*; do"#,
                    #"  n=$(basename "$b")"#,
                    #"  printf '#!/bin/sh\nRUSTUP_HOME="${RUSTUP_HOME:-/usr/local/rustup}" exec %s "$@"\n' "$b" > "/usr/local/bin/$n""#,
                    #"  chmod 755 "/usr/local/bin/$n""#,
                    "done",
                    "rustc --version && cargo --version",
                ].joined(separator: "\n"))),
                ("env", env("RUST_TOOLCHAIN", tc.trimmed)))])
        },
        PhaseSetup(id: "java", group: "Packages and languages", label: "Java (OpenJDK)",
                   help: "Debian's OpenJDK, headless.", stage: "commands",
                   fields: [PhaseSetupField(key: "version", label: "Version", kind: "select", defaultValue: "21", options: ["21", "25"])]) { v, _ in
            let ver = or(v["version"], "21")
            return PhaseSetupOutput(commands: [m(("comment", s("Install OpenJDK \(ver)")),
                                                 ("shell", s("\(apt("openjdk-\(ver)-jdk-headless")) && java -version")),
                                                 ("env", aptEnv))])
        },
        PhaseSetup(id: "uv", group: "Packages and languages", label: "uv (Python)",
                   help: "Astral\u{2019}s uv — Python versions, virtualenvs and packages, fast. Python 3 itself is already in the image.",
                   stage: "commands") { _, _ in
            PhaseSetupOutput(commands: [m(("comment", s("Install uv")),
                                          ("shell", s("curl -LsSf https://astral.sh/uv/install.sh | env UV_INSTALL_DIR=/usr/local/bin UV_NO_MODIFY_PATH=1 sh && uv --version")))])
        },
        PhaseSetup(id: "node-tools", group: "Packages and languages", label: "pnpm, Yarn or Bun",
                   help: "Node.js 24 and npm are already in the image; these add the other package managers.", stage: "commands",
                   fields: [PhaseSetupField(key: "tools", label: "Which", placeholder: "pnpm yarn bun", defaultValue: "pnpm")]) { v, _ in
            let want = Set(words(v["tools"]).map { $0.lowercased() })
            let npm = ["pnpm", "yarn"].filter { want.contains($0) }
            var commands: [YAMLValue] = []
            if !npm.isEmpty {
                commands.append(m(("comment", s("Install \(npm.joined(separator: " and "))")),
                                  ("shell", s("npm install -g --no-audit --no-fund \(npm.joined(separator: " "))"))))
            }
            if want.contains("bun") {
                commands.append(m(("comment", s("Install Bun")),
                                  ("shell", s("\(apt("unzip")) && curl -fsSL https://bun.sh/install | BUN_INSTALL=/usr/local bash && bun --version")),
                                  ("env", aptEnv)))
            }
            return PhaseSetupOutput(commands: commands)
        },
    ]

    /* ---- Cloud and infrastructure CLIs (command stages) ---- */
    private static let cloud: [PhaseSetup] = [
        PhaseSetup(id: "kube-tools", group: "Cloud and infrastructure", label: "kubectl and Helm",
                   help: "For clusters reached through Teleport from the Beam (tsh kube login, then kubectl).", stage: "commands") { _, _ in
            PhaseSetupOutput(commands: [m(("comment", s("Install kubectl and Helm")), ("shell", s([
                "set -eu",
                "v=$(curl -fsSL https://dl.k8s.io/release/stable.txt)",
                #"curl -fsSLo /usr/local/bin/kubectl "https://dl.k8s.io/release/$v/bin/linux/$(dpkg --print-architecture)/kubectl""#,
                "chmod 755 /usr/local/bin/kubectl",
                "curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash",
                "kubectl version --client && helm version",
            ].joined(separator: "\n"))))])
        },
        PhaseSetup(id: "terraform", group: "Cloud and infrastructure", label: "Terraform",
                   help: "HashiCorp's release build, the current version on each rebuild.", stage: "commands") { _, _ in
            PhaseSetupOutput(commands: [m(("comment", s("Install Terraform")), ("shell", s([
                "set -eu",
                apt("unzip"),
                "v=$(curl -fsSL https://checkpoint-api.hashicorp.com/v1/check/terraform | jq -r .current_version)",
                #"curl -fsSLo /tmp/terraform.zip "https://releases.hashicorp.com/terraform/$v/terraform_${v}_linux_$(dpkg --print-architecture).zip""#,
                "unzip -o -q /tmp/terraform.zip terraform -d /usr/local/bin && rm -f /tmp/terraform.zip",
                "terraform version",
            ].joined(separator: "\n"))), ("env", aptEnv))])
        },
        PhaseSetup(id: "aws-cli", group: "Cloud and infrastructure", label: "AWS CLI",
                   help: "AWS CLI v2 — use it through tsh aws, or with tsh apps login for an AWS app.", stage: "commands") { _, _ in
            PhaseSetupOutput(commands: [m(("comment", s("Install the AWS CLI")), ("shell", s([
                "set -eu",
                apt("unzip"),
                #"curl -fsSLo /tmp/awscli.zip "https://awscli.amazonaws.com/awscli-exe-linux-$(uname -m).zip""#,
                "unzip -q /tmp/awscli.zip -d /tmp && /tmp/aws/install --update && rm -rf /tmp/aws /tmp/awscli.zip",
                "aws --version",
            ].joined(separator: "\n"))), ("env", aptEnv))])
        },
        PhaseSetup(id: "gcloud", group: "Cloud and infrastructure", label: "Google Cloud CLI",
                   help: "gcloud from Google's own Debian repository.", stage: "commands") { _, _ in
            PhaseSetupOutput(commands: [m(("comment", s("Install the Google Cloud CLI")), ("shell", s([
                "set -eu",
                apt("gnupg"),
                "curl -fsSL https://packages.cloud.google.com/apt/doc/apt-key.gpg | gpg --dearmor --yes -o /usr/share/keyrings/cloud.google.gpg",
                #"echo "deb [signed-by=/usr/share/keyrings/cloud.google.gpg] https://packages.cloud.google.com/apt cloud-sdk main" > /etc/apt/sources.list.d/google-cloud-sdk.list"#,
                apt("google-cloud-cli"),
                "gcloud --version | head -n 1",
            ].joined(separator: "\n"))), ("env", aptEnv))])
        },
        PhaseSetup(id: "azure-cli", group: "Cloud and infrastructure", label: "Azure CLI",
                   help: "az from Microsoft's Debian repository — Debian 13's own when Microsoft has it, bookworm's until then.",
                   stage: "commands") { _, _ in
            PhaseSetupOutput(commands: [m(("comment", s("Install the Azure CLI")), ("shell", s([
                "set -eu",
                apt("gnupg"),
                "curl -fsSL https://packages.microsoft.com/keys/microsoft.asc | gpg --dearmor --yes -o /usr/share/keyrings/microsoft.gpg",
                #"c=$(. /etc/os-release && echo "$VERSION_CODENAME")"#,
                // Microsoft adds a Debian release to its repository some time after it ships.
                #"curl -fsI "https://packages.microsoft.com/repos/azure-cli/dists/$c/Release" >/dev/null 2>&1 || c=bookworm"#,
                #"echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/microsoft.gpg] https://packages.microsoft.com/repos/azure-cli/ $c main" > /etc/apt/sources.list.d/azure-cli.list"#,
                apt("azure-cli"),
                "az version --output tsv | head -n 1",
            ].joined(separator: "\n"))), ("env", aptEnv))])
        },
    ]

    /* ---- Settings (command stages) ---- */
    private static let settingsSetups: [PhaseSetup] = [
        PhaseSetup(id: "env", group: "Settings", label: "Environment variables",
                   help: "Set for every login shell (written to /etc/profile.d). Services take their own env instead.", stage: "commands",
                   fields: [PhaseSetupField(key: "vars", label: "Variables", kind: "textarea",
                                            placeholder: "EDITOR=vim\nNODE_ENV=development", required: true)]) { v, _ in
            let lines = (v["vars"] ?? "").components(separatedBy: "\n").map(\.trimmed).filter { !$0.isEmpty && !$0.hasPrefix("#") }
            let body: [String] = lines.compactMap { l in
                guard let at = l.firstIndex(of: "="), at != l.startIndex else { return nil }
                return "export \(String(l[..<at]).trimmed)=\(sq(String(l[l.index(after: at)...]).trimmed))"
            }
            return PhaseSetupOutput(
                commands: [m(("comment", s("Set environment variables for login shells")),
                             ("shell", s("cat > /etc/profile.d/serverlife-env.sh <<'EOF'\n\(body.joined(separator: "\n"))\nEOF")))],
                check: lines.filter { !test(#"^[A-Za-z_][A-Za-z0-9_]*\s*="#, $0) }.map { "\"\($0)\" is not NAME=value" })
        },
        PhaseSetup(id: "deps-under-home", group: "Settings", label: "Rebuild dependencies under /home",
                   help: "For an app saved in an interactive Phase: this stage reinstalls its dependencies (npm ci, by default) on every rebuild, and reserves that folder for it.",
                   stage: "commands",
                   fields: [
                    PhaseSetupField(key: "dir", label: "App folder", placeholder: "/home/beams/app", defaultValue: "/home/beams/app", required: true),
                    PhaseSetupField(key: "reserve", label: "Folder it writes", placeholder: "/home/beams/app/node_modules",
                                    defaultValue: "/home/beams/app/node_modules", required: true),
                    PhaseSetupField(key: "command", label: "Install command", placeholder: "npm ci", defaultValue: "npm ci", required: true),
                   ]) { v, _ in
            PhaseSetupOutput(commands: [m(("comment", s("Reinstall dependencies in \(v["dir"] ?? "undefined")")),
                                          ("shell", s(or(v["command"], "npm ci"))),
                                          ("workdir", s((v["dir"] ?? "").trimmed)))],
                             homePaths: [.string((v["reserve"] ?? "").trimmed)])
        },
    ]

    /* ---- Services (either stage) ---- */
    private static let servicesSetups: [PhaseSetup] = [
        PhaseSetup(id: "clone-repo", group: "Services", label: "Clone a repository on first start",
                   help: "Runs before anything else when a Beam starts; does nothing if the folder is already there, so saved work is kept.",
                   stage: "any",
                   fields: [
                    PhaseSetupField(key: "url", label: "Repository URL", placeholder: "https://github.com/example/app.git", required: true),
                    PhaseSetupField(key: "dir", label: "Into", placeholder: "/home/beams/app", defaultValue: "/home/beams/app", required: true),
                   ]) { v, _ in
            let base = basename(or(v["dir"], "repo")).replacingOccurrences(of: "[^A-Za-z0-9._-]", with: "", options: .regularExpression)
            let dir = v["dir"] ?? "undefined", url = v["url"] ?? "undefined"
            return PhaseSetupOutput(services: [m(
                ("name", s("clone-" + (base.isEmpty ? "repo" : base))),
                ("comment", s("Clone \(url)")),
                ("type", s("pre-start")), ("context", s("user")),
                ("shell", s("[ -d \(sq(dir))/.git ] || git clone \(sq(url)) \(sq(dir))")))])
        },
        PhaseSetup(id: "postgres", group: "Services", label: "PostgreSQL server",
                   help: "Postgres running for the beams user, on localhost:5432. Its data is under /home/beams/.pgdata, so an interactive snapshot saves your dev database with your work.",
                   stage: "commands") { _, _ in
            PhaseSetupOutput(
                commands: [m(("comment", s("Install PostgreSQL")), ("shell", s([
                    "set -eu",
                    apt("postgresql"),
                    "v=$(ls /usr/lib/postgresql | sort -V | tail -n 1)",
                    // The packaged cluster is not used; a per-user one is made on first start.
                    #"pg_dropcluster --stop "$v" main 2>/dev/null || true"#,
                    #"for b in initdb postgres pg_ctl; do ln -sf "/usr/lib/postgresql/$v/bin/$b" /usr/local/bin/; done"#,
                    #"printf 'export PGHOST=localhost\n' > /etc/profile.d/serverlife-postgres.sh"#,
                ].joined(separator: "\n"))), ("env", aptEnv))],
                services: [
                    m(("name", s("postgres-init")), ("comment", s("Create the dev database once")),
                      ("type", s("pre-start")), ("context", s("user")), ("shell", s([
                        "D=/home/beams/.pgdata",
                        #"[ -d "$D" ] && exit 0"#,
                        #"initdb -D "$D" -U beams --auth=trust >/dev/null"#,
                        #"printf "listen_addresses = 'localhost'\nunix_socket_directories = '/tmp'\n" >> "$D/postgresql.conf""#,
                        // A database named after the user, so a plain `psql` connects.
                        #"pg_ctl -D "$D" -w -o "-c listen_addresses=" start >/dev/null"#,
                        "createdb -h /tmp beams",
                        #"pg_ctl -D "$D" -w stop >/dev/null"#,
                      ].joined(separator: "\n")))),
                    m(("name", s("postgres")), ("comment", s("PostgreSQL on localhost:5432")), ("type", s("background")),
                      ("context", s("user")), ("shell", s("exec postgres -D /home/beams/.pgdata"))),
                ])
        },
        PhaseSetup(id: "redis", group: "Services", label: "Redis server",
                   help: "Redis on localhost:6379, kept in memory only — every Beam starts with it empty.", stage: "commands") { _, _ in
            PhaseSetupOutput(
                commands: [m(("comment", s("Install Redis")), ("shell", s(apt("redis-server"))), ("env", aptEnv))],
                services: [m(("name", s("redis")), ("comment", s("Redis on localhost:6379")), ("type", s("background")),
                             ("context", s("user")), ("shell", s("exec redis-server --bind 127.0.0.1 --save '' --appendonly no --dir /tmp")))])
        },
        PhaseSetup(id: "app-service", group: "Services", label: "Run my app",
                   help: "A long-running program started in every Beam from this image. Listen on 0.0.0.0, then publish the Beam (tsh beams publish) to reach it.",
                   stage: "any",
                   fields: [
                    PhaseSetupField(key: "name", label: "Service name", placeholder: "app", defaultValue: "app", required: true),
                    PhaseSetupField(key: "shell", label: "Command", placeholder: "python3 -m http.server 8080 --directory /home/beams/app", required: true),
                    PhaseSetupField(key: "workdir", label: "Working folder", placeholder: "/home/beams"),
                    PhaseSetupField(key: "context", label: "Runs in", kind: "select", defaultValue: "runtime", options: serviceContexts),
                   ]) { v, _ in
            PhaseSetupOutput(services: [m(
                ("name", s(or(v["name"], "app").trimmed)), ("comment", s("Run \(or(v["name"], "app"))")), ("type", s("background")),
                ("context", s(or(v["context"], "runtime"))), ("shell", s(v["shell"] ?? "")),
                ("workdir", s(trimmedOrNil(v["workdir"]))))])
        },
    ]

    /* ---- Files (copy stages) ---- */
    private static let filesSetups: [PhaseSetup] = [
        PhaseSetup(id: "copy", group: "Files", label: "Copy a file or folder",
                   help: "From this computer into the image, outside /home. A folder merges into the destination.", stage: "files",
                   fields: [
                    PhaseSetupField(key: "from", label: "From (this computer)", kind: "path", placeholder: "/Users/me/project/config", required: true),
                    PhaseSetupField(key: "to", label: "To (in the Beam)", placeholder: "/opt/app/config", required: true),
                   ]) { v, _ in
            let from = v["from"] ?? ""
            return PhaseSetupOutput(files: [m(("comment", s("Copy \(basename(from))")),
                                              ("from", s(from.trimmed)), ("to", s((v["to"] ?? "").trimmed)))])
        },
        PhaseSetup(id: "dotfiles", group: "Files", label: "My dotfiles and settings",
                   help: "Files from your home folder — .gitconfig, .vimrc, .tmux.conf, ~/.claude settings — put in the Beam user\u{2019}s home on first start. Files already there are left alone unless you say to replace them.",
                   stage: "files",
                   fields: [
                    PhaseSetupField(key: "paths", label: "Files or folders", kind: "paths", placeholder: "~/.gitconfig\n~/.vimrc\n~/.tmux.conf", required: true),
                    PhaseSetupField(key: "replace", label: "Replace files already in the Beam", kind: "select", defaultValue: "no", options: ["no", "yes"]),
                   ]) { v, ctx in
            let home = ctx.home
            let list = (v["paths"] ?? "").components(separatedBy: "\n").map(\.trimmed).filter { !$0.isEmpty }
                .map { p in p == "~" || p.hasPrefix("~/") ? join(home, String(p.dropFirst())) : p }
            let files: [YAMLValue] = list.map { p in
                // Kept at the same place relative to home: ~/.claude/x lands in /home/beams/.claude/x.
                let inHome = !home.isEmpty && p.hasPrefix(home + "/")
                let rel = inHome ? relative(home, p) : basename(p)
                return m(("comment", s("Bring in \(inHome ? "~/" : "")\(rel)")), ("from", s(p)), ("to", s("\(homeStaging)/\(rel)")))
            }
            return PhaseSetupOutput(services: [m(
                ("name", s("serverlife-home")), ("comment", s("Put dotfiles in place")), ("type", s("pre-start")),
                ("context", s("user")), ("shell", s("cp -R\(v["replace"] == "yes" ? "f" : "n") \(homeStaging)/. /home/beams/")))],
                files: files)
        },
    ]

    /* ---- Your own (either) ---- */
    private static let yourOwn: [PhaseSetup] = [
        PhaseSetup(id: "command", group: "Your own", label: "A command",
                   help: "Any shell script, run as root. Keep it repeatable: rebuilds run it again on a fresh copy of the parent.",
                   stage: "commands",
                   fields: [
                    PhaseSetupField(key: "comment", label: "Shown in the log as", placeholder: "Install my tools"),
                    PhaseSetupField(key: "shell", label: "Shell", kind: "textarea", placeholder: "apt-get update && apt-get install -y htop", required: true),
                    PhaseSetupField(key: "workdir", label: "Working folder", placeholder: "/"),
                   ]) { v, _ in
            PhaseSetupOutput(commands: [m(("comment", s(trimmedOrNil(v["comment"]))), ("shell", s(v["shell"] ?? "")),
                                          ("workdir", s(trimmedOrNil(v["workdir"]))))])
        },
        PhaseSetup(id: "service", group: "Your own", label: "A service",
                   help: "A program started with every Beam from this image, as the beams user (sudo for root).", stage: "any",
                   fields: [
                    PhaseSetupField(key: "name", label: "Name", placeholder: "my-service", required: true),
                    PhaseSetupField(key: "type", label: "Kind", kind: "select", defaultValue: "background", options: serviceTypes),
                    PhaseSetupField(key: "context", label: "Runs in", kind: "select", defaultValue: "user", options: serviceContexts),
                    PhaseSetupField(key: "shell", label: "Shell", kind: "textarea", placeholder: "exec my-server --port 8080", required: true),
                   ]) { v, _ in
            PhaseSetupOutput(services: [m(("name", s((v["name"] ?? "").trimmed)), ("type", s(or(v["type"], "background"))),
                                          ("context", s(or(v["context"], "user"))), ("shell", s(v["shell"] ?? "")))])
        },
        PhaseSetup(id: "raw", group: "Your own", label: "Written in YAML",
                   help: "Commands, services, files and rebuild_home_paths exactly as phase.yaml has them — what an opened phase.yaml becomes, and the way to write anything the other setups do not cover.",
                   stage: "any",
                   fields: [PhaseSetupField(key: "yaml", label: "phase.yaml", kind: "yaml",
                                            placeholder: "commands:\n  - comment: Install htop\n    shell: apt-get update && apt-get install -y htop",
                                            required: true)]) { v, _ in
            var doc: YAMLValue
            do {
                doc = try YAMLReader.load(v["yaml"] ?? "")
                if !doc.truthy { doc = .map([]) }
            } catch { return PhaseSetupOutput(check: ["not YAML: \(firstLine(error))"]) }
            guard case .map(let entries) = doc else {
                return PhaseSetupOutput(check: ["should be a mapping of commands:, services:, files:"])
            }
            let allowed = ["commands", "services", "files", "rebuild_home_paths"]
            let unknown = uniqueKeys(entries).filter { !allowed.contains($0) }
            let lists = allowed.filter { !doc[$0].isNull && doc[$0].items == nil }
            var check: [String] = []
            if !unknown.isEmpty {
                check.append("unknown key\(unknown.count > 1 ? "s" : ""): \(unknown.joined(separator: ", ")) (commands, services, files, rebuild_home_paths)")
            }
            check += lists.map { "\($0) should be a list" }
            return PhaseSetupOutput(commands: doc["commands"].items ?? [], services: doc["services"].items ?? [],
                                    files: doc["files"].items ?? [], homePaths: doc["rebuild_home_paths"].items ?? [], check: check)
        },
    ]
}
