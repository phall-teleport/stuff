import Testing
import Foundation
@testable import ServerLife

/// 0.16 → 0.39: free-space footer, connect-failure wording, pod sources.
@MainActor @Suite struct ExplorerSyncTests {
    @Test func parsesDfPosixOutput() {
        let out = """
        Filesystem     1024-blocks     Used Available Capacity Mounted on
        /dev/sda1         50633164 9876543  40756621      20% /
        """
        let d = XP.parseDf(out)
        #expect(d == XPDisk(free: 40756621 * 1024, total: 50633164 * 1024))
        #expect(XP.parseDf("") == nil)
        #expect(XP.parseDf("Filesystem 1024-blocks Used Available\n") == nil)
        #expect(XP.parseDf("h\nx y z w") == nil)
        #expect(XP.parseDf("h\nx 0 0 0 0% /") == nil)
    }

    @Test func diskBadgeLevels() {
        let ok = XP.diskBadge(XPDisk(free: 50, total: 100))
        #expect(ok.level == "")
        #expect(ok.text.hasSuffix(" · "))
        #expect(!ok.text.hasPrefix("⚠") && !ok.text.hasPrefix("⛔"))
        #expect(ok.tooltip == "50% free on this volume")
        let warn = XP.diskBadge(XPDisk(free: 15, total: 100))
        #expect(warn.level == "warn" && warn.text.hasPrefix("⚠ "))
        let bad = XP.diskBadge(XPDisk(free: 5, total: 100))
        #expect(bad.level == "danger" && bad.text.hasPrefix("⛔ "))
        #expect(bad.text.contains(" free of "))
        #expect(XP.diskBadge(XPDisk(free: 0, total: 0)).level == "")
    }

    @Test func localDiskSpaceAnswersForHome() {
        let d = XP.localDiskSpace(NSHomeDirectory())
        #expect(d != nil)
        if let d { #expect(d.total > 0 && d.free <= d.total) }
        #expect(XP.localDiskSpace("/no/such/dir/at/all") == nil)
    }

    @Test func explainConnectError() {
        #expect(XP.explainConnectError("ssh: handshake failed [mfa]") == "ssh: handshake failed (MFA may be required)")
        #expect(XP.explainConnectError("[mfa] not at the end") == "[mfa] not at the end")
        #expect(XP.explainConnectError("Connection refused") == "Connection refused")
        #expect(XP.explainConnectError(AppError("Denied", code: "mfa")) == "Denied (MFA may be required)")
        #expect(XP.explainConnectError(AppError("Denied [mfa]", code: "mfa")) == "Denied (MFA may be required)")
        #expect(XP.explainConnectError(AppError("Timed out")) == "Timed out")
    }

    @Test func kubeEntriesAndBase64() {
        let j: JSON = ["name": "etc", "path": "/etc", "type": "directory", "size": 4096, "mode": 493,
                       "modeString": "", "mtime": 1_700_000_000_000, "owner": .null, "group": .null]
        let e = XP.kubeEntry(j)
        #expect(e?.type == .directory && e?.path == "/etc" && e?.mode == 493 && e?.size == 4096)
        #expect(XP.kubeEntry(["path": "/x"]) == nil)
        let s = "héllo\n✓"
        #expect(XP.textFromB64(XP.b64FromText(s)) == s)
        #expect(XP.trimTrailingSlashes("/a/b//") == "/a/b")
    }

    @Test func kubeSpecFromAttachment() {
        #expect(XPKube.specFrom(KubeSpec(podName: "web-1"))?.podName == "web-1")
        #expect(XPKube.specFrom(true) == nil)
        #expect(XPKube.specFrom(nil) == nil)
    }
}
