import Testing
import Foundation
@testable import ServerLife

/// tests/sshoptions.test.mjs, against the hosts stand-in for main/sshoptions.js.
@MainActor @Suite struct HostsSSHOptionsTests {
    typealias S = HostsSSHOpts

    @Test func forwardsSocksJumpAndOptionsAreSharedFlags() {
        let o: JSON = ["localForwards": "5432:db.internal:5432", "remoteForwards": ["9000:localhost:3000"],
                       "dynamicForwards": "1080", "jumpHost": "ops@bastion", "extraOptions": "ServerAliveInterval 30"]
        let flags = ["-L", "5432:db.internal:5432", "-R", "9000:localhost:3000", "-D", "1080",
                     "-J", "ops@bastion", "-o", "ServerAliveInterval=30"]
        #expect(S.opensshArgs(o) == flags)
        #expect(S.tshArgs(o) == flags)
    }

    @Test func reasonInvitesAndRequestsAreTshFlags() {
        let o: JSON = ["reason": "INC-42 disk", "invite": "alice, bob", "requestMode": "resource",
                       "requestReason": "on call", "noResume": true]
        #expect(S.tshArgs(o) == ["--reason=INC-42 disk", "--invite=alice,bob",
                                 "--request-mode=resource", "--request-reason=on call", "--no-resume"])
        #expect(S.opensshArgs(o) == [])
        #expect(S.needsTsh(o))
        #expect(!S.needsTsh(["remoteForwards": ["1:a:1"]]))
    }

    @Test func badForwardsAreReported() {
        let e = S.normalize(["remoteForwards": "9000", "dynamicForwards": "abc", "localForwards": "1:h:99999"]).errors
        #expect(e.count == 3)
        #expect(e.joined(separator: "\n").contains("port:host:port"))
        #expect(S.normalize(["localForwards": "127.0.0.1:8080:[::1]:80"]).errors.isEmpty)
    }

    @Test func unknownValuesFallBack() {
        let o = S.normalize(["x11": "yes please", "requestMode": "always"]).options
        #expect(o.x11 == "off")
        #expect(o.requestMode == "")
        #expect(S.isEmpty([:]))
        #expect(!S.isEmpty(["x11": "untrusted"]))
    }

    @Test func summaryIsBrief() {
        #expect(S.summary(["x11": "trusted", "remoteForwards": "9000:localhost:3000", "invite": "alice"])
                == ["X11 trusted", "-R 9000:localhost:3000", "invites alice"])
    }

    @Test func copyCommandForTeleport() {
        let host: JSON = ["type": "teleport", "name": "bms-app-service", "hostname": "bms-app-service",
                          "cluster": "red-fire.beams.sh", "proxy": "red-fire.beams.sh:443"]
        let opts: JSON = ["x11": "untrusted", "localForwards": "15500:localhost:22", "reason": "it's a test", "invite": "alice"]
        #expect(S.commandLine(host: host, login: "root", options: opts)
                == "tsh --proxy=red-fire.beams.sh:443 ssh --cluster=red-fire.beams.sh -X -L 15500:localhost:22 '--reason=it'\\''s a test' --invite=alice root@bms-app-service")
    }

    @Test func copyCommandForConfigHost() {
        let host: JSON = ["type": "ssh", "alias": "ent", "configFile": "/Users/me/.ssh/extra config"]
        #expect(S.commandLine(host: host, login: "ubuntu", options: ["dynamicForwards": "1080", "jumpHost": "ops@bastion"])
                == "ssh -F '/Users/me/.ssh/extra config' -D 1080 -J ops@bastion ubuntu@ent")
    }

    @Test func noShell() {
        let o: JSON = ["noShell": true, "localForwards": "5432:db:5432"]
        #expect(!S.isEmpty(o))
        #expect(S.summary(o) == ["-L 5432:db:5432", "no shell (-N)"])
        #expect(S.commandLine(host: ["type": "ssh", "alias": "ent"], login: nil, options: o) == "ssh -L 5432:db:5432 -N ent")
        #expect(S.opensshArgs(o) == ["-L", "5432:db:5432"])
    }

    @Test func everyInterfaceAndSockets() {
        for o: JSON in [["localForwards": "*:8080:localhost:80"], ["remoteForwards": ":9000:localhost:3000"],
                        ["dynamicForwards": "*:1080"], ["localForwards": "8080:/var/run/app.sock"],
                        ["localForwards": "/tmp/local.sock:db.internal:5432"], ["localForwards": "/tmp/local.sock:/tmp/remote.sock"]] {
            #expect(S.normalize(o).errors.isEmpty)
        }
    }

    @Test func multiHopJump() {
        let c = S.normalize(["jumpHost": "bastion1,user@bastion2:2222"])
        #expect(c.errors.isEmpty)
        #expect(c.options.jumpHost == "bastion1,user@bastion2:2222")
        #expect(S.opensshArgs(c.options.json) == ["-J", "bastion1,user@bastion2:2222"])
        #expect(S.normalize(["jumpHost": "bastion1,,bastion2"]).errors.first?.contains("empty hop") == true)
    }

    @Test func unknownDirectiveIsAWarning() {
        let c = S.normalize(["extraOptions": "SeverAliveInterval=30"])
        #expect(c.errors.isEmpty)
        #expect(c.warnings.joined().contains("not a recognized ssh_config directive"))
        #expect(S.normalize(["extraOptions": "ServerAliveInterval=30"]).warnings.isEmpty)
    }

    @Test func shqQuotesOnlyWhatNeedsIt() {
        #expect(S.shq("plain-word") == "plain-word")
        #expect(S.shq("it's") == "'it'\\''s'")
    }
}

