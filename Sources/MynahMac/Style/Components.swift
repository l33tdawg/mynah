import AppKit
import SageVoiceCore
import SwiftUI

// MARK: - Owner-facing copy helpers

/// The words the owner reads, kept in one place so no screen invents its own.
///
/// Nothing in here may contain a product name for the memory layer, a protocol,
/// a status code, or an exception string. QuietType puts "SAGE", "CometBFT" and
/// `HTTP \(status)` in front of the person who bought the appliance; those words
/// belong in `os.Logger`.
enum MynahCopy {

    /// Who receives the owner's speech, in a name they would recognise.
    ///
    /// Keyed on the adapter's own identifier, which is what `BrainSetupOption`
    /// now carries. `"google"` and `"openai-compatible"` are legacy spellings
    /// kept so a choice stored by an older build still names a company rather
    /// than falling through to "the provider you chose".
    static func company(forBackend identifier: String) -> String? {
        switch identifier {
        case "ollama", "local", "lmstudio": return nil
        case "gemini", "google": return "Google"
        case "openai", "codex-cli": return "OpenAI"
        case "anthropic", "claude-code-cli": return "Anthropic"
        case "deepseek": return "DeepSeek"
        case "moonshot", "kimi": return "Kimi"
        case "groq": return "Groq"
        default: return "the provider you chose"
        }
    }

    /// "about 4.7 GB" — decimal units, matching how macOS reports storage.
    static func downloadSize(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useGB, .useMB]
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
    }

    /// The honest status line during a turn.
    ///
    /// Real turns are 18–29s and up to 77s on a big recall, and there is no
    /// determinate progress to report. Four sentences on a timer tell the truth;
    /// a percentage would be a lie and a spinner would imply a network call that
    /// is about to time out.
    static func thinkingLine(elapsed: TimeInterval) -> String {
        switch elapsed {
        case ..<8: return "Thinking…"
        case ..<22: return "Still thinking…"
        case ..<45: return "Looking through what it remembers."
        default: return "This one's a big recall — it can take up to a minute."
        }
    }

    /// Shown under the indicator on the owner's very first turn, once, never
    /// animated. Sets the expectation before the wait rather than during it.
    ///
    /// No number any more. It said twenty seconds, which was true of a local
    /// model on a Mac mini and is not true of an API one — measured turns now
    /// run three to nine seconds, and a search runs longer. A specific figure in
    /// the interface is a promise that goes stale the moment the owner changes
    /// their brain, and being told to expect twenty seconds and waiting four is
    /// its own small failure of trust.
    static let firstTurnExpectation = "The first answer takes a moment longer than the rest."

    /// "21s", "1m 14s". How long a turn took, in the smallest honest unit.
    ///
    /// Lives here rather than beside the transcript block that first needed it,
    /// because the floating panel reports the same number and two formatters
    /// would drift the moment one of them learned about hours.
    static func duration(_ seconds: TimeInterval) -> String {
        let whole = max(0, Int(seconds.rounded()))
        guard whole >= 60 else { return "\(whole)s" }
        return "\(whole / 60)m \(whole % 60)s"
    }

    // MARK: The floating panel
    //
    // The panel appears the moment the owner closes the window, which for most
    // people is the first time they meet it. So its resting line has to answer
    // "why is this here?" as well as "what is it doing?" — a panel that only
    // says "Listening" is a thing that appeared for no stated reason.

    /// The panel's second line when MYNAH is ready and nothing is in flight.
    ///
    /// Two facts, and no third. "It's on and waiting" is why the panel appeared;
    /// the destination is the one thing this product is about, and the panel is
    /// the only surface still on screen once the window is shut.
    ///
    /// Deliberately *not* "send it a voice note and watch here". The panel
    /// reports the conversation this app is holding; a note sent to the phone is
    /// answered by a separate process that nothing in this target can observe,
    /// so inviting that here would promise a narration that never arrives.
    static func floatingPanelResting(destination: String, staysOnDevice: Bool) -> String {
        staysOnDevice
            ? "It's on and waiting. Your words stay on this Mac."
            : "It's on and waiting. Your words go to \(destination)."
    }

    /// The panel's second line during start-up. `ConversationModel.Health` has
    /// no detail for this state because the window's health line sits directly
    /// above a composer that explains itself; the panel has no such neighbour.
    static let floatingPanelWaking = "It's getting ready. This only takes a moment."

    /// The panel's second line while the owner has answering paused. Deliberately
    /// not the window's wording — "or this window" names a window that, by the
    /// time anyone reads this, is closed.
    static let floatingPanelSleeping = "It won't answer your phone until you start it again."

    /// The panel's second line while speech is being captured.
    static let floatingPanelListening = "Go ahead — it's listening."
}

// MARK: - Divider

/// A hairline at the right colour, insettable from the leading edge like a
/// real list separator.
struct MynahDivider: View {
    var leadingInset: CGFloat = 0

    var body: some View {
        Rectangle()
            .fill(Palette.line.divider)
            .frame(height: 1)
            .padding(.leading, leadingInset)
    }
}

// MARK: - Buttons

/// Three buttons, all text-only.
///
/// Mac apps do not put icons in text buttons — that is a Windows and Android
/// convention, and QuietType's 75 `Label(` calls are one of the loudest
/// non-Apple tells in it.
enum MynahButtonKind: Sendable {
    /// The one commitment on a screen.
    case primary
    /// A second, equal-weight action.
    case secondary
    /// "Not now", "Later", "Skip", "Learn more". Every one of these must lead
    /// somewhere observable — a dead escape hatch is worse than none.
    case quiet
}

struct MynahButtonStyle: ButtonStyle {
    let kind: MynahButtonKind

    init(_ kind: MynahButtonKind) {
        self.kind = kind
    }

    func makeBody(configuration: Configuration) -> some View {
        Chrome(kind: kind, configuration: configuration)
    }

    // A `ButtonStyle` cannot hold `@State`, and hover is state, so the body is
    // a real view.
    private struct Chrome: View {
        let kind: MynahButtonKind
        let configuration: ButtonStyleConfiguration
        @State private var isHovering = false
        @Environment(\.isEnabled) private var isEnabled

        var body: some View {
            label
                .contentShape(RoundedRectangle.mynah(r.control))
                // Full Keyboard Access draws its ring on the *focus effect*
                // shape, which defaults to the view's bounds rectangle — square
                // corners over a 10pt continuous button. Stating it costs one
                // line and is the difference between a finished control and one
                // that only looks finished with a mouse.
                .contentShape(.focusEffect, RoundedRectangle.mynah(r.control))
                .scaleEffect(pressScale)
                .opacity(pressOpacity)
                .mynahAnimation(Motion.hair, value: configuration.isPressed)
                .mynahAnimation(Motion.fade, value: isHovering)
                .onHover { isHovering = $0 }
                .pointingHandCursor(isEnabled)
        }

