import Testing
import Foundation
@testable import ServerLife

// Ports of tests/tsh-env.test.mjs, tests/vnet.test.mjs, tests/phases.test.mjs
// (the parts that are not phasesetup.js) and tests/sshconfigedit.test.mjs,
// plus the 0.16–0.39 teleport.js helpers.

private func tempDir(_ prefix: String = "sl-tp39-") -> String {
    let d = NSTemporaryDirectory() + prefix + UUID().uuidString
    try? FileManager.default.createDirectory(atPath: d, withIntermediateDirectories: true)
    return d
}

private func write(_ path: String, _ text: String) {
    try? FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
    FileManager.default.createFile(atPath: path, contents: Data(text.utf8), attributes: [.posixPermissions: 0o600])
}

private func read(_ path: String) -> String { (try? String(contentsOfFile: path, encoding: .utf8)) ?? "" }

private func fixture(_ name: String) -> String {
    let dir = ((#filePath as NSString).deletingLastPathComponent as NSString).appendingPathComponent("Fixtures")
    return read((dir as NSString).appendingPathComponent(name))
}

// MARK: - tsh variables

@Suite(.serialized) struct TshEnvTests {
    @Test func nameValueLines() {
        let r = TshEnv.parse("TELEPORT_TOOLS_VERSION=18.11.9")
        #expect(r.vars == ["TELEPORT_TOOLS_VERSION": "18.11.9"])
        #expect(r.errors.isEmpty)
    }

    @Test func shellProfileLinesReadTheSame() {
        #expect(TshEnv.parse("export TELEPORT_TOOLS_VERSION=\"18.11.9\"\nA='x y'").vars
                == ["TELEPORT_TOOLS_VERSION": "18.11.9", "A": "x y"])
    }

    @Test func blankAndCommentsSkippedOthersReported() {
        let r = TshEnv.parse("\n# a comment\nGOOD=1\nnot an assignment\n9BAD=x")
        #expect(r.vars == ["GOOD": "1"])
        #expect(r.errors.count == 2)
        #expect(r.errors[0].hasPrefix("line 4:"))
    }

    @Test func clusterGetsGlobalAndItsOwn() {
        defer { TshEnv.setSettings(global: "", clusters: [:], homesEnv: [:], inShells: false) }
        TshEnv.setSettings(global: "SHARED=1\nTELEPORT_TOOLS_VERSION=18.11.7",
                           clusters: ["red-fire.beams.sh": "TELEPORT_TOOLS_VERSION=18.11.9"], homesEnv: [:], inShells: false)
        for p in ["red-fire.beams.sh", "red-fire.beams.sh:443", "https://red-fire.beams.sh/web"] {
            #expect(TshEnv.envFor(p) == ["SHARED": "1", "TELEPORT_TOOLS_VERSION": "18.11.9"])
        }
        #expect(TshEnv.envFor("other.example.com:443") == ["SHARED": "1", "TELEPORT_TOOLS_VERSION": "18.11.7"])
        #expect(TshEnv.envFor(nil) == ["SHARED": "1", "TELEPORT_TOOLS_VERSION": "18.11.7"])
    }

    @Test func everyTshGetsTheClustersVars() {
        defer { TshEnv.setSettings(global: "", clusters: [:], homesEnv: [:], inShells: false) }
        TshEnv.setSettings(global: "", clusters: ["red-fire.beams.sh": "TELEPORT_TOOLS_VERSION=18.11.9"], homesEnv: [:], inShells: false)
        #expect(TshEnv.vars(home: nil, proxy: "red-fire.beams.sh:443", environment: [:], chosen: nil)["TELEPORT_TOOLS_VERSION"] == "18.11.9")
        #expect(TshEnv.vars(home: nil, proxy: "other.example.com:443", environment: [:], chosen: nil)["TELEPORT_TOOLS_VERSION"] == nil)
    }

    @Test func toolsVersionWinsOverChosenTshOff() {
        defer { TshEnv.setSettings(global: "", clusters: [:], homesEnv: [:], inShells: false) }
        TshEnv.setSettings(global: "", clusters: ["red-fire.beams.sh": "TELEPORT_TOOLS_VERSION=18.11.9"], homesEnv: [:], inShells: false)
        #expect(TshEnv.vars(home: nil, proxy: "red-fire.beams.sh", environment: [:], chosen: "/opt/tsh")["TELEPORT_TOOLS_VERSION"] == "18.11.9")
        #expect(TshEnv.vars(home: nil, proxy: "other.example.com", environment: [:], chosen: "/opt/tsh")["TELEPORT_TOOLS_VERSION"] == "off")
        // Someone's own TELEPORT_TOOLS_VERSION is left to decide.
        #expect(TshEnv.vars(home: nil, proxy: "other.example.com", environment: ["TELEPORT_TOOLS_VERSION": "18.1.0"],
                            chosen: "/opt/tsh")["TELEPORT_TOOLS_VERSION"] == nil)
    }

    @Test func localShellsGetGlobalOnlyWhenAsked() {
        defer { TshEnv.setSettings(global: "", clusters: [:], homesEnv: [:], inShells: false) }
        TshEnv.setSettings(global: "A=1", clusters: ["x": "B=2"], homesEnv: [:], inShells: false)
        #expect(TshEnv.envForShells() == [:])
        TshEnv.setSettings(global: "A=1", clusters: ["x": "B=2"], homesEnv: [:], inShells: true)
        #expect(TshEnv.envForShells() == ["A": "1"])
    }

    @Test func homesWithVariables() {
        let env = ["SL_TEST_WORK": "/tmp/sl-work"]
        #expect(TshEnv.expandHome("$SL_TEST_WORK/.tsh", environment: env) == "/tmp/sl-work/.tsh")
        #expect(TshEnv.expandHome("${SL_TEST_WORK}/tsh-b", environment: env) == "/tmp/sl-work/tsh-b")
        #expect(TshEnv.expandHome("$SL_TEST_NOT_SET/.tsh", environment: env) == "")
        #expect(TshEnv.unsetVars("$SL_TEST_WORK/${SL_NOPE}/$SL_NOPE2", environment: env) == ["SL_NOPE", "SL_NOPE2"])
    }

    @Test func chosenTsh() {
        #expect(TshEnv.chosenTsh(settingsPath: "/opt/tsh", environment: [:]) == "/opt/tsh")
        #expect(TshEnv.chosenTsh(settingsPath: "", environment: ["TSH_PATH": "/x/tsh"]) == "/x/tsh")
        #expect(TshEnv.chosenTsh(settingsPath: nil, environment: [:]) == nil)
        #expect(TshEnv.chosenFrom(settingsPath: "/opt/tsh", environment: [:]) == "settings")
        #expect(TshEnv.chosenFrom(settingsPath: nil, environment: ["TSH_PATH": "/x/tsh"]) == "TSH_PATH")
    }

    @Test func proxyInArgs() {
        #expect(TshEnv.proxyInArgs(["--proxy=a.example.com:443", "ssh", "x"]) == "a.example.com:443")
        #expect(TshEnv.proxyInArgs(["--proxy", "b.example.com", "ls"]) == nil)   // only the = form, as teleport.js
        #expect(TshEnv.proxyInArgs(["ls"]) == nil)
    }
}

