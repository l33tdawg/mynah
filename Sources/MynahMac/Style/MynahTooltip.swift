import SwiftUI

// MARK: - Tooltips
//
// The owner resolved a tension this app had been trading away screen by screen:
// every explanation in it earns its place — the RBAC essay cost a day to
// discover, the privacy claims are the product's whole argument — and all of it
// is noise once you already know. Hiding it loses the first reader; keeping it
// inline loses the tenth.
//
// So the long form moves onto hover, and hovering is switchable.
//
// **Two rules this file exists to keep.**
//
// 1. **A tooltip only ever elaborates.** Nothing may live here and nowhere else.
//    An owner on a trackpad, or using VoiceOver, or with the switch off, has no
//    hover at all — content that exists only on hover does not exist for them.
//    Load-bearing facts live on a screen: the privacy claims are in
//    `PrivacyView`, the long-form explanations are group captions.
// 2. **It is plain SwiftUI**, which is not an implementation detail. The system
//    tooltip cannot be styled and — like everything AppKit-backed — cannot be
//    rendered, and the tab strip stayed ugly for a week because nobody could
//    look at it. `MynahTooltipBubble` is internal so a harness can draw it.

private struct MynahShowsTooltipsKey: EnvironmentKey {
    /// On, because somebody meeting this app for the first time needs the
    /// explanations. Turning them off is a choice made once they do not.
    static let defaultValue = true
}

extension EnvironmentValues {
    /// Whether hover explanations appear. Set once, at the window root.
    var mynahShowsTooltips: Bool {
        get { self[MynahShowsTooltipsKey.self] }
        set { self[MynahShowsTooltipsKey.self] = newValue }
    }
}

/// The bubble itself.
///
/// Not `private`: a render harness composes this directly, because the modifier
/// below only shows it after a hover that `ImageRenderer` cannot perform. That
/// is the same concession `StandingFacts` makes and for the same reason — a
/// reconstruction of a bubble would drift from the real one, and then the render
/// would be confirming its own lookalike.
struct MynahTooltipBubble: View {
    let text: String

    var body: some View {
        Text(text)
            .mynahFont(.callout)
            .foregroundStyle(Palette.ink.primary)
            .fixedSize(horizontal: false, vertical: true)
            // Narrower than a settings caption on purpose. A tooltip is read in
            // one glance while the pointer is held still; at a paragraph's width
            // it becomes something you have to settle down to, which is the
            // thing this was built to take off the screen.
            .frame(maxWidth: 300, alignment: .leading)
            .padding(.horizontal, s4)
            .padding(.vertical, s3)
            .background(Palette.surface.overlay, in: RoundedRectangle.mynah(r.control))
            .mynahBorder(r.control)
            // The one shadow: this floats above content, and `.card` is the
            // token for something lifted off the page rather than drawn on it.
            .mynahShadow(.card)
    }
}

private struct MynahTooltipModifier: ViewModifier {
    let text: String

    @Environment(\.mynahShowsTooltips) private var isEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isShowing = false
    @State private var pending: Task<Void, Never>?

    func body(content: Content) -> some View {
        content
            .onHover { hovering in
                pending?.cancel()
                guard isEnabled else { isShowing = false; return }
                guard hovering else { isShowing = false; return }
                // A delay, because a tooltip that appears the instant the
                // pointer crosses a row fires on the way to somewhere else.
                // Cancelled on exit, so crossing three rows shows nothing.
                pending = Task {
                    try? await Task.sleep(for: .milliseconds(450))
                    guard !Task.isCancelled else { return }
                    isShowing = true
                }
            }
            .onDisappear { pending?.cancel() }
            .overlay(alignment: .bottomLeading) {
                if isShowing && isEnabled {
                    MynahTooltipBubble(text: text)
                        // Below the row rather than over it. A tooltip that
                        // covers the thing it explains makes the owner move the
                        // pointer to read it, which dismisses it.
                        .offset(y: 6)
                        .alignmentGuide(.bottom) { $0[.top] }
                        // It must not eat the hover that is showing it, nor a
                        // click meant for whatever is underneath.
                        .allowsHitTesting(false)
                        .transition(reduceMotion ? .identity : .opacity)
                        .zIndex(1)
                }
            }
            .mynahAnimation(Motion.fade, value: isShowing)
            // The text still exists for VoiceOver, which has no hover. This is
            // the half of rule 1 that a screen reader depends on.
            .accessibilityHint(text)
    }
}

extension View {

    /// Attaches an explanation that appears on hover, when the owner has hover
    /// explanations switched on.
    ///
    /// **Only ever elaboration.** If this string is the only place a fact is
    /// stated, it is in the wrong place — see the rules at the top of this file.
    func mynahTooltip(_ text: String?) -> some View {
        modifier(OptionalTooltip(text: text))
    }
}

/// A modifier rather than an `if` at the call site: branching would give the row
/// two identities and rebuild it, losing hover and selection state every time a
/// detail string changed.
private struct OptionalTooltip: ViewModifier {
    let text: String?

    func body(content: Content) -> some View {
        if let text, !text.isEmpty {
            content.modifier(MynahTooltipModifier(text: text))
        } else {
            content
        }
    }
}
