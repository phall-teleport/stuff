import SwiftUI

/// Tiny per-view state holder used instead of `@State`.
///
/// With the macOS 27 SDK, SwiftUI's `@State` is implemented as a compiler
/// macro whose plugin ships only with full Xcode, not the Command Line Tools.
/// `@StateObject` is a plain property wrapper and builds everywhere, so local
/// flags (hover, disclosure) live in one of these.
final class LocalFlag: ObservableObject {
    @Published var on: Bool
    init(_ initial: Bool = false) { on = initial }
}