// MARK: - VNet

@Test func vnetProfileName() {
    #expect(VnetManager.profileName("red-fire.beams.sh:443") == "red-fire.beams.sh")
    #expect(VnetManager.profileName("https://red-fire.beams.sh/web") == "red-fire.beams.sh")
    #expect(VnetManager.profileName("plain.example.com") == "plain.example.com")
}

@Test func vnetScopedHomeHoldsOnlyItsCluster() throws {
    let real = tempDir(), root = tempDir()
    write(real + "/a.example.com.yaml", "web_proxy_addr: a.example.com:443\n")
    write(real + "/b.example.com.yaml", "web_proxy_addr: b.example.com:443\n")
    write(real + "/keys/a.example.com/alice", "key")
    write(real + "/keys/b.example.com/alice", "key")
    write(real + "/known_hosts", "")
    let dir = try #require(try VnetManager.scopedHome(real, proxy: "a.example.com:443", root: root))
    let names = try FileManager.default.contentsOfDirectory(atPath: dir).sorted()
    #expect(names == ["a.example.com.yaml", "current-profile", "keys", "known_hosts"])
    #expect(try FileManager.default.contentsOfDirectory(atPath: dir + "/keys") == ["a.example.com"])
    #expect(read(dir + "/current-profile") == "a.example.com\n")
    #expect(try FileManager.default.destinationOfSymbolicLink(atPath: dir + "/a.example.com.yaml") == real + "/a.example.com.yaml")
    #expect(try VnetManager.scopedHome(real, proxy: "c.example.com", root: root) == nil)
}