        @ViewBuilder
        private var label: some View {
            switch kind {
            case .primary where !isEnabled:
                // A real disabled recipe, not two alphas on the enabled colours.
                // `primaryFill @ 0.32` with `primaryInk @ 0.55` resolved to
                // #DBDBDC on #AFAFB1 — 1.58:1, an invisible label. And this is
                // the state of "Continue" on the brain stage before anything is
                // picked: the first control in the product, on the screen that
                // decides where a person's speech goes.
                configuration.label
                    .mynahFont(.title3)
                    .foregroundStyle(Palette.ink.secondary)
                    .padding(.horizontal, s6)
                    .padding(.vertical, 10)
                    .frame(minWidth: 132)
                    .background(Palette.surface.well, in: RoundedRectangle.mynah(r.control))
                    // The shape still has to read as a button, or a disabled
                    // primary looks like a paragraph of grey text.
                    .mynahBorder(r.control)

            case .primary:
                configuration.label
                    .mynahFont(.title3)
                    .foregroundStyle(Palette.button.primaryInk)
                    .padding(.horizontal, s6)
                    .padding(.vertical, 10)
                    .frame(minWidth: 132)
                    .background(primaryFill, in: RoundedRectangle.mynah(r.control))

            case .secondary:
                configuration.label
                    .mynahFont(.title3)
                    // A named token rather than an alpha on the enabled colour,
                    // for the same reason the primary stopped doing that: an
                    // opacity is a guess at a contrast ratio.
                    .foregroundStyle(isEnabled ? Palette.ink.primary : Palette.ink.secondary)
                    .padding(.horizontal, s6)
                    .padding(.vertical, 10)
                    .background(
                        configuration.isPressed
                            ? Palette.ink.primary.opacity(0.05)
                            : Palette.surface.raised,
                        in: RoundedRectangle.mynah(r.control)
                    )
                    .mynahBorder(r.control, isHovering && isEnabled ? Palette.line.strong : Palette.line.hairline)

            case .quiet:
                configuration.label
                    .mynahFont(.body)
                    .foregroundStyle(quietInk)
                    .padding(.horizontal, s3)
                    .padding(.vertical, 6)
            }
        }

        /// A disabled quiet button used to render identically to a working one —
        /// no dimming, no press feedback, no cursor change beyond the hand that
        /// `pointingHandCursor(isEnabled)` already suppresses. The composer's
        /// Send button is a quiet button, so with an empty draft it looked
        /// exactly as it does when it works and clicking did nothing.
        ///
        /// `tertiary` is right here and only here: a dimmed two-word control is
        /// a mark, not a sentence.
        private var quietInk: Color {
            guard isEnabled else { return Palette.ink.tertiary }
            return isHovering ? Palette.ink.primary : Palette.ink.secondary
        }

        private var primaryFill: Color {
            configuration.isPressed
                ? Palette.button.primaryFillPressed
                : Palette.button.primaryFill
        }

        /// macOS press feedback is about a 2.5% shrink and a 10% fade. QuietType
        /// uses 1.5% and 28% — one invisible, the other far too loud.
        private var pressScale: CGFloat {
            guard isEnabled, kind != .quiet else { return 1 }
            return configuration.isPressed ? 0.975 : 1
        }

        private var pressOpacity: Double {
            guard isEnabled else { return 1 }
            return configuration.isPressed ? 0.90 : 1
        }
    }
}

extension ButtonStyle where Self == MynahButtonStyle {
    static func mynah(_ kind: MynahButtonKind) -> MynahButtonStyle { MynahButtonStyle(kind) }
    static var mynahPrimary: MynahButtonStyle { MynahButtonStyle(.primary) }
    static var mynahSecondary: MynahButtonStyle { MynahButtonStyle(.secondary) }
    static var mynahQuiet: MynahButtonStyle { MynahButtonStyle(.quiet) }
}

/// The button most call sites want: a title, a kind, an action.
struct MynahButton: View {
    let title: String
    var kind: MynahButtonKind = .primary
    var isEnabled: Bool = true
    /// Makes Return activate this button.
    ///
    /// On a Mac, Return activates the default button. Onboarding shipped with
    /// none: five screens where the one key everybody presses did nothing at
    /// all, which is what makes a flow read as a wizard rather than an app. It
    /// composes with `isEnabled` — SwiftUI will not fire a disabled default
    /// action — and there must never be two on one screen.
    var isDefault: Bool = false
    let action: () -> Void

    init(
        _ title: String,
        kind: MynahButtonKind = .primary,
        isEnabled: Bool = true,
        isDefault: Bool = false,
        action: @escaping () -> Void
    ) {
        self.title = title
        self.kind = kind
        self.isEnabled = isEnabled
        self.isDefault = isDefault
        self.action = action
    }

    var body: some View {
        Button(action: action) { Text(title) }
            .buttonStyle(.mynah(kind))
            .disabled(!isEnabled)
            .modifier(DefaultActionKey(isOn: isDefault))
    }
}

/// `.keyboardShortcut(.defaultAction)` applied conditionally.
///
/// A modifier rather than an `if` in the body: branching would give the button
/// two identities, and SwiftUI would rebuild it — losing hover and press state
/// every time `isDefault` changed.
private struct DefaultActionKey: ViewModifier {
    let isOn: Bool

    func body(content: Content) -> some View {
        if isOn {
            content.keyboardShortcut(.defaultAction)
        } else {
            content
        }
    }
}

/// The standard bottom row of a stage or sheet.
///
/// The escape hatch sits on the far side of the row from the commitment, so
/// "Not now" is never a mis-click away from "Continue". `helper` is where the
/// reason a disabled primary is disabled goes — a greyed button with no
/// explanation is a dead end.
struct ActionRow<Trailing: View>: View {
    var quietTitle: String?
    var quietAction: (() -> Void)?
    var helper: String?
    @ViewBuilder var trailing: Trailing

    init(
        quietTitle: String? = nil,
        quietAction: (() -> Void)? = nil,
        helper: String? = nil,
        @ViewBuilder trailing: () -> Trailing
    ) {
        self.quietTitle = quietTitle
        self.quietAction = quietAction
        self.helper = helper
        self.trailing = trailing()
    }

    var body: some View {
        HStack(alignment: .center, spacing: s4) {
            if let quietTitle, let quietAction {
                MynahButton(quietTitle, kind: .quiet, action: quietAction)
            }
            Spacer(minLength: s6)
            if let helper {
                // `secondary`, not `tertiary`: this is the only explanation for
                // a disabled Continue, so it is a sentence the owner has to act
                // on rather than a decorative mark.
                //
                // Lowest layout priority in the row. It is prose, so it can wrap
                // to a second line; the buttons cannot, and when this text won
                // the negotiation the result was a Connect screen where "Check
                // this key" wrapped mid-phrase and "Back" was compressed to a
                // blank white rectangle — a control the owner could still click
                // and could no longer read.
                Text(helper)
                    .mynahFont(.callout)
                    .foregroundStyle(Palette.ink.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .multilineTextAlignment(.trailing)
                    .layoutPriority(-1)
            }
            // Buttons keep their intrinsic width. A squeezed label is not a
            // smaller button, it is an unreadable one.
            trailing
                .fixedSize(horizontal: true, vertical: false)
                .layoutPriority(1)
        }
    }
}

// MARK: - Card

/// How much air a card carries. Top-level rather than nested in `MynahCard` so
/// the modifier form can name it without pinning a generic parameter.
enum MynahCardDensity: Sendable {
    case compact
    case standard
    case hero

    var padding: CGFloat {
        switch self {
        case .compact: return s5
        case .standard: return s6
        case .hero: return s7
        }
    }
}

/// A card sits on the page at `surface.raised` with a hairline and, unless the
/// owner can pick it up, no shadow. That restraint is what separates a
/// considered layout from a bevelled one.
struct MynahCard<Content: View>: View {
    typealias Density = MynahCardDensity

    var density: Density = .standard
    /// Interactive cards — draggable, selectable — earn `shadow.card`.
    var isInteractive: Bool = false
    @ViewBuilder var content: Content

    init(
        density: Density = .standard,
        isInteractive: Bool = false,
        @ViewBuilder content: () -> Content
    ) {
        self.density = density
        self.isInteractive = isInteractive
        self.content = content()
    }

    var body: some View {
        content
            .padding(density.padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Palette.surface.raised, in: RoundedRectangle.mynah(r.card))
            .mynahBorder(r.card)
            .modifier(OptionalCardShadow(isOn: isInteractive))
    }
}

private struct OptionalCardShadow: ViewModifier {
    let isOn: Bool

