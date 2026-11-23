import Testing
import Foundation
@testable import ServerLife

// 0.16 → 0.39: teleportpanel.js (filter, expiry, login methods, pin),
// beams.js (Phase names, Start from), recordings.js (date range).

@Test func phaseNameRule() {
    #expect(BeamsUI.phaseNameProblem("") == "")
    #expect(BeamsUI.phaseNameProblem("go-dev") == "")
    #expect(BeamsUI.phaseNameProblem("a") == "")
    #expect(!BeamsUI.phaseNameProblem("Go").isEmpty)
    #expect(!BeamsUI.phaseNameProblem("-go").isEmpty)
    #expect(!BeamsUI.phaseNameProblem("go-").isEmpty)
    #expect(!BeamsUI.phaseNameProblem("go_dev").isEmpty)
    #expect(BeamsUI.phaseNameProblem(String(repeating: "a", count: 54)) == "")
    #expect(!BeamsUI.phaseNameProblem(String(repeating: "a", count: 55)).isEmpty)
    #expect(BeamsUI.phaseName("go@sha256:abc") == "go")
    #expect(BeamsUI.phaseName("go") == "go")
}

@MainActor @Test func startFromReadyPhasesOnly() {
    let p = TeleportProfile(proxy: "beams.example.com:443", cluster: "beams")
    let m = StartBeamModel(p: p, preselect: "go")
    m.applyPhases(TshList(ok: true, error: nil, items: [
        BeamPhase(name: "go", state: "ready"), BeamPhase(name: "py", state: "building"),
    ]))
    #expect(m.ready.map(\.name) == ["go"])
    #expect(m.waiting == 1)
    #expect(m.phase == "go")
    #expect(m.phaseNote.isEmpty)

    let none = StartBeamModel(p: p)
    none.applyPhases(TshList(ok: true, error: nil, items: []))
    #expect(none.phaseNote.hasPrefix("No Phases yet"))
    #expect(none.phase == "")

    let bad = StartBeamModel(p: p)
    bad.applyPhases(.failed("boom"))
    #expect(bad.phaseNote == "boom")
}

@MainActor @Test func beamTabIsBeamsWithoutPhases() {
    let px = "no-phases-\(UUID().uuidString).example.com:443"
    BeamPhaseLists.shared._setForTests(proxy: px, tab: .phases)
    #expect(BeamPhaseLists.shared.tab(for: px) == .beams)
}

@MainActor @Test func loginMethodChoices() {
    var m = Teleport.LoginMethods(ok: true, authType: "github")
    m.defaultConnector = "github"
    m.passwordless = true
    m.providers = [.init(name: "github", type: "github", display: "GitHub")]
    let c = LoginDialogModel.methodChoices(m)
    #expect(c.first?.value == "")
    #expect(c.first?.label == "The cluster's default (github)")
    #expect(c.map(\.value) == ["", "github", "local", "passwordless", "headless", "__other"])
    m.local = false
    #expect(!LoginDialogModel.methodChoices(m).map(\.value).contains("local"))
}

@MainActor @Test func expiringSoonWindow() {
    let now = 1_700_000_000_000.0
    func prof(_ minsLeft: Double, expired: Bool = false) -> TeleportProfile {
        TeleportProfile(proxy: "x:443", validUntil: TPText.isoString(ms: now + minsLeft * 60000), expired: expired)
    }
    #expect(TeleportPanel.expiringSoon(prof(30), now: now))
    #expect(!TeleportPanel.expiringSoon(prof(90), now: now))
    #expect(!TeleportPanel.expiringSoon(prof(30, expired: true), now: now))
    #expect(!TeleportPanel.expiringSoon(TeleportProfile(proxy: "x:443"), now: now))
}

@MainActor @Test func clusterFilter() {
    let q = Tags.compileQuery("lab")
    #expect(TeleportPanel.clusterMatchesFilter(name: "", cluster: "lab", proxy: "lab.example.com:443", user: "me", q))
    #expect(!TeleportPanel.clusterMatchesFilter(name: "", cluster: "prod", proxy: "prod.example.com:443", user: "me", q))
}

@MainActor @Test func pinSavesAndUnpinKeepsRecord() {
    let s = Store(dir: FileManager.default.temporaryDirectory.appendingPathComponent("sl-tui-sync-\(UUID().uuidString)"))
    TUIData.store = s
    defer { TUIData.store = .shared }
    let p = TeleportProfile(proxy: "lab.example.com:443", cluster: "lab", username: "me")
    #expect(!TeleportPanel.isPinned(p))
    TeleportPanel.togglePin(p)
    #expect(TeleportPanel.isPinned(p))
    #expect(TeleportPanel.savedRecordsFor(p).count == 1)
    TeleportPanel.togglePin(p)
    #expect(!TeleportPanel.isPinned(p))
    #expect(TeleportPanel.savedRecordsFor(p).count == 1)
}

@MainActor @Test func recordingDates() {
    let now = 1_700_000_000_000.0   // 2023-11-14T22:13:20Z
    #expect(RecordingsModel.dateDaysAgo(0, now: now) == "2023-11-14")
    #expect(RecordingsModel.dateDaysAgo(1, now: now) == "2023-11-13")
    #expect(RecordingsModel.dateDaysAgo(180, now: now) == "2023-05-18")
}