// MARK: - Beams: add support, Phases

@Test func addSupportWithout() {
    let r = Beams.parseAddSupport(addHelp: fixture("v18.11.7-beams-add.txt"), phaseHelp: "",
                                  phaseHelpStderr: fixture("v18.11.7-phase.txt"), phaseAddHelp: "")
    #expect(!fixture("v18.11.7-beams-add.txt").isEmpty)
    #expect(!r.phases && !r.roles && !r.apply)
}

@Test func addSupportWith() {
    let r = Beams.parseAddSupport(addHelp: fixture("v18.11.9-beams-add.txt"), phaseHelp: fixture("v18.11.9-phase.txt"),
                                  phaseHelpStderr: "", phaseAddHelp: "")
    #expect(r.phases && r.roles)
}

@Test func addSupportApplyCopyNoConsole() {
    let r = Beams.parseAddSupport(
        addHelp: fixture("v18.11.9-beams-add.txt"),
        phaseHelp: fixture("v18.11.9-phase.txt") + "\n  phase apply     Create or update Phases from a multi-document YAML configuration.\n",
        phaseHelpStderr: "",
        phaseAddHelp: "      --[no-]console  Open an interactive shell or stream command logs.\n      --copy=COPY ...  Copy files outside /home\n")
    #expect(r.apply && r.copy && r.noConsole)
}

@Test func phasesNeedBoth() {
    let r = Beams.parseAddSupport(addHelp: fixture("v18.11.9-beams-add.txt"), phaseHelp: "",
                                  phaseHelpStderr: fixture("v18.11.7-phase.txt"), phaseAddHelp: "")
    #expect(!r.phases)
    #expect(r.roles)
}

@Test func phaseAddArgs() throws {
    #expect(try Beams.phaseAddArgs(proxy: "red-fire.beams.sh:443") == ["--proxy=red-fire.beams.sh:443", "phase", "add"])
    #expect(try Beams.phaseAddArgs(proxy: nil, name: "dev-tools") == ["phase", "add", "dev-tools"])
    #expect(try Beams.phaseAddArgs(proxy: nil, name: "project-tools", from: "sage-garden")
            == ["phase", "add", "project-tools", "--from=sage-garden"])
    #expect(try Beams.phaseAddArgs(proxy: nil, name: "my-fork", forkFrom: "sage-garden@sha256:34eada19f8")
            == ["phase", "add", "my-fork", "--fork-from=sage-garden@sha256:34eada19f8"])
    #expect(throws: AppError.self) { try Beams.phaseAddArgs(proxy: nil, from: "a", forkFrom: "b") }
    #expect(try Beams.phaseAddArgs(proxy: nil, name: "x", roles: ["access", "beam-user"], region: "us-west-2")
            == ["phase", "add", "x", "--roles=access,beam-user", "--region=us-west-2"])
    #expect(try Beams.phaseAddArgs(proxy: nil, name: "x", roles: []) == ["phase", "add", "x"])
    #expect(try Beams.phaseAddArgs(proxy: nil, name: "dev-tools", commandsFile: "/tmp/build.yaml")
            == ["phase", "add", "dev-tools", "--commands-file=/tmp/build.yaml"])
    #expect(try Beams.phaseAddArgs(proxy: nil, name: "p", from: "dev-tools", commandsFile: "/tmp/b.yaml")
            == ["phase", "add", "p", "--from=dev-tools", "--commands-file=/tmp/b.yaml"])
    #expect(throws: AppError.self) { try Beams.phaseAddArgs(proxy: nil, forkFrom: "dev-tools", commandsFile: "/tmp/b.yaml") }
}