    func body(content: Content) -> some View {
        if isOn {
            content.mynahShadow(.card)
        } else {
            content
        }
    }
}

extension View {
    /// Card chrome as a modifier, for content that already owns its own stack.
    func mynahCard(density: MynahCardDensity = .standard, isInteractive: Bool = false) -> some View {
        padding(density.padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Palette.surface.raised, in: RoundedRectangle.mynah(r.card))
            .mynahBorder(r.card)
            .modifier(OptionalCardShadow(isOn: isInteractive))
    }

    /// `.toggleStyle(.switch)` with the accent tint. QuietType tints every
    /// toggle `.primary`, so an "on" switch is the same colour as a disabled one.
    func mynahToggle() -> some View {
        toggleStyle(.switch).tint(Palette.accent.fill)
    }
}

// MARK: - Section header

/// The `.eyebrow` kicker that groups rows. Settings rows carry no leading
/// icons; the header does the categorising.
struct SectionHeader: View {
    let title: String

    init(_ title: String) {
        self.title = title
    }

    var body: some View {
        Text(title)
            .mynahFont(.eyebrow)
            // A group heading is read, not decorative — and at 10pt it is the
            // least forgiving size in the scale. `secondary` still sits two
            // steps below the row titles it introduces.
            .foregroundStyle(Palette.ink.secondary)
            .padding(.top, s6)
            .padding(.bottom, s4)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityAddTraits(.isHeader)
    }
}

// MARK: - Status

/// State is a 6pt dot, never a `checkmark.circle.fill`. The word beside it
/// already says "Ready"; a glyph restating it is noise, and a red triangle
/// makes a recoverable situation feel like a crash.
enum MynahTone: Sendable, CaseIterable {
    case neutral
    case good
    case caution
    case critical
    case accent

    var ink: Color {
        switch self {
        case .neutral: return Palette.ink.secondary
        case .good: return Palette.state.good
        case .caution: return Palette.state.caution
        case .critical: return Palette.state.critical
        case .accent: return Palette.accent.ink
        }
    }

    var wash: Color {
        switch self {
        case .neutral: return Palette.surface.well
        case .good: return Palette.state.goodWash
        case .caution: return Palette.state.cautionWash
        case .critical: return Palette.state.criticalWash
        case .accent: return Palette.accent.wash
        }
    }
}

struct StatusDot: View {
    var tone: MynahTone = .neutral
    var size: CGFloat = 6

    init(_ tone: MynahTone = .neutral, size: CGFloat = 6) {
        self.tone = tone
        self.size = size
    }

    var body: some View {
        Circle()
            .fill(tone == .neutral ? Palette.ink.tertiary : tone.ink)
            .frame(width: size, height: size)
    }
}

/// A small chip. Carries a dot only when it is reporting state.
struct StatusPill: View {
    let text: String
    var tone: MynahTone = .neutral
    var showsDot: Bool = true

    init(_ text: String, tone: MynahTone = .neutral, showsDot: Bool = true) {
        self.text = text
        self.tone = tone
        self.showsDot = showsDot
    }

    var body: some View {
        HStack(spacing: s3) {
            if showsDot { StatusDot(tone) }
            Text(text)
                .mynahFont(.label)
                .foregroundStyle(tone == .neutral ? Palette.ink.secondary : tone.ink)
        }
        .padding(.horizontal, s3)
        .padding(.vertical, s2)
        .background(tone.wash, in: RoundedRectangle.mynah(r.chip))
    }
}

/// One line in a status list. A status list is a list — rows separated by
/// dividers — not a grid of cards. QuietType wraps five one-line rows in five
/// invisible boxes inside a sixth.
struct StatusLine: View {
    let title: String
    var value: String?
    var tone: MynahTone = .neutral

    init(_ title: String, value: String? = nil, tone: MynahTone = .neutral) {
        self.title = title
        self.value = value
        self.tone = tone
    }

    var body: some View {
        HStack(spacing: s3) {
            StatusDot(tone)
            Text(title).mynahFont(.body).foregroundStyle(Palette.ink.primary)
            Spacer(minLength: s5)
            if let value {
                Text(value)
                    .mynahFont(.bodyEmphasis)
                    .foregroundStyle(Palette.ink.secondary)
            }
        }
        .padding(.vertical, s4)
    }
}

// MARK: - Progress rail

/// The onboarding progress indicator.
///
/// Order comes from the caller's fixed list and nothing else. QuietType computes
/// its stage from the first unmet condition, so a brand-new owner's opening
/// screen is a demand to install a consensus node — and a background check
/// flipping a flag can throw them backwards mid-flow.
///
/// No connecting line, no chevrons, no percentage bar. Weight does not change
/// between states either: swapping `.medium` for `.semibold` reflows the whole
/// row on every advance.
struct ProgressRail: View {
    let titles: [String]
    let currentIndex: Int

    init(titles: [String], currentIndex: Int) {
        self.titles = titles
        self.currentIndex = currentIndex
    }

    var body: some View {
        HStack(spacing: s6) {
            ForEach(Array(titles.enumerated()), id: \.offset) { index, title in
                HStack(spacing: s3) {
                    Circle()
                        .fill(dotColor(index))
                        .frame(width: index == currentIndex ? 8 : 6, height: index == currentIndex ? 8 : 6)
                    Text(title)
                        .mynahFont(.label)
                        .foregroundStyle(nameColor(index))
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel(accessibilityLabel(index, title))
            }
        }
        .frame(height: 44)
        .mynahAnimation(Motion.snap, value: currentIndex)
    }

    private func dotColor(_ index: Int) -> Color {
        if index == currentIndex { return Palette.accent.fill }
        return index < currentIndex ? Palette.ink.secondary : Palette.ink.quaternary
    }

    private func nameColor(_ index: Int) -> Color {
        if index == currentIndex { return Palette.ink.primary }
        return index < currentIndex ? Palette.ink.secondary : Palette.ink.tertiary
    }

    private func accessibilityLabel(_ index: Int, _ title: String) -> String {
        if index == currentIndex { return "\(title), step \(index + 1) of \(titles.count), current" }
        return index < currentIndex ? "\(title), done" : "\(title), not started"
    }
}

// MARK: - Scroll edges

/// The 3% top-and-bottom fade a chromeless scroll area needs so clipped content
/// reads as "there is more" rather than "this is broken".
///
/// A free-standing enum rather than a static on `StageShell`, which is generic
/// and therefore cannot hold one.
enum MynahScrollEdgeFade {
    static let vertical = LinearGradient(
        stops: [
            .init(color: .clear, location: 0),
            .init(color: .black, location: 0.03),
            .init(color: .black, location: 0.97),
            .init(color: .clear, location: 1)
        ],
        startPoint: .top,
        endPoint: .bottom
    )
}

// MARK: - Stage shell

/// The onboarding container: rail, hero glyph, one display title, one capped
/// paragraph, the stage's own content, and the action row.
///
/// The page *is* the card — there is no panel behind the column. QuietType's
/// two-column layout puts a SwiftUI drawing of a Mac window next to the actual
/// Mac window, which is a picture of software sitting beside the software.
struct StageShell<Content: View, Actions: View>: View {
    let stageTitles: [String]
    let currentIndex: Int
    var glyph: String?
    let title: String
    var subtitle: String?
    @ViewBuilder var content: Content
    @ViewBuilder var actions: Actions

