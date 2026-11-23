import SwiftUI

/// The `kube-browser` action: resolve a context to a spec and open the browser.
@MainActor
enum KubeBrowserOpen {
    static func fromAction(_ ctx: ActionContext) async -> Bool {
        false
    }
}