@Test func phaseEditArgs() throws {
    #expect(try Beams.phaseEditArgs(proxy: "p:443", name: "sage-garden") == ["--proxy=p:443", "phase", "edit", "sage-garden"])
    #expect(throws: AppError.self) { try Beams.phaseEditArgs(proxy: nil, name: "") }
}

@Test func copyFlags() throws {
    #expect(try Beams.copyFlags([PhaseCopy(from: "./a.conf", to: "/etc/a.conf")]) == ["--copy=/etc/a.conf:./a.conf"])
    #expect(throws: AppError.self) { try Beams.copyFlags([PhaseCopy(from: "a", to: "etc/a")]) }
    #expect(throws: AppError.self) { try Beams.copyFlags([PhaseCopy(from: "a", to: "/home/x/a")]) }
    #expect(throws: AppError.self) { try Beams.copyFlags([PhaseCopy(from: "", to: "/etc/a")]) }
}

// MARK: - Versions, login methods, inventory ids

@Test func versionCompatibility() {
    #expect(Teleport.majorOf("v18.11.7") == 18)
    #expect(Teleport.majorOf("nonsense") == nil)
}

@Test func loginMethodsFromConfigJS() {
    let js = """
    var GRV_CONFIG = {"auth":{"authType":"github","defaultConnectorName":"gh","localAuthEnabled":false,"allowPasswordless":true,"second_factors":["webauthn"],"providers":[{"name":"gh","type":"github","displayName":"GitHub"},{"name":"okta","type":"saml"}]}};
    """
    let m = Teleport.parseLoginMethods(js)
    #expect(m.ok)
    #expect(m.authType == "github")
    #expect(m.defaultConnector == "gh")
    #expect(!m.local)
    #expect(m.passwordless)
    #expect(m.secondFactors == ["webauthn"])
    #expect(m.providers.map(\.display) == ["GitHub", "okta"])
    #expect(Teleport.parseLoginMethods("nothing here").local)
}

@Test func kubeInventoryIdsNeverCollideWithNodes() {
    let ids = Teleport.inventoryKubeIds([(id: "/c/kube_cluster/k1", cluster: "c", name: "k1")], home: nil)
    #expect(ids["/c/kube_cluster/k1"]?.hasPrefix("tsh-kube:") == true)
    #expect(ids["/c/kube_cluster/k1"]?.hasSuffix(":c:k1") == true)
}

// MARK: - Install Teleport on a host

@Test func nodeInstallCommand() {
    let r = Teleport.nodeInstallCommand(proxy: "https://teleport.example.com:443/web", token: "abc123",
                                        labels: [("env", "prod"), ("team", "ops")], nodeName: "web-1")
    #expect(r.ok)
    let lines = r.command.components(separatedBy: "\n")
    #expect(lines.first == "curl -fsSL https://teleport.example.com/scripts/install.sh | sudo sh")
    #expect(lines[1].contains("--proxy=teleport.example.com:443"))
    #expect(lines[1].contains("--token=abc123"))
    #expect(lines[1].contains("--node-name=web-1"))
    #expect(lines[1].contains("--labels=env=prod,team=ops"))
    #expect(lines.last == "sudo systemctl enable --now teleport")
    #expect(!Teleport.nodeInstallCommand(proxy: nil, token: "x").ok)
    #expect(!Teleport.nodeInstallCommand(proxy: "p", token: "x", labels: [("bad key", "v")]).ok)
    #expect(!Teleport.nodeInstallCommand(proxy: "p", token: "x", nodeName: "a b").ok)
}

@Test func joinTokenReading() {
    #expect(Teleport.tokenFrom("The invite token: x\n\nabcdef0123456789\n\n") == "abcdef0123456789")
    #expect(Teleport.tctlStatusCluster("Cluster:  prod.example.com\nVersion:  18.1.0\n") == "prod.example.com")
}

// MARK: - ssh config: delete or comment out a host

private let CONFIG = [
    "Host *",
    "  ServerAliveInterval 30",
    "",
    "# the web box",
    "Host web",
    "  HostName 10.0.0.5",
    "  User deploy",
    "",
    "# the database",
    "Host db db-replica",
    "  HostName 10.0.0.6",
    "",
    "Match host other",
    "  User x",
    "",
].joined(separator: "\n")