    init(
        stageTitles: [String],
        currentIndex: Int,
        glyph: String? = nil,
        title: String,
        subtitle: String? = nil,
        @ViewBuilder content: () -> Content,
        @ViewBuilder actions: () -> Actions
    ) {
        self.stageTitles = stageTitles
        self.currentIndex = currentIndex
        self.glyph = glyph
        self.title = title
        self.subtitle = subtitle
        self.content = content()
        self.actions = actions()
    }

    var body: some View {
        VStack(spacing: 0) {
            // The same two frames the action row carries. Without them the rail
            // centres at its own natural width — about 380pt for five names —
            // inside a `VStack` that centres by default, so its leading edge
            // landed ~70pt to the right of the display title underneath it. The
            // first thing on the page lined up with nothing below it.
            ProgressRail(titles: stageTitles, currentIndex: currentIndex)
                .frame(maxWidth: MynahWidth.stageColumn, alignment: .leading)
                .frame(maxWidth: .infinity)
                .padding(.bottom, s9)

            // Top-aligned, scrolled when it doesn't fit.
            //
            // It used to centre, and that put an arbitrary gap under the rail:
            // the slack is whatever the viewport has left over, so a short stage
            // floated a long way down while a tall one sat tight, and neither
            // looked deliberate. With the action row pinned at the bottom, all
            // of that space collects in one place with nothing in it.
            //
            // Not `ViewThatFits(in: .vertical)`: inside a `VStack` between two
            // `Spacer`s it is proposed more height than it is finally given, so
            // a four-option brain stage measures as fitting and then renders
            // clipped with no way to reach the rest. Measuring against the real
            // viewport is the only version that cannot lie.
            GeometryReader { proxy in
                ScrollView {
                    column
                        .frame(maxWidth: .infinity)
                        .frame(minHeight: proxy.size.height, alignment: .top)
                }
                .scrollIndicators(.automatic)
                .scrollBounceBehavior(.basedOnSize)
                // A fade rather than a hairline. The stage has no chrome — the
                // transparent titlebar exists so it doesn't — and a divider
                // above the scroll area would reintroduce exactly the wizard
                // strip that was designed out. Without either, a brain stage
                // with five cards hard-clips one mid-height at both edges with
                // nothing saying the content continues.
                .mask(MynahScrollEdgeFade.vertical)
            }

            // Outside the scroll view on purpose. A stage with five brain
            // options is taller than the window, and a Continue button the owner
            // has to discover by scrolling is a Continue button they will not
            // find. Pinning it also gives every stage the same button position,
            // which is what stops the flow feeling like four unrelated screens.
            actions
                .frame(maxWidth: MynahWidth.stageColumn, alignment: .leading)
                .frame(maxWidth: .infinity)
                .padding(.top, s7)
        }
        .padding(.horizontal, s9)
        .padding(.top, s9)
        .padding(.bottom, s8)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Palette.surface.canvas)
    }

    /// The mark on the left, everything that reads on the right.
    ///
    /// One narrow column centred in a window twice its width left the whole
    /// setup flow as a strip of prose with empty canvas either side, and the
    /// glyph stacked above the title pushed the first sentence a long way down
    /// the page. Putting the mark beside the words instead uses the width the
    /// window already has, and lets the title start at the top where it is read.
    ///
    /// The mark column is a fixed width rather than a fraction so the content
    /// begins at the same place on every stage — one that slides between screens
    /// reads as a layout unsure of itself.
    private var column: some View {
        HStack(alignment: .top, spacing: s8) {
            if let glyph {
                HeroGlyph(glyph)
                    .frame(width: MynahWidth.stageMarkColumn, alignment: .leading)
            }

            VStack(alignment: .leading, spacing: 0) {
                Text(title)
                    .mynahFont(.display)
                    .foregroundStyle(Palette.ink.primary)
                    .fixedSize(horizontal: false, vertical: true)
                if let subtitle {
                    Spacer().frame(height: s4)
                    Text(subtitle)
                        .mynahFont(.body)
                        .foregroundStyle(Palette.ink.secondary)
                        .mynahProse()
                }
                Spacer().frame(height: s8)
                content
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: MynahWidth.stageColumn, alignment: .leading)
        .frame(maxWidth: .infinity)
    }
}

// MARK: - Option card

/// One way of getting a brain, rendered so the owner can tell at a glance where
/// their words would go.
///
/// Nothing is preselected, ever. `BrainSetupSelection`'s initialiser is internal
/// precisely so nothing can choose on the owner's behalf; a UI that quietly
/// highlights a default would defeat that from the outside.
struct OptionCard: View {
    let option: BrainSetupOption
    let isSelected: Bool
    let isRecommended: Bool
    let namespace: Namespace.ID
    let action: () -> Void

    @State private var isHovering = false

    init(
        option: BrainSetupOption,
        isSelected: Bool,
        isRecommended: Bool,
        namespace: Namespace.ID,
        action: @escaping () -> Void
    ) {
        self.option = option
        self.isSelected = isSelected
        self.isRecommended = isRecommended
        self.namespace = namespace
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: s5) {
                GlyphWell(glyphName, isActive: isSelected)
                VStack(alignment: .leading, spacing: s2) {
                    nameRow
                    Text(option.summary)
                        .mynahFont(.callout)
                        .foregroundStyle(bodyInk)
                        .frame(maxWidth: MynahWidth.cardSummary, alignment: .leading)
                        .fixedSize(horizontal: false, vertical: true)
                        .multilineTextAlignment(.leading)
                    requirementLine.padding(.top, s1)
                    if let reason = option.availability.reason {
                        // Unavailable options are not hidden and not greyed into
                        // illegibility: "needs 8.6 GB, this Mac has 4.3 GB" tells
                        // the owner what to buy. Hiding the row tells them nothing.
                        Text(reason)
                            .mynahFont(.label)
                            .foregroundStyle(Palette.ink.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.top, s1)
                    }
                }
                Spacer(minLength: s4)
                if option.isAvailable { selectionMark }
            }
            .padding(s6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(RoundedRectangle.mynah(r.card))
            .contentShape(.focusEffect, RoundedRectangle.mynah(r.card))
        }
        .buttonStyle(.plain)
        .disabled(!option.isAvailable)
        .background {
            if isSelected {
                RoundedRectangle.mynah(r.card)
                    .fill(Palette.accent.wash)
                    .matchedGeometryEffect(id: "choice.fill", in: namespace)
            } else {
                RoundedRectangle.mynah(r.card).fill(Palette.surface.raised)
            }
        }
        .overlay {
            if isSelected {
                RoundedRectangle.mynah(r.card)
                    .strokeBorder(Palette.accent.fill, lineWidth: 1)
                    .matchedGeometryEffect(id: "choice.border", in: namespace)
            } else {
                RoundedRectangle.mynah(r.card)
                    .strokeBorder(borderColor, lineWidth: 1)
            }
        }
        .onHover { isHovering = $0 && option.isAvailable }
        .pointingHandCursor(option.isAvailable)
        .mynahAnimation(Motion.snap, value: isSelected)
        .mynahAnimation(Motion.fade, value: isHovering)
        // The label is a composite of a glyph well and four `Text`s, which
        // VoiceOver reduced to "button" with no title at all — seven unlabelled
        // buttons on the one screen that decides where a person's speech goes.
        // Combined and named explicitly, with the privacy answer as the value
        // because that is the fact the screen exists to convey.
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityTitle)
        .accessibilityValue(accessibilityDestination)
        .accessibilityAddTraits(
            isSelected ? AccessibilityTraits([.isButton, .isSelected]) : AccessibilityTraits.isButton
        )
    }

    private var accessibilityTitle: String {
        var parts = [option.label]
        if isRecommended && option.isAvailable { parts.append("Recommended") }
        parts.append(option.summary)
        if let reason = option.availability.reason { parts.append(reason) }
        return parts.joined(separator: ". ")
    }

