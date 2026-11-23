import Foundation
import Testing
@testable import ServerLife

/// The 0.16 → 0.39 additions that are plain logic.
@MainActor @Suite struct Sidebar039PureTests {
    @Test func theProxyNoteIsOnlyShownWhenItSaysSomethingNew() {
        #expect(SBGroupMenuExtra.proxyNote(TeleportProfile(proxy: "lab.example.com:443", cluster: "lab")) == "(lab.example.com)")
        #expect(SBGroupMenuExtra.proxyNote(TeleportProfile(proxy: "https://u@lab:3080/web", cluster: "c")) == "(lab:3080)")
        #expect(SBGroupMenuExtra.proxyNote(TeleportProfile(proxy: "lab:443", cluster: "lab")) == nil)
        #expect(SBGroupMenuExtra.proxyNote(TeleportProfile(proxy: "lab:443", cluster: "")) == nil)
        #expect(SBGroupMenuExtra.proxyNote(nil) == nil)
    }

    @Test func installLabelsAreKeyValuePairsByLineOrComma() {
        let l = SBInstallTeleport.parseLabels("env=prod, team = db\njunk\nrole=a=b")
        #expect(l.map(\.0) == ["env", "team", "role"])
        #expect(l.map(\.1) == ["prod", "db", "a=b"])
    }

    @Test func aRecentCommandShowsItsFirstLineOnly() {
        #expect(SBCommandHistory.label("uptime") == "uptime")
        #expect(SBCommandHistory.label("df -h\nfree -m") == "df -h…")
        #expect(SBCommandHistory.label(String(repeating: "x", count: 70)) == String(repeating: "x", count: 60) + "…")
    }

    @Test func kubeClustersAreKeyedByTheirClusterAndName() {
        var k = ServerLife.Host(type: "kube", id: "kube:lab:prod", name: "prod")
        k.extra["kind"] = "kube"
        k.extra["teleportCluster"] = "lab"
        #expect(SBKube.isKubeHost(k))
        #expect(k.sbPrefKey == "kube:lab:prod")
        let n = sbNode("web")
        #expect(!SBKube.isKubeHost(n))
        #expect(n.sbPrefKey == n.prefKey)
    }
}

extension SidebarStoreSuites {
    @MainActor @Suite struct CommandHistoryTests {
        init() { _ = sbFreshStore() }

        @Test func historyIsMostRecentFirstDeduplicatedAndCapped() {
            for i in 0..<30 { SBCommandHistory.remember("c\(i)") }
            SBCommandHistory.remember("c5")
            let l = SBCommandHistory.list
            #expect(l.count == SBCommandHistory.max)
            #expect(l.first == "c5")
            #expect(l.filter { $0 == "c5" }.count == 1)
            #expect(l[1] == "c29")
        }
    }
}
