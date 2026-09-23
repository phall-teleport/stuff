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

/// Drives a hover popover: shows after a short delay so it doesn't flash while
/// the pointer scans the list, hides immediately on exit. `.help()` tooltips
/// don't fire reliably on rows that also carry tap/hover gestures, so we use
/// this instead.
final class HoverPopover: ObservableObject {
    @Published var shown = false
    private var work: DispatchWorkItem?

    func enter(delay: Double = 0.45) {
        work?.cancel()
        let w = DispatchWorkItem { [weak self] in self?.shown = true }
        work = w
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: w)
    }

    func exit() {
        work?.cancel(); work = nil
        shown = false
    }
}