    private var accessibilityDestination: String {
        if option.keepsWordsOnDevice { return "Stays on this Mac" }
        guard let company = MynahCopy.company(forBackend: option.backendIdentifier) else {
            return "Sends your words off this Mac"
        }
        return "Sends your words to \(company)"
    }

    /// Name, recommendation marker and privacy badge on one line when they fit,
    /// on two when they do not.
    ///
    /// Both candidates pin their text to a single line, which is what makes
    /// `ViewThatFits` honest here: a wrapping `Text` always "fits" by growing
    /// taller, so the fallback would never fire and a label like "Claude Code —
    /// already signed in" would wrap around the badge sitting beside it.
    private var nameRow: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: s3) {
                titleText.lineLimit(1)
                recommendationMark
                privacyBadge.lineLimit(1)
            }
            VStack(alignment: .leading, spacing: s2) {
                HStack(spacing: s3) {
                    titleText
                    recommendationMark
                }
                privacyBadge
            }
        }
    }

    private var titleText: some View {
        Text(option.label)
            // An unavailable option steps down one level, not two. The spec's
            // own rule is "not greyed into illegibility", and `tertiary` on a
            // card is 2.4:1 — which would hide the name of the very option
            // whose reason the owner is being asked to read.
            .foregroundStyle(option.isAvailable ? Palette.ink.primary : Palette.ink.secondary)
            .mynahFont(.title2)
            .fixedSize(horizontal: false, vertical: true)
            .multilineTextAlignment(.leading)
    }

    @ViewBuilder
    private var recommendationMark: some View {
        if isRecommended && option.isAvailable {
            // One singular sparkle. Not a star, not a badge, not "RECOMMENDED"
            // in caps, and it does not pulse.
            Image(systemName: "sparkle")
                .mynahIcon(.inline)
                .foregroundStyle(Palette.accent.ink)
                .accessibilityLabel("Recommended")
        }
    }

    @ViewBuilder
    private var privacyBadge: some View {
        if option.keepsWordsOnDevice {
            HStack(spacing: s3) {
                StatusDot(.good)
                Text("Stays on this Mac")
                    .mynahFont(.label)
                    .foregroundStyle(Palette.ink.secondary)
            }
        } else if let company = MynahCopy.company(forBackend: option.backendIdentifier) {
            Text("Sends your words to \(company)")
                .mynahFont(.label)
                .foregroundStyle(Palette.state.caution)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// What the owner still has to do. Every line here is a sentence they act
    /// on, so it is `secondary` ink — `tertiary` is 2.4:1 on a raised card and
    /// these were 11pt.
    @ViewBuilder
    private var requirementLine: some View {
        switch option.requirement {
        case .apiKey:
            Text("Needs a key you paste in the next step")
                .mynahFont(.label)
                .foregroundStyle(Palette.ink.secondary)
        case .signIn:
            Text("Needs one sign-in — no key, no card")
                .mynahFont(.label)
                .foregroundStyle(Palette.ink.secondary)
        case .download:
            if let bytes = option.approximateDownloadBytes {
                HStack(spacing: s2) {
                    Text("Needs a")
                        .mynahFont(.label)
                        .foregroundStyle(Palette.ink.secondary)
                    Text(MynahCopy.downloadSize(bytes))
                        .mynahFont(.mono)
                        .foregroundStyle(Palette.ink.secondary)
                    // Not "Downloads … once": nothing in this product performs
                    // that download, and a card that promises one is how an
                    // owner ends up waiting for a file that was never fetched.
                    Text("download")
                        .mynahFont(.label)
                        .foregroundStyle(Palette.ink.secondary)
                }
            }
        case .nothing:
            EmptyView()
        }
    }

    private var selectionMark: some View {
        ZStack {
            if isSelected {
                Circle().fill(Palette.accent.fill)
                Image(systemName: "checkmark")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Palette.accent.onFill)
            } else {
                Circle().strokeBorder(Palette.line.strong, lineWidth: 1.5)
            }
        }
        .frame(width: 20, height: 20)
    }

    /// The summary says where the words would go and what it costs. That is
    /// true whether or not the option can be picked today, so it stays legible.
    private var bodyInk: Color { Palette.ink.secondary }

    private var borderColor: Color {
        isHovering ? Palette.line.strong : Palette.line.hairline
    }

    /// Never a lock or a shield for "private", never a warning triangle for
    /// "cloud". Security theatre for one, an implied crash for the other.
    private var glyphName: String {
        option.keepsWordsOnDevice ? "laptopcomputer" : "arrow.up.forward.app"
    }
}

/// The whole choice column, owning the `Namespace` so the accent border can
/// travel between cards. Selection is `nil` until the owner clicks.
struct OptionCardList: View {
    let options: [BrainSetupOption]
    let recommendedID: BrainSetupOptionID?
    @Binding var selection: BrainSetupOptionID?

    @Namespace private var namespace

    init(
        options: [BrainSetupOption],
        recommendedID: BrainSetupOptionID?,
        selection: Binding<BrainSetupOptionID?>
    ) {
        self.options = options
        self.recommendedID = recommendedID
        self._selection = selection
    }

    var body: some View {
        VStack(spacing: s4) {
            ForEach(options) { option in
                OptionCard(
                    option: option,
                    isSelected: selection == option.id,
                    isRecommended: recommendedID == option.id,
                    namespace: namespace
                ) {
                    selection = option.id
                }
            }
        }
        .frame(maxWidth: MynahWidth.stageColumn)
    }
}

// MARK: - Key field

/// What the key field is currently saying. Driven by `BrainKeyValidator.Verdict`
/// and `APIKeyOnboarding.shapeProblem(of:expecting:)`, both of which already
/// produce owner-readable sentences — the view never composes its own.
enum KeyFieldState: Equatable {
    /// Helper line is the provider's own instructions.
    case idle(helper: String)
    /// Caught offline, as they type: a pasted URL, a whole `export` line, the
    /// wrong provider's key.
    case shapeProblem(String)
    case checking(String)
    case rejected(String)
    case accepted(String)
}

/// Pasting an API key.
///
/// The focus ring here is the app's only one and it matters more than it looks:
/// QuietType has zero `FocusState` in 14,556 lines, so a keyboard user is
/// invisible in it.
struct KeyField: View {
    var label: String = "API key"
    @Binding var text: String
    var state: KeyFieldState
    /// A `QuietButton` naming the fix — "Get a key from Anthropic", "Try again".
    var fixTitle: String?
    var fix: (() -> Void)?
    var onSubmit: (() -> Void)?

    @FocusState private var isFocused: Bool

    init(
        label: String = "API key",
        text: Binding<String>,
        state: KeyFieldState,
        fixTitle: String? = nil,
        fix: (() -> Void)? = nil,
        onSubmit: (() -> Void)? = nil
    ) {
        self.label = label
        self._text = text
        self.state = state
        self.fixTitle = fixTitle
        self.fix = fix
        self.onSubmit = onSubmit
    }

    var body: some View {
        VStack(alignment: .leading, spacing: s3) {
            Text(label)
                .mynahFont(.label)
                .foregroundStyle(Palette.ink.secondary)

            field

            helper

            if let fixTitle, let fix {
                MynahButton(fixTitle, kind: .quiet, action: fix)
                    .padding(.leading, -s3)
            }
        }
        .frame(maxWidth: MynahWidth.stageColumn, alignment: .leading)
        .mynahAnimation(Motion.snap, value: state)
        .mynahAnimation(Motion.fade, value: isFocused)
    }

