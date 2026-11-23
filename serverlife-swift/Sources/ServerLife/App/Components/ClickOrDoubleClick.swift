import SwiftUI

extension View {
    /// util.js `clickOrDblClick`: a single click that waits out the
    /// double-click window (`delay`, 300 ms) before it acts, so a double click
    /// runs only `double` — not `single` and then `double`. For rows where
    /// the two do different things (select vs open).
    func onClickOrDoubleClick(delay: Double = 0.3, single: @escaping () -> Void,
                              double: @escaping () -> Void) -> some View {
        modifier(ClickOrDoubleClick(delay: delay, single: single, double: double))
    }
}

private struct ClickOrDoubleClick: ViewModifier {
    let delay: Double
    let single: () -> Void
    let double: () -> Void
    @StateObject private var pending = Local<DispatchWorkItem?>(nil)

    func body(content: Content) -> some View {
        content
            .contentShape(Rectangle())
            .simultaneousGesture(TapGesture(count: 1).onEnded {
                if pending.value != nil { return }
                let w = DispatchWorkItem { [pending] in
                    MainActor.assumeIsolated {
                        pending.value = nil
                        single()
                    }
                }
                pending.value = w
                DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: w)
            })
            .simultaneousGesture(TapGesture(count: 2).onEnded {
                pending.value?.cancel()
                pending.value = nil
                double()
            })
    }
}
