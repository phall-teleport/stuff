import Foundation
import Testing
@testable import ServerLife

/// The kubeconfig editor's pure check (main.js `kubeconfig:check`'s warnings).
@Suite struct KubeConfigFilesTests {
    @Test func warnings() throws {
        let cfg = try KubeYAML.load("""
        apiVersion: v1
        kind: Config
        current-context: gone
        clusters:
        - name: c1
          cluster: {server: "https://10.0.0.1"}
        users:
        - name: u1
          user: {token: x}
        contexts:
        - name: good
          context: {cluster: c1, user: u1}
        - name: bad
          context: {cluster: c2, user: u2}
        """)
        #expect(KubeConfigFiles.warnings(cfg) == [
            "Context \"bad\" names cluster \"c2\", which this file does not have",
            "Context \"bad\" names user \"u2\", which this file does not have",
            "current-context \"gone\" is not one of the contexts in this file",
        ])
        #expect(KubeConfigFiles.warnings(["contexts": [["name": "a", "context": [:]]], "current-context": "a"]).isEmpty)
    }

    @MainActor @Test func onlyKnownFilesAreWritten() async {
        await #expect(throws: (any Error).self) { try await KubeConfigFiles.write(file: "/tmp/not-a-kubeconfig-serverlife-knows", text: "x") }
    }
}