    private var field: some View {
        HStack(spacing: s3) {
            // Always secure. The key is a spending credential on the owner's
            // account; there is no view in this app that renders it in the clear.
            SecureField("", text: $text)
                .textFieldStyle(.plain)
                .mynahFont(.mono)
                .foregroundStyle(Palette.ink.primary)
                .focused($isFocused)
                .onSubmit { onSubmit?() }

            trailingControl
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .background(Palette.surface.sunken, in: RoundedRectangle.mynah(r.control))
        .mynahBorder(r.control, borderColor)
        .overlay {
            if isFocused {
                RoundedRectangle.mynah(r.control + 3)
                    .strokeBorder(Palette.accent.fill.opacity(0.30), lineWidth: 3)
                    .padding(-3)
            }
        }
    }

    @ViewBuilder
    private var trailingControl: some View {
        if case .checking = state {
            // Tinted, because this spinner sits inside one of MYNAH's own
            // fields. Platform chrome keeps the owner's system accent; anything
            // the app draws itself uses the app's. See `Palette.accent`.
            ProgressView()
                .controlSize(.small)
                .tint(Palette.accent.fill)
                .frame(width: 14, height: 14)
        } else {
            MynahButton("Paste", kind: .quiet) {
                if let pasted = NSPasteboard.general.string(forType: .string) {
                    text = APIKeyOnboarding.normalise(pasted)
                }
            }
            .padding(.trailing, -2)
        }
    }

    @ViewBuilder
    private var helper: some View {
        switch state {
        // Both of these are instructions the owner has to follow — where to get
        // a key, what it should look like, who is being asked. `tertiary` is for
        // marks, never for a sentence.
        case .idle(let line):
            Text(line).mynahFont(.callout).foregroundStyle(Palette.ink.secondary).mynahProse()
        case .shapeProblem(let line):
            Text(line).mynahFont(.callout).foregroundStyle(Palette.state.caution).mynahProse()
        case .checking(let line):
            Text(line).mynahFont(.callout).foregroundStyle(Palette.ink.secondary).mynahProse()
        case .rejected(let line):
            // No icon, no shake, no flash. The note appears and stays.
            Text(line)
                .mynahFont(.body)
                .foregroundStyle(Palette.state.critical)
                .textSelection(.enabled)
                .mynahProse()
                .transition(.push(from: .top).combined(with: .opacity))
        case .accepted(let line):
            Text(line).mynahFont(.body).foregroundStyle(Palette.state.good).mynahProse()
        }
    }

    private var borderColor: Color {
        switch state {
        case .shapeProblem: return Palette.state.caution
        case .rejected: return Palette.state.critical.opacity(0.55)
        case .accepted: return Palette.state.good.opacity(0.45)
        case .idle, .checking:
            return isFocused ? Palette.accent.fill.opacity(0.65) : Palette.line.hairline
        }
    }
}

// MARK: - Copy field

/// A value the owner needs to move somewhere else: a pairing code, a folder
/// path, a phone number. Mono, selectable, with one Copy button.
struct CopyField: View {
    var label: String?
    let value: String
    /// Masks the value until the owner asks to see it. The Copy button still
    /// copies the real thing.
    var isSecret: Bool = false

    @State private var isRevealed = false
    @State private var didCopy = false

    init(label: String? = nil, value: String, isSecret: Bool = false) {
        self.label = label
        self.value = value
        self.isSecret = isSecret
    }

    var body: some View {
        VStack(alignment: .leading, spacing: s3) {
            if let label {
                Text(label).mynahFont(.label).foregroundStyle(Palette.ink.secondary)
            }
            HStack(spacing: s4) {
                Text(displayValue)
                    .mynahFont(.mono)
                    .foregroundStyle(Palette.ink.primary)
                    .textSelection(.enabled)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: s4)
                if isSecret {
                    MynahButton(isRevealed ? "Hide" : "Show", kind: .quiet) {
                        isRevealed.toggle()
                    }
                }
                MynahButton(didCopy ? "Copied" : "Copy", kind: .quiet) {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(value, forType: .string)
                    didCopy = true
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .background(Palette.surface.sunken, in: RoundedRectangle.mynah(r.control))
            .mynahBorder(r.control)
        }
        .onChange(of: value) { _, _ in didCopy = false }
        .mynahAnimation(Motion.fade, value: didCopy)
    }

    private var displayValue: String {
        guard isSecret, !isRevealed else { return value }
        return String(repeating: "•", count: min(max(value.count, 8), 24))
    }
}

// MARK: - Inline banner

/// An inline explanation or error.
///
/// `explanation` must contain a verb the owner can perform: "Open Signal on your
/// phone once, then come back here." Never a code, never a status, never an
/// exception string — those go to `os.Logger`.
struct InlineBanner: View {
    enum Tone: Sendable {
        case info
        case caution
        case critical

        var ink: Color {
            switch self {
            case .info: return Palette.ink.primary
            case .caution: return Palette.state.caution
            case .critical: return Palette.state.critical
            }
        }

        var wash: Color {
            switch self {
            case .info: return Palette.surface.well
            case .caution: return Palette.state.cautionWash
            case .critical: return Palette.state.criticalWash
            }
        }

        var line: Color {
            switch self {
            case .info: return Palette.line.hairline
            case .caution: return Palette.state.caution.opacity(0.32)
            case .critical: return Palette.state.critical.opacity(0.32)
            }
        }
    }

    var tone: Tone = .info
    let headline: String
    let explanation: String
    var actionTitle: String?
    var action: (() -> Void)?

    init(
        tone: Tone = .info,
        headline: String,
        explanation: String,
        actionTitle: String? = nil,
        action: (() -> Void)? = nil
    ) {
        self.tone = tone
        self.headline = headline
        self.explanation = explanation
        self.actionTitle = actionTitle
        self.action = action
    }

    var body: some View {
        VStack(alignment: .leading, spacing: s2) {
            Text(headline)
                .mynahFont(.bodyEmphasis)
                .foregroundStyle(tone.ink)
                .fixedSize(horizontal: false, vertical: true)
            Text(explanation)
                .mynahFont(.body)
                .foregroundStyle(Palette.ink.secondary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            if let actionTitle, let action {
                MynahButton(actionTitle, kind: .quiet, action: action)
                    .padding(.leading, -s3)
                    .padding(.top, s1)
            }
        }
        .padding(s5)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(tone.wash, in: RoundedRectangle.mynah(r.card))
        .mynahBorder(r.card, tone.line)
        .transition(.push(from: .top).combined(with: .opacity))
    }
}

// MARK: - Empty state

/// Centred, one hierarchical glyph, one title, one line naming the next action,
/// and — only when there is one — a single primary button. No card, no border,
/// no fill: a left-aligned grey box looks like a filled state that failed.
struct EmptyState: View {
    let glyph: String
    let title: String
    let message: String
    var actionTitle: String?
    var action: (() -> Void)?

    init(
        glyph: String,
        title: String,
        message: String,
        actionTitle: String? = nil,
        action: (() -> Void)? = nil
    ) {
        self.glyph = glyph
        self.title = title
        self.message = message
        self.actionTitle = actionTitle
        self.action = action
    }

