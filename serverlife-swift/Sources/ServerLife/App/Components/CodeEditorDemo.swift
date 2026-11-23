import SwiftUI

/// `dev-code-editor` — development only (not in any menu): the shared code
/// editor with sample YAML and ssh_config, for `--snapshot … --actions
/// dev-code-editor` and for owners checking how their text will look.
@MainActor
enum CodeEditorDemo {
    static let yaml = """
    # A Deployment
    apiVersion: apps/v1
    kind: Deployment
    metadata:
      name: "web"
      labels: {app: web, tier: 'front'}
      annotations:
        note: &a plain value # trailing comment
    spec:
      replicas: 3
      template:
        spec:
          containers:
            - name: web
              image: nginx:1.27
              args: [--port, "8080"]
              command:
                - sh
                - -c
                - |
                  echo "hello: world"
                  exec nginx
          extra: *a
    ---
    kind: ConfigMap
    """

    static let ssh = """
    # ~/.ssh/config
    Host web-* !web-test
      HostName 10.0.0.%h
      User deploy
      Port=2222
      IdentityFile "~/.ssh/id ed25519"
      ForwardAgnet yes

    Match host *.internal exec "test -f /tmp/x"
      ProxyJump bastion
    """

    static func install() {
        Actions.shared.register("dev-code-editor") { ctx in
            Modal.sheet(ctx.window, title: "Code editor", width: 900, height: 560, resizable: true) { handle in
                CodeEditorDemoView(handle: handle)
            }
        }
    }
}

private struct CodeEditorDemoView: View {
    let handle: ModalHandle
    @StateObject private var yaml = Local(CodeEditorDemo.yaml)
    @StateObject private var ssh = Local(CodeEditorDemo.ssh)

    var body: some View {
        DialogScaffold(title: "Code editor", subtitle: "YAML, ssh_config and read-only text", scroll: false) {
            HStack(spacing: 10) {
                CodeEditor(text: $yaml.value, language: .yaml, linter: { text in
                    guard let r = text.range(of: "replicas: 3") else { return [] }
                    let from = text.utf16.distance(from: text.startIndex, to: r.lowerBound)
                    return [CodeDiagnostic(from: from, to: from + 8, message: "spec.replicas: example lint message")]
                }, completer: { text, pos, explicit in
                    guard explicit else { return nil }
                    return CodeCompletions(from: pos, items: [.init(label: "apiVersion"), .init(label: "metadata")])
                })
                VStack(spacing: 10) {
                    CodeEditor(text: $ssh.value, language: .sshConfig)
                    YamlView(text: "Name:         web-1\nNamespace:    default\nStatus:       Running", language: .text)
                        .frame(height: 90)
                }
            }
        } footer: {
            Spacer()
            Button("Close") { handle.close() }.buttonStyle(.ghost).keyboardShortcut(.cancelAction)
        }
    }
}