@MainActor @Suite struct HostsSyncUITests {
    @Test func brieflyAndMenuTitle() {
        #expect(SSHOptionsUI.briefly(nil) == "")
        #expect(SSHOptionsUI.briefly(["x11": "trusted", "jumpHost": "b", "noShell": true]) == "X11 trusted · via b · no shell (-N)")
        #expect(SSHOptionsUI.menuTitle(.init(defaultOptions: nil, presets: [])) == "SSH options")
    }

    @Test func addOptionLinesReplacesTheSameOption() {
        #expect(SSHPresets.addOptionLines("ServerAliveInterval=10\nFoo=1", [("ServerAliveInterval", "30")])
                == "ServerAliveInterval=30\nFoo=1")
        #expect(SSHPresets.addOptionLines("", [("ForwardAgent", "yes")], format: "config") == "ForwardAgent yes")
        #expect(SSHPresets.addOptionLines("ForwardAgent no", [("forwardagent", "yes")], format: "config") == "forwardagent yes")
    }

    @Test func sftpProfiles() {
        #expect(Profiles.kindLabel(["type": "sftp"]).lowercased().contains("sftp"))
        #expect(HostsPane.profileKind(["type": "sftp"]) == "sftp")
        #expect(HostsPane.profileKind(["type": "teleport"]) == "tsh")
        #expect(HostsPane.profileKind([:]) == "ssh")
    }

    @Test func configLabel() {
        #expect(AddServer.configLabel(nil) == "~/.ssh/config")
        #expect(AddServer.configLabel("/Users/me/.ssh/work.conf") == "~/.ssh/work.conf")
        #expect(AddServer.configLabel("/etc/ssh/ssh_config") == "/etc/ssh/ssh_config")
    }

    @Test func kubeKeysRename() {
        let v: JSON = ["kube:old": ["key": "kube:old", "x": 1], "other": ["kube:old", "y"]]
        let out = KubeHostKeys.renameKey(v, from: "kube:old", to: "kube:new")
        #expect(out["kube:old"].isNull)
        #expect(out["kube:new"]["key"].string == "kube:new")
        #expect(out["other"] == ["kube:new", "y"])
        let patch = KubeHostKeys.patch(settings: ["hostIcons": ["kube:old": "⭐"], "phaseJournal": ["kube:old": 1]],
                                       pairs: [("kube:old", "kube:new")])
        #expect(patch["hostIcons"]?["kube:new"].string == "⭐")
        #expect(patch["phaseJournal"] == nil)
    }

    @Test func paneSorting() {
        func h(_ name: String, _ labels: [String: String] = [:]) -> ServerLife.Host {
            ServerLife.Host(json: ["type": "teleport", "id": .string(name), "name": .string(name),
                        "labels": .object(labels.mapValues { .string($0) })])
        }
        let hosts = [h("web-2", ["env": "prod"]), h("db", ["env": "dev"]), h("web-1")]
        #expect(HostsPane.sortHosts(hosts, .init(mode: "name")).map(\.name) == ["db", "web-1", "web-2"])
        #expect(HostsPane.sortHosts(hosts, .init(mode: "name", desc: true)).map(\.name) == ["web-2", "web-1", "db"])
        // A host without the label sorts last.
        #expect(HostsPane.sortHosts(hosts, .init(mode: "label", labelKey: "env")).map(\.name) == ["db", "web-2", "web-1"])
        #expect(HostsPane.labelKeysIn(hosts) == ["env"])
        #expect(HostsPane.SortPref(mode: "label", labelKey: "env").value == "label:env")
    }

    @Test func paneKind() {
        let kube = ServerLife.Host(json: ["type": "teleport", "id": "kube:c:x", "name": "x", "kind": "kube"])
        let ssh = ServerLife.Host(json: ["type": "ssh", "id": "ssh:a", "alias": "a", "name": "a"])
        #expect(HostsHooks.inKind(kube, "kube") && !HostsHooks.inKind(kube, "ssh"))
        #expect(HostsHooks.inKind(ssh, "ssh") && HostsHooks.inKind(ssh, "all") && !HostsHooks.inKind(ssh, "kube"))
        #expect(HostsPane.leafOf("tsh:a::leaf")?.cluster == "leaf")
        #expect(HostsPane.leafOf("tsh:a") == nil)
    }
}