    /// Naturally sized vertically — it fills the width and centres inside
    /// whatever its parent gives it, rather than claiming all the height itself.
    ///
    /// Deliberate: a view that greedily fills vertical space feeds its height
    /// back up through a `NavigationSplitView` detail pane and pushes the
    /// sidebar out of the window. `MainShell` clamps that with a
    /// `GeometryReader`, and this staying naturally sized is the other half.
    /// Callers that need it to fill should say so at the call site.
    var body: some View {
        VStack(spacing: s5) {
            HeroGlyph(glyph, tone: .quiet)
            VStack(spacing: s3) {
                Text(title).mynahFont(.title2).foregroundStyle(Palette.ink.primary)
                Text(message)
                    .mynahFont(.body)
                    .foregroundStyle(Palette.ink.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 340)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let actionTitle, let action {
                MynahButton(actionTitle, action: action)
            }
        }
        .frame(maxWidth: .infinity)
    }
}

// MARK: - Thinking

/// Three dots that breathe. Not a spinner, not a progress bar, not a percentage.
///
/// There is no determinate progress available for an 18–29s turn and pretending
/// otherwise is a lie. Under reduce-motion all three sit still at 0.55 and only
/// the status text changes.
struct ThinkingIndicator: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isBreathing = false

    var body: some View {
        HStack(spacing: s3) {
            ForEach(0..<3, id: \.self) { index in
                Circle()
                    .fill(Palette.ink.tertiary)
                    .frame(width: 5, height: 5)
                    .opacity(reduceMotion ? 0.55 : (isBreathing ? 0.80 : 0.30))
                    .scaleEffect(reduceMotion ? 1 : (isBreathing ? 1.15 : 1.0))
                    .animation(
                        reduceMotion
                            ? nil
                            : .easeInOut(duration: 0.9)
                                .repeatForever(autoreverses: true)
                                .delay(Double(index) * 0.18),
                        value: isBreathing
                    )
            }
        }
        .onAppear { isBreathing = true }
        .accessibilityHidden(true)
    }
}

/// The whole waiting state: dots plus an honest, advancing status line.
///
/// The elapsed time is never rendered as a number. A big ticking readout is a
/// stopwatch the owner is failing.
struct TurnStatus: View {
    let elapsed: TimeInterval
    /// Set on the owner's very first turn only. One-time expectation setting.
    var showsFirstTurnHint: Bool = false

    init(elapsed: TimeInterval, showsFirstTurnHint: Bool = false) {
        self.elapsed = elapsed
        self.showsFirstTurnHint = showsFirstTurnHint
    }

    var body: some View {
        VStack(spacing: s3) {
            HStack(spacing: s4) {
                ThinkingIndicator()
                Text(MynahCopy.thinkingLine(elapsed: elapsed))
                    .mynahFont(.body)
                    .foregroundStyle(Palette.ink.secondary)
                    // A cross-fade, never a slide and never `.numericText()`:
                    // "Thinking…" becoming "Still thinking…" is a reassurance,
                    // not an event.
                    .contentTransition(.opacity)
                    .mynahAnimation(Motion.fade, value: MynahCopy.thinkingLine(elapsed: elapsed))
            }
            if showsFirstTurnHint {
                Text(MynahCopy.firstTurnExpectation)
                    .mynahFont(.callout)
                    .foregroundStyle(Palette.ink.secondary)
            }
        }
        .padding(.vertical, s5)
        .frame(maxWidth: .infinity)
    }
}

// MARK: - Waveform

/// 18 capsules driven by a real audio level.
///
/// The shape falloff and the shimmer term are what stop it reading as a stock
/// equaliser. 30fps, paused when idle or under reduce-motion — a level meter
/// running at full rate behind a closed window is pure battery.
struct Waveform: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var level: Double
    var isActive: Bool

    private let bars = 18

    init(level: Double, isActive: Bool) {
        self.level = level
        self.isActive = isActive
    }

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: !isActive || reduceMotion)) { timeline in
            let timestamp = timeline.date.timeIntervalSinceReferenceDate
            HStack(alignment: .center, spacing: 3) {
                ForEach(0..<bars, id: \.self) { index in
                    Capsule()
                        .fill(isActive ? Palette.accent.fill : Palette.ink.quaternary)
                        .opacity(opacity(for: index, timestamp: timestamp))
                        .frame(width: 4, height: barHeight(index, timestamp: timestamp))
                }
            }
        }
        // Fixed height so a rising level never reflows whatever sits beside it.
        .frame(height: 28)
        .opacity(isActive ? 1 : 0.55)
        .accessibilityHidden(true)
    }

    private func barHeight(_ index: Int, timestamp: TimeInterval) -> CGFloat {
        let phase = abs(Double(index) - Double(bars - 1) / 2.0)
        let shape = 1.0 - min(phase / Double(bars), 0.65)
        let clampedLevel = isActive ? min(max(level, 0), 1) : 0
        let localPulse = (sin(timestamp * 14.0 + Double(index) * 0.72) + 1.0) / 2.0
        let shimmer = 0.74 + (localPulse * 0.30)
        let idleMotion = isActive ? 1.2 + (localPulse * 2.4) : 0
        return CGFloat(4 + idleMotion + (clampedLevel * shape * shimmer * 18))
    }

    private func opacity(for index: Int, timestamp: TimeInterval) -> Double {
        guard isActive else { return 0.35 }
        let clampedLevel = min(max(level, 0), 1)
        let threshold = Int((clampedLevel * Double(bars)).rounded(.up))
        let localPulse = (sin(timestamp * 12.0 + Double(index) * 0.62) + 1.0) / 2.0
        return index < max(1, threshold) ? 0.72 + (localPulse * 0.22) : 0.18 + (localPulse * 0.08)
    }
}

// MARK: - Memory row

/// What MYNAH remembers, and when it learned it. Nothing else.
///
/// No confidence percentage, no domain chip, no consensus state, no leading
/// glyph. Those are facts about the machinery, and the owner did not buy
/// machinery.
struct MemoryRow: View {
    let text: String
    let date: Date
    let topic: String
    var isSelected: Bool = false

    init(text: String, date: Date, topic: String, isSelected: Bool = false) {
        self.text = text
        self.date = date
        self.topic = topic
        self.isSelected = isSelected
    }

    var body: some View {
        VStack(alignment: .leading, spacing: s2) {
            Text(text)
                .mynahFont(.body)
                .foregroundStyle(Palette.ink.primary)
                .lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
            // When it was learned and what it is about are the two facts this
            // row exists to carry, so they get `secondary`. The `·` between
            // them is a genuine mark and stays quaternary.
            HStack(spacing: s3) {
                Text(date.formatted(.relative(presentation: .named)))
                    .mynahFont(.label)
                    .foregroundStyle(Palette.ink.secondary)
                Text("·").mynahFont(.label).foregroundStyle(Palette.ink.quaternary)
                Text(topic).mynahFont(.label).foregroundStyle(Palette.ink.secondary)
            }
        }
        .padding(.horizontal, s4)
        .padding(.vertical, s4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            isSelected ? Palette.accent.wash : .clear,
            in: RoundedRectangle.mynah(r.control)
        )
    }
}

// MARK: - Settings row

/// A settings list with a coloured icon per row is a control panel. MYNAH is
/// not one, so rows carry no leading icons and sit directly on the canvas.
struct SettingsRow<Control: View>: View {
    let title: String
    var detail: String?
    @ViewBuilder var control: Control

    init(_ title: String, detail: String? = nil, @ViewBuilder control: () -> Control) {
        self.title = title
        self.detail = detail
        self.control = control()
    }