private func tmpConfig(_ text: String = CONFIG) -> String {
    let f = tempDir("slcfg-") + "/config"
    write(f, text)
    return f
}

@Test func blockEndsBeforeNextDescription() throws {
    let lines = CONFIG.components(separatedBy: "\n")
    let b = try #require(SSHConfig.findHostBlock(lines, alias: "web"))
    #expect(Array(lines[b.start..<b.end]) == ["Host web", "  HostName 10.0.0.5", "  User deploy"])
    #expect(b.shared.isEmpty)
}

@Test func deleteRemovesOnlyThatBlockKeepsBackup() throws {
    let file = tmpConfig()
    try SSHConfig.removeHostFromFile(file: file, alias: "web", mode: "delete")
    let out = read(file)
    #expect(!out.contains("Host web"))
    #expect(!out.contains("# the web box"))
    #expect(out.contains("  ServerAliveInterval 30\n\n# the database\nHost db db-replica"))
    #expect(read(file + ".serverlife-backup") == CONFIG)
    let mode = (try FileManager.default.attributesOfItem(atPath: file)[.posixPermissions] as? NSNumber)?.intValue
    #expect(mode == 0o600)
}

@Test func commentOutKeepsEveryLinePrefixed() throws {
    let file = tmpConfig()
    try SSHConfig.removeHostFromFile(file: file, alias: "web", mode: "comment")
    let out = read(file)
    #expect(TPText.test(#"# Commented out by ServerLife, \d{4}-\d\d-\d\d\n# Host web\n# {3}HostName 10\.0\.0\.5\n# {3}User deploy\n"#, out))
    #expect(SSHConfig.collectAliases(file).map(\.alias) == ["db", "db-replica"])
}

@Test func sharedNameTakenOffTheLine() throws {
    let file = tmpConfig()
    try SSHConfig.removeHostFromFile(file: file, alias: "db-replica", mode: "delete")
    #expect(read(file).contains("Host db\n  HostName 10.0.0.6"))
}

@Test func missingAliasIsAnErrorFileUntouched() {
    let file = tmpConfig()
    #expect(throws: AppError.self) { try SSHConfig.removeHostFromFile(file: file, alias: "nope") }
    #expect(read(file) == CONFIG)
}

@Test func blockPreview() throws {
    let file = tmpConfig()
    let p = try SSHConfig.hostBlockPreview(file: file, alias: "web")
    #expect(p.text == "# the web box\nHost web\n  HostName 10.0.0.5\n  User deploy")
    #expect(p.line == 5)
    let s = try SSHConfig.hostBlockPreview(file: file, alias: "db")
    #expect(s.shared == ["db-replica"])
    #expect(s.text.hasPrefix("Host db db-replica"))
}

@Test func identityFilesAccumulateFromFile() {
    let file = tmpConfig("Host a\n  IdentityFile ~/.ssh/id_ed25519\n  IdentityFile ~/.ssh/id_rsa_fallback\n  User u1\n  User u2\n  CertificateFile ~/.ssh/id_ed25519-cert.pub\n")
    let cfg = SSHConfig.readAliasFromFile(SSHConfig.Alias(alias: "a", source: file, comment: nil))
    #expect(cfg["identityfile"] == ["~/.ssh/id_ed25519", "~/.ssh/id_rsa_fallback"])
    #expect(cfg["certificatefile"] == ["~/.ssh/id_ed25519-cert.pub"])
    #expect(cfg["user"] == ["u1"])
    #expect(SSHConfig.asList([" a ", "", "b"]) == ["a", "b"])
}

@Test func newHostInAGivenConfig() throws {
    let primary = tmpConfig("Host x\n  HostName 1.2.3.4\n")
    let other = tmpConfig("Host y\n  HostName 5.6.7.8\n")
    let r = try SSHConfig.addHost(ManagedSSHHost(alias: "z", hostname: "9.9.9.9", file: other), configPath: primary)
    #expect(r.path == other)
    #expect(read(other).contains("Host z\n  HostName 9.9.9.9"))
    #expect(!read(primary).contains("Host z"))
    #expect(throws: AppError.self) {
        try SSHConfig.addHost(ManagedSSHHost(alias: "y", hostname: "1.1.1.1", file: other), configPath: primary)
    }
}