    var body: some View {
        HStack(spacing: s5) {
            VStack(alignment: .leading, spacing: s1) {
                Text(title).mynahFont(.title3).foregroundStyle(Palette.ink.primary)
                if let detail {
                    Text(detail)
                        .mynahFont(.callout)
                        .foregroundStyle(Palette.ink.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: s6)
            control
        }
        .padding(.vertical, s4)
    }
}

// MARK: - Previews

private struct PreviewPair<Content: View>: View {
    let title: String
    @ViewBuilder var content: Content

    var body: some View {
        HStack(spacing: 0) {
            pane.environment(\.colorScheme, .light)
            pane.environment(\.colorScheme, .dark)
        }
    }

    private var pane: some View {
        VStack(alignment: .leading, spacing: s6) {
            Text(title).mynahFont(.eyebrow).foregroundStyle(Palette.ink.tertiary)
            content
            Spacer(minLength: 0)
        }
        .padding(s8)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Palette.surface.canvas)
    }
}

#Preview("Buttons") {
    PreviewPair(title: "Buttons — all states") {
        VStack(alignment: .leading, spacing: s5) {
            HStack(spacing: s4) {
                MynahButton("Continue") {}
                MynahButton("Choose this", kind: .secondary) {}
                MynahButton("Not now", kind: .quiet) {}
            }
            HStack(spacing: s4) {
                MynahButton("Continue", isEnabled: false) {}
                MynahButton("Choose this", kind: .secondary, isEnabled: false) {}
                MynahButton("Not now", kind: .quiet, isEnabled: false) {}
            }
            ActionRow(quietTitle: "Not now", quietAction: {}, helper: "Pick where your words go") {
                MynahButton("Continue", isEnabled: false) {}
            }
        }
    }
    .frame(width: 900, height: 320)
}

#Preview("Option cards") {
    OptionCardPreviewHost()
        .frame(width: 1240, height: 620)
}

private struct OptionCardPreviewHost: View {
    @State private var selection: BrainSetupOptionID? = .googleSignIn

    private static let sample: [BrainSetupOption] = [
        BrainSetupOption(
            id: .googleSignIn,
            label: "Sign in with Google",
            summary: "Sign in with a Google account — no API key and no card. What you say goes to Google.",
            requirement: .signIn,
            keepsWordsOnDevice: false,
            availability: .available,
            tier: .zeroFrictionSignIn,
            backendIdentifier: "google"
        ),
        BrainSetupOption(
            id: .anthropicAPIKey,
            label: "Anthropic API key",
            summary: "Paste an Anthropic API key. Billed per use. What you say goes to Anthropic.",
            requirement: .apiKey,
            keepsWordsOnDevice: false,
            availability: .available,
            tier: .typedAPIKey,
            backendIdentifier: "anthropic"
        ),
        BrainSetupOption(
            id: .fullyLocal,
            label: "Fully on this Mac",
            summary: "Downloads a model and runs it here. Nothing you say leaves the machine, and there's nothing to sign into or pay for.",
            requirement: .download,
            keepsWordsOnDevice: true,
            approximateDownloadBytes: 4_700_000_000,
            availability: .available,
            tier: .fullyLocal,
            backendIdentifier: "ollama",
            modelName: "qwen3.5:4b"
        ),
        BrainSetupOption(
            id: .claudeCodeCLI,
            label: "Claude Code",
            summary: "Use the Claude Code subscription you already pay for.",
            requirement: .signIn,
            keepsWordsOnDevice: false,
            availability: .unavailable(reason: "Claude Code isn't installed on this Mac."),
            tier: .signedInSubscription,
            backendIdentifier: "claude-code-cli"
        )
    ]

    var body: some View {
        HStack(spacing: 0) {
            pane.environment(\.colorScheme, .light)
            pane.environment(\.colorScheme, .dark)
        }
    }

    private var pane: some View {
        ScrollView {
            OptionCardList(
                options: Self.sample,
                recommendedID: .googleSignIn,
                selection: $selection
            )
            .padding(s8)
        }
        .background(Palette.surface.canvas)
    }
}

#Preview("Key field") {
    KeyFieldPreviewHost().frame(width: 1100, height: 560)
}

private struct KeyFieldPreviewHost: View {
    @State private var key = "sk-ant-api03-not-a-real-key"

    var body: some View {
        HStack(spacing: 0) {
            pane.environment(\.colorScheme, .light)
            pane.environment(\.colorScheme, .dark)
        }
    }

    private var pane: some View {
        VStack(alignment: .leading, spacing: s7) {
            KeyField(text: $key, state: .idle(helper: APIKeyOnboarding.anthropic.looksLikeHint))
            KeyField(text: $key, state: .shapeProblem("That looks like a web address, not a key."))
            KeyField(text: $key, state: .checking("Checking this key with Anthropic…"))
            KeyField(
                text: $key,
                state: .rejected("That key was refused. Check you copied the whole thing, and that it hasn't been deleted."),
                fixTitle: "Get a key from Anthropic",
                fix: {}
            )
            KeyField(text: $key, state: .accepted("That works — you're connected to claude-opus-5."))
            Spacer(minLength: 0)
        }
        .padding(s8)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Palette.surface.canvas)
    }
}

#Preview("Status, banners, rails") {
    PreviewPair(title: "Status & notes") {
        VStack(alignment: .leading, spacing: s6) {
            ProgressRail(titles: ["Welcome", "Brain", "Connect", "Ready"], currentIndex: 1)
            HStack(spacing: s3) {
                StatusPill("Linked", tone: .good)
                StatusPill("Needs you", tone: .caution)
                StatusPill("Sleeping")
                StatusPill("Answering", tone: .accent)
            }
            VStack(spacing: 0) {
                StatusLine("Your phone", value: "Linked", tone: .good)
                MynahDivider()
                StatusLine("Where your words go", value: "This Mac", tone: .good)
                MynahDivider()
                StatusLine("Web search", value: "Off")
            }
            InlineBanner(
                headline: "MYNAH keeps answering with this window closed.",
                explanation: "Close it whenever you like — your phone still reaches it."
            )
            InlineBanner(
                tone: .caution,
                headline: "This sends your words to Google.",
                explanation: "You can move to a brain that runs on this Mac later, in Settings."
            )
            InlineBanner(
                tone: .critical,
                headline: "MYNAH can't reach your phone.",
                explanation: "Open Signal on your phone once, then come back here.",
                actionTitle: "Try again",
                action: {}
            )
            TurnStatus(elapsed: 24, showsFirstTurnHint: true)
            Waveform(level: 0.62, isActive: true)
        }
    }
    .frame(width: 1100, height: 900)
}

#Preview("Lists & empty states") {
    PreviewPair(title: "Lists") {
        VStack(alignment: .leading, spacing: s6) {
            VStack(spacing: 0) {
                MemoryRow(
                    text: "Prefers the espresso machine descaled every three weeks, not monthly.",
                    date: Date().addingTimeInterval(-3_600),
                    topic: "Home",
                    isSelected: true
                )
                MynahDivider(leadingInset: s4)
                MemoryRow(
                    text: "Flying to Kuala Lumpur on the 14th; wants the 6am departure, not the redeye.",
                    date: Date().addingTimeInterval(-86_400 * 3),
                    topic: "Travel"
                )
            }
            SectionHeader("Answering")
            VStack(spacing: 0) {
                SettingsRow("Keep answering when this window is closed", detail: "Your phone can still reach MYNAH.") {
                    Toggle("", isOn: .constant(true)).labelsHidden().mynahToggle()
                }
                MynahDivider()
                SettingsRow("Text size") {
                    Picker("", selection: .constant(MynahTextSize.standard)) {
                        ForEach(MynahTextSize.allCases) { Text($0.label).tag($0) }
                    }
                    .labelsHidden()
                    .frame(width: 140)
                }
            }
            CopyField(label: "Pairing code", value: "MYNAH-4471-QX")
            CopyField(label: "Anthropic key", value: "sk-ant-api03-not-a-real-key", isSecret: true)
            EmptyState(
                glyph: "text.append",
                title: "No memories yet",
                message: "MYNAH will start remembering once you talk to it.",
                actionTitle: "Link my phone",
                action: {}
            )
            .frame(height: 260)
        }
    }
    .frame(width: 1100, height: 940)
}
