import AppKit
import SwiftUI

// MARK: - Colour construction
//
// Every surface, ink and line in MYNAH is a literal sRGB value, never a
// semantic `NSColor`. On this OS `windowBackgroundColor`, `controlBackgroundColor`
// and `textBackgroundColor` all resolve to the same #FFFFFF / #1E1E1E, so an
// elevation model built on them renders as one flat plane and every card has to
// be rescued by a hairline. Literals let the ramp carry a measured luminance
// step, which is what makes a card read as a card with the stroke removed.

extension Color {

    /// A colour that flips with the system appearance without any call site
    /// having to read `\.colorScheme`.
    ///
    /// `NSColor(name:dynamicProvider:)` resolves at draw time against the
    /// appearance actually in effect, so a token defined once is correct inside
    /// a vibrant sidebar, a popover, and a light window on a dark system.
    static func mynah(light: NSColor, dark: NSColor) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
        })
    }
}

extension NSColor {

    /// `0xF4F4F6` style literals, in sRGB rather than the calibrated space so
    /// the numbers in the spec are the numbers on screen.
    static func mynahHex(_ hex: UInt32, alpha: CGFloat = 1) -> NSColor {
        NSColor(
            srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: alpha
        )
    }

    /// Pure black or white at an alpha — the shape every ink and line token takes.
    static func mynahMono(_ white: CGFloat, _ alpha: CGFloat) -> NSColor {
        NSColor(srgbRed: white, green: white, blue: white, alpha: alpha)
    }
}

// MARK: - Palette

/// The whole colour vocabulary. Nothing outside this enum may name a colour.
enum Palette {

    /// The elevation ramp. Four steps, each separated by a luminance difference
    /// large enough to read without a border (4.7% light, 5.8% dark).
    enum surface {
        /// The page behind everything.
        static let canvas = Color.mynah(light: .mynahHex(0xF4F4F6), dark: .mynahHex(0x161618))
        /// Cards, list rows, panels.
        static let raised = Color.mynah(light: .mynahHex(0xFFFFFF), dark: .mynahHex(0x1F1F23))
        /// Text wells, transcript areas, key fields — content sits *in* these.
        static let sunken = Color.mynah(light: .mynahHex(0xEDEDF0), dark: .mynahHex(0x111113))
        /// Sheets, popovers, the floating HUD.
        static let overlay = Color.mynah(light: .mynahHex(0xFFFFFF), dark: .mynahHex(0x26262B))
        /// The fill behind a glyph well. Not part of the ramp — it is ink at a
        /// low alpha, so it tints correctly on any of the four surfaces.
        static let well = Color.mynah(light: .mynahMono(0, 0.05), dark: .mynahMono(1, 0.08))

        /// The same value as `canvas`, for the one caller that needs an
        /// `NSColor`: the window's own background. Without it the frame flashes
        /// system white behind the SwiftUI content during a live resize.
        static let canvasNSColor = NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
                ? .mynahHex(0x161618)
                : .mynahHex(0xF4F4F6)
        }
    }

    /// Text and glyph colours. Never `Color.primary`/`.secondary`: those are
    /// `labelColor` at 0.85 alpha and shift meaning under `.foregroundStyle`
    /// hierarchy, so the same token renders differently in two containers.
    enum ink {
        static let primary = Color.mynah(light: .mynahMono(0, 0.88), dark: .mynahMono(1, 0.93))
        static let secondary = Color.mynah(light: .mynahMono(0, 0.56), dark: .mynahMono(1, 0.62))

        /// **Marks only — never a sentence.**
        ///
        /// 2.37:1 on `surface.raised` in light and 3.53:1 in dark. That is
        /// correct for a `·` separator, a step numeral in a gutter, a dimmed
        /// two-word control; it is not legible for text the owner has to read
        /// and act on. It carried the API-key instructions, the requirement
        /// lines, the reason an option was unavailable, memory dates and the
        /// only explanation for a disabled Continue — every one of them 11–12pt
        /// for exactly the person who cannot afford to miss it. Anything that
        /// is a sentence takes `secondary` (4.68:1).
        static let tertiary = Color.mynah(light: .mynahMono(0, 0.34), dark: .mynahMono(1, 0.38))
        static let quaternary = Color.mynah(light: .mynahMono(0, 0.16), dark: .mynahMono(1, 0.20))
    }

    enum line {
        /// Resting card, field, row.
        static let hairline = Color.mynah(light: .mynahMono(0, 0.09), dark: .mynahMono(1, 0.11))
        /// Hovered card, focused field's inner edge.
        static let strong = Color.mynah(light: .mynahMono(0, 0.16), dark: .mynahMono(1, 0.20))
        /// Between rows in a list.
        static let divider = Color.mynah(light: .mynahMono(0, 0.07), dark: .mynahMono(1, 0.09))
    }

    /// **The accent is ink, not amber. The owner ended a long argument in one
    /// line: *"amber accent kill it bro - its meaningless"*.**
    ///
    /// He was right, and the evidence was already in this file. The amber had
    /// accumulated four jobs — the recommended choice, the one live thing, a
    /// paused appliance, a destination that leaves the Mac — and a colour with
    /// four jobs is read as its most alarming one. He proved it by reporting a
    /// crash that had not happened, off a yellow mark on a task list. Every
    /// attempt to fix that was a rule about *which* amber was allowed where,
    /// which is a rule nobody can apply while choosing a colour.
    ///
    /// So the accent is now the same near-black as `button.primaryFill`, and
    /// the meaning it used to carry is carried by shape, weight and words — a
    /// filled chip is selected, a sparkle is recommended, a sentence names the
    /// company. **See `state` for the other half of the ruling: a control that
    /// cannot be used is disabled rather than coloured.**
    ///
    /// **Scope, unchanged: these tokens are for MYNAH's own surfaces only.**
    /// Platform chrome — the sidebar's selection capsule, pop-up buttons,
    /// confirmation dialogs' default button — keeps the *system* accent the
    /// owner set in System Settings, because that is what every other Mac app on
    /// their machine does. So the app deliberately sets no root `.tint`.
    /// Anything MYNAH draws itself — a selected option card, the recommendation
    /// sparkle, a switch, a spinner inside one of our own fields — uses these.
    enum accent {
        /// Selection fills, the recommendation marker, the listening ring.
        static let fill = Color.mynah(light: .mynahHex(0x1C1C1F), dark: .mynahHex(0xF2F2F4))
        /// Accent-coloured *text and glyphs*. Full-strength ink in both schemes:
        /// with the hue gone there is nothing left to darken for contrast.
        static let ink = Color.mynah(light: .mynahHex(0x151517), dark: .mynahHex(0xF5F5F7))
        /// Selected-row background, chip background. A wash of the ink rather
        /// than of a hue, so a selected row reads as *raised* and not as *lit*.
        static let wash = Color.mynah(light: .mynahMono(0, 0.07), dark: .mynahMono(1, 0.11))
        /// Anything sitting *on* `accent.fill`, which is dark in light mode and
        /// light in dark mode — so this inverts with it.
        static let onFill = Color.mynah(light: .mynahHex(0xFFFFFF), dark: .mynahHex(0x151517))
    }

    /// **Two colours, and there is no amber.**
    ///
    /// Green means "your words stay on this Mac". Red means something failed.
    /// That is the whole vocabulary, and the gap between them is deliberate.
    ///
    /// ## Why the amber went
    ///
    /// It spent a long time meaning four things — paused, restricted, setup
    /// unfinished, words leaving the Mac — and the owner proved what a colour
    /// with four jobs does. He looked at a yellow mark on his task list and
    /// reported *"signal crashed again"*. Signal had not crashed; both
    /// processes were up. He was reading the colour correctly, because by then
    /// amber on this product genuinely did mean *Mynah is not doing what you
    /// think*, and a stale list had borrowed it.
    ///
    /// Two rules were written to contain that — one about subject rather than
    /// severity, one about destinations not being faults — and both were rules
    /// you had to already know in order to pick a colour correctly. He ended it
    /// instead: *"amber accent kill it bro - its meaningless"*.
    ///
    /// ## What replaces it, and it is not another colour
    ///
    /// **A control that cannot be used is disabled.** That was the owner's own
    /// substitution — *"if something is not working, we should disable the send
    /// button or something instead; that makes more visual sense"* — and it is
    /// strictly better than the amber was, because a grey Send cannot be
    /// misread as a crash, and it stops the thing it is warning about instead
    /// of merely colouring it. `ConversationModel.canSend` is where that lives.
    ///
    /// Everything else amber used to carry is now carried by words. "Paused"
    /// says paused. "Not done" says not done. A destination pill names the
    /// company, which is a far more specific signal than a hue: "Anthropic"
    /// tells the owner where his words went, and amber only told him to worry.
    ///
    /// `critical` survives because a failure is not a shade of a warning, and
    /// `good` survives because nothing ever used it for a fault — it means
    /// "stays on this Mac", and it means only that.
    enum state {
        static let good = Color.mynah(light: .mynahHex(0x1D8A4E), dark: .mynahHex(0x3FD07E))
        static let critical = Color.mynah(light: .mynahHex(0xC0392B), dark: .mynahHex(0xFF6B5E))

        /// Low-alpha backgrounds for inline notes.
        static let goodWash = Color.mynah(
            light: .mynahHex(0x1D8A4E, alpha: 0.10),
            dark: .mynahHex(0x3FD07E, alpha: 0.12)
        )

        /// A full-width band that tints whatever it is laid over. See
        /// `UpdateBanner`, which is the only thing that should use it.
        ///
        /// **Stronger than `goodWash` and used differently, which is the point.**
        /// A wash sits inside a card that has already painted an opaque surface,
        /// so it only ever has to tint white. A band has nothing of its own
        /// underneath — the window shows through it — which is what the owner
        /// meant by *"translucent green like quiettype-ish"*, and it needs the
        /// weight to read as green rather than as a smudge.
        ///
        /// The alphas are the reference's own: QuietType's band is
        /// `Color.green.opacity(0.16)` light and `0.24` dark. The hue stays this
        /// palette's `good` so no new colour enters the design system.
        static let goodBand = Color.mynah(
            light: .mynahHex(0x1D8A4E, alpha: 0.16),
            dark: .mynahHex(0x3FD07E, alpha: 0.24)
        )
        static let criticalWash = Color.mynah(
            light: .mynahHex(0xC0392B, alpha: 0.09),
            dark: .mynahHex(0xFF6B5E, alpha: 0.12)
        )

        /// **Words leave this Mac. That is the whole meaning, and it may never
        /// acquire a second one.**
        ///
        /// Amber was removed from this product once, and the argument was the
        /// owner's: *"amber accent kill it bro - its meaningless"*. It was
        /// meaningless because it meant four things at once — paused,
        /// restricted, setup unfinished, and words leaving the Mac — and he
        /// proved what that costs by reading a yellow mark on a stale task list
        /// as "Signal has crashed". It had not; both processes were up.
        ///
        /// It comes back for exactly one of those four, at his request: *"if
        /// user is using api key, these model thing should be in yellow /
        /// orange - green only when its fully private"*. That is the same
        /// distinction `good` already carries from the other side — green has
        /// only ever meant "stays on this Mac" and has never been used for a
        /// fault, which is precisely why green survived the sweep.
        ///
        /// So this is one half of a pair, not a warning colour. It does not
        /// mean danger, it does not mean broken, and nothing that is merely
        /// *not working* may use it — a jammed engine disables Send, which is
        /// the constraint that replaced the signal. `AmberIsGoneTests` holds
        /// the line: it now permits this token and still forbids every other
        /// amber, so the next person to reach for a warm yellow has to come
        /// through here and read this.
        static let caution = Color.mynah(light: .mynahHex(0x9A6212), dark: .mynahHex(0xE0A54A))
        static let cautionWash = Color.mynah(
            light: .mynahHex(0x9A6212, alpha: 0.10),
            dark: .mynahHex(0xE0A54A, alpha: 0.13)
        )

        /// **When something happens — not whether anything is wrong.**
        ///
        /// The owner asked for these directly: *"things that are due today
        /// should be at the top probably with a 'blue' border for the card
        /// perhaps to show its something happening soon"*, and then *"and yellow
        /// for the ones due tomorrow?"*.
        ///
        /// **Today is the warm one.** First built the other way round, and the
        /// owner corrected it on sight: *"change teh colors around - red /
        /// orange should be today, blue should be tomorrow"*. He is right and
        /// the reason is worth keeping — warmth reads as urgency everywhere
        /// else, so a cool border on the thing happening in two hours was
        /// fighting an instinct rather than using it. Tomorrow is genuinely
        /// cooler news.
        ///
        /// Orange rather than the yellow first suggested, also his call, and it
        /// settles a collision as well as a preference: `caution` carries
        /// exactly one meaning, words leave this Mac, and the history above is
        /// what a colour with more than one job costs — he read a yellow mark on
        /// a stale task list as "Signal has crashed". A second yellow, however
        /// separate its constant, would have had somebody comparing them by eye.
        ///
        /// These live on a **border**, never on text or a pill. A border says
        /// "this one" without claiming anything about state, which is precisely
        /// the distinction that was lost last time.
        static let dueToday = Color.mynah(light: .mynahHex(0xC2410C), dark: .mynahHex(0xFB923C))
        static let dueTomorrow = Color.mynah(light: .mynahHex(0x1F6FEB), dark: .mynahHex(0x58A6FF))
    }

    /// Stated explicitly in both schemes rather than inverting `Color.primary`,
    /// which produces a white button with white-ish text wherever the resolved
    /// window background is not what the inversion assumed.
    enum button {
        static let primaryFill = Color.mynah(light: .mynahHex(0x1C1C1F), dark: .mynahHex(0xF2F2F4))
        static let primaryInk = Color.mynah(light: .mynahHex(0xFFFFFF), dark: .mynahHex(0x151517))
        static let primaryFillPressed = Color.mynah(
            light: .mynahHex(0x33333A),
            dark: .mynahHex(0xD8D8DC)
        )
    }
}

// Both spellings compile. The spec writes `Color.line.hairline` in places and
// `Palette.line.hairline` in others; making one a typo would cost more than
// three aliases. `Palette.*` is canonical.
extension Color {
    static var ink: Palette.ink.Type { Palette.ink.self }
    static var line: Palette.line.Type { Palette.line.self }
    static var surface: Palette.surface.Type { Palette.surface.self }
}

// MARK: - Spacing

// A 4pt base, nine steps, deliberately terse names so a call site reads
// `.padding(s6)` rather than `.padding(MynahSpacing.standardCardPadding)` —
// short enough that reaching for a raw number is never the easier option.
let s1: CGFloat = 2
let s2: CGFloat = 4
let s3: CGFloat = 8
let s4: CGFloat = 12
let s5: CGFloat = 16
let s6: CGFloat = 20
let s7: CGFloat = 24
let s8: CGFloat = 32
let s9: CGFloat = 48

// MARK: - Radii

/// Four radii, all continuous. Named `r` so `r.card` is shorter to type than
/// `14` is to remember.
/// Radii scale with the boxes they round. Every box grew when the type did, and
/// a 14pt radius on a card that is now half again as tall reads sharper than it
/// did — the corner is a proportion of the shape, not a constant.
enum r {
    /// Pills, chips, keycaps, tiny badges.
    static let chip: CGFloat = 9
    /// Buttons, text fields, list rows, segmented track.
    static let control: CGFloat = 12
    /// Cards, panels, wells, group containers.
    static let card: CGFloat = 18
    /// Sheets, floating HUD, modal overlays.
    static let sheet: CGFloat = 26
}

extension RoundedRectangle {

    /// The only way a rounded rectangle enters this app.
    ///
    /// `.circular` corners have a visible curvature discontinuity where the arc
    /// meets the straight edge; the continuous curve does not, and that
    /// difference is the most recognisable piece of Apple's visual grammar.
    /// Routing every shape through here means `.circular` cannot be typed by
    /// accident.
    static func mynah(_ radius: CGFloat) -> RoundedRectangle {
        RoundedRectangle(cornerRadius: radius, style: .continuous)
    }
}

// MARK: - Content widths

/// Measured caps rather than `maxWidth: .infinity` everywhere. A 13pt paragraph
/// running the full width of a 1180pt window is ~150 characters per line, which
/// no one reads twice.
enum MynahWidth {
    /// The onboarding stage, across both of its columns.
    ///
    /// 520 was one column of prose centred in a window twice that wide, which
    /// left the setup flow reading as a narrow strip with a great deal of empty
    /// canvas either side of it. The window is wide; the stage may as well use
    /// it.
    static let stageColumn: CGFloat = 860

    /// The mark's column — roughly a third, with the content taking the rest.
    ///
    /// Fixed rather than a fraction so the content column starts in the same
    /// place on every stage. A mark that shifts left and right between screens
    /// reads as the layout being unsure of itself.
    static let stageMarkColumn: CGFloat = 240
    /// Prose inside that column — ~62 characters at 13pt.
    static let prose: CGFloat = 460
    /// A settings pane.
    ///
    /// Deliberately still 640, and widening it was tried and reverted. The pane
    /// sits beside a 284pt sidebar in a 1180pt window, so the obvious reading of
    /// "there is too much blank space" is to make the column wider — which
    /// measurably made it worse: the label stays left and the control stays
    /// right, so a wider row is a *bigger* gap between them, which is the thing
    /// that was being complained about. Unused width wants a second column, not
    /// a stretched one.
    static let settings: CGFloat = 640

    /// The measure a settings caption wraps at.
    ///
    /// A detail that runs the full width of the card is a paragraph; the same
    /// sentence capped is a caption under a label, which is most of why a
    /// settings pane reads as documentation rather than as settings.
    ///
    /// 480 rather than 420, and the 60pt matters more than it looks. At 420 an
    /// ordinary one-sentence detail — "Sent to Anthropic each time you ask
    /// something, so it can work out an answer" — wrapped onto a second line, so
    /// capping the prose made the common row *taller* while only helping the
    /// rare long one. 480 keeps a sentence on one line and still forces an
    /// essay to wrap, which is the shape that was wanted: cap the paragraphs,
    /// not the captions.
    static let settingsCaption: CGFloat = 480
    /// A memory detail view.
    static let memoryDetail: CGFloat = 720
    /// A choice card's summary line.
    static let cardSummary: CGFloat = 380
}

// MARK: - Type scale

/// How much larger the owner asked for everything to be.
///
/// Not a font-size picker: three named steps, applied to *every* token
/// including display and numerals. A text-size setting that moves only half the
/// UI is worse than none, because the half that moved makes the half that
/// didn't look broken.
enum MynahTextSize: String, CaseIterable, Identifiable, Sendable {
    case standard
    case large
    case larger

    var id: String { rawValue }

    var delta: CGFloat {
        switch self {
        case .standard: return 0
        case .large: return 2
        case .larger: return 4
        }
    }

    var label: String {
        switch self {
        case .standard: return "Standard"
        case .large: return "Large"
        case .larger: return "Larger"
        }
    }
}

private struct MynahTypeDeltaKey: EnvironmentKey {
    static let defaultValue: CGFloat = 0
}

extension EnvironmentValues {
    /// Points added to every type token. Set once at the window root.
    var mynahTypeDelta: CGFloat {
        get { self[MynahTypeDeltaKey.self] }
        set { self[MynahTypeDeltaKey.self] = newValue }
    }
}

/// Eleven tokens. A size not on this list does not exist in MYNAH.
enum MynahFont: CaseIterable, Sendable {
    /// 32/bold. One per onboarding stage, never two on a screen.
    case display
    /// 22/semibold. Sheet title, page title.
    case title1
    /// 17/semibold. Card title, choice-card name.
    case title2
    /// 15/semibold. List-row title, group header, button label.
    case title3
    /// 13/regular. Paragraphs, descriptions.
    case body
    /// 13/medium. Inline emphasis, row values, numbers inside sentences.
    case bodyEmphasis
    /// 12/regular. Secondary explanation under a control.
    case callout
    /// 11/medium. Field labels, pill text, metadata.
    case label
    /// 10/semibold, uppercased. "STEP 2 OF 4", group kickers.
    case eyebrow
    /// 28/semibold/rounded/monospaced digits. The one big number on a screen.
    case numeral
    /// 12/medium/monospaced. Keys, paths, durations, sizes.
    case mono

    /// **The scale the owner asked for, and what it replaces.**
    ///
    /// It was 13pt body, 22pt title, 32pt display — System Settings sizing. Read
    /// back against the reference he sent (QuietType), his verdict was *"a bit
    /// too Anthropic"*, and the diagnosis is exact: muted, low-contrast, and
    /// typeset for a preference pane rather than an app somebody looks at.
    ///
    /// The reference is not subtle and does not need to be. A 44pt headline over
    /// a 15pt subtitle, numerals big enough to read across a desk, and sidebar
    /// items you hit without aiming. That is Apple's own current display
    /// typography — Music, Fitness, System Settings' own hero rows — rather than
    /// anything web.
    ///
    /// **Every size moved up together on purpose.** Enlarging headings alone
    /// widens the gap until the page reads as a poster with fine print under it;
    /// the ratios between steps are what make a scale feel deliberate, so those
    /// are preserved and the whole thing is shifted.
    var size: CGFloat {
        switch self {
        case .display: return 44
        case .title1: return 30
        case .title2: return 22
        case .title3: return 17
        case .body, .bodyEmphasis: return 15
        case .callout, .mono: return 13
        case .label: return 12
        case .eyebrow: return 11
        case .numeral: return 42
        }
    }

    /// Heavier at the top, unchanged at the bottom.
    ///
    /// `display` and `numeral` go to `.bold`, and `title1` with them — at 30pt,
    /// semibold reads as regular. Body stays `.regular`: bolding paragraph text
    /// is how "bold and modern" turns into shouting, and the reference does not
    /// do it either. The contrast comes from the *jump* between steps.
    var weight: Font.Weight {
        switch self {
        case .display, .title1, .numeral: return .bold
        case .title2, .title3, .eyebrow: return .semibold
        case .body, .callout: return .regular
        case .bodyEmphasis, .label, .mono: return .medium
        }
    }

    /// SF Pro's default tracking is metrically correct at 13pt and visibly loose
    /// above 20pt. Apple's own display type is always tightened; without this
    /// every heading in the app is 3–4% wider than it should be.
    /// Tightened further, because the sizes moved.
    ///
    /// Tracking is a proportion of the size and these values were set for a
    /// 32pt display. At 44pt the old `-0.6` leaves the headline visibly airy —
    /// the exact "web page" look he objected to twice. Apple's display faces
    /// tighten roughly linearly above 20pt and these follow that.
    var tracking: CGFloat {
        switch self {
        case .display: return -1.1
        case .title1: return -0.6
        case .title2: return -0.3
        case .title3: return -0.15
        case .body, .bodyEmphasis, .mono: return 0
        case .callout: return 0.05
        case .label: return 0.15
        case .eyebrow: return 0.8
        case .numeral: return -1.0
        }
    }

    /// Leading grows with the type, except where the type is a single line.
    ///
    /// A 44pt headline at the old 5pt spacing sets too tight when it wraps to
    /// two lines, which the Home headline does at narrow widths. Numerals and
    /// labels stay at 0 — they never wrap, and spacing on a single line only
    /// pushes it off its own baseline.
    var lineSpacing: CGFloat {
        switch self {
        case .display: return 7
        case .title1: return 6
        case .body, .bodyEmphasis: return 5
        case .title2, .callout: return 4
        case .title3: return 3
        case .label, .eyebrow, .numeral, .mono: return 0
        }
    }

    var textCase: Text.Case? {
        self == .eyebrow ? .uppercase : nil
    }

    /// `.rounded` is permitted in exactly two places in the whole app: the
    /// "Mynah" wordmark, and large numeric readouts. Rounded buttons and rounded
    /// titles are what make a Mac app read as an iOS app that was dragged over.
    private var design: Font.Design {
        switch self {
        case .numeral: return .rounded
        case .mono: return .monospaced
        default: return .default
        }
    }

    func font(delta: CGFloat = 0) -> Font {
        let base = Font.system(size: size + delta, weight: weight, design: design)
        // Anything that changes needs fixed-width figures, or the layout twitches
        // sideways on every update and the eye catches it even when the mind
        // doesn't.
        return self == .numeral ? base.monospacedDigit() : base
    }
}

private struct MynahFontModifier: ViewModifier {
    let token: MynahFont
    @Environment(\.mynahTypeDelta) private var delta

    func body(content: Content) -> some View {
        content
            .font(token.font(delta: delta))
            .tracking(token.tracking)
            .lineSpacing(token.lineSpacing)
            .textCase(token.textCase)
    }
}

extension View {

    /// The only way text gets a size in MYNAH. Applies weight, tracking, line
    /// spacing, case and the owner's text-size delta in one place.
    func mynahFont(_ token: MynahFont) -> some View {
        modifier(MynahFontModifier(token: token))
    }

    /// The "Mynah" wordmark — the one rounded, un-tracked piece of text.
    func mynahWordmark() -> some View {
        modifier(MynahWordmarkModifier())
    }

    /// A multi-line prose block: capped line length and allowed to grow
    /// vertically. Forgetting `.fixedSize` is how descriptions end up truncated
    /// to one line in a column that had room for three.
    func mynahProse(maxWidth: CGFloat = MynahWidth.prose) -> some View {
        frame(maxWidth: maxWidth, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
    }

    /// Sets the text-size step for a whole subtree. Call once, at the window root.
    func mynahTextSize(_ size: MynahTextSize) -> some View {
        environment(\.mynahTypeDelta, size.delta)
    }
}

private struct MynahWordmarkModifier: ViewModifier {
    @Environment(\.mynahTypeDelta) private var delta

    func body(content: Content) -> some View {
        content
            .font(.system(size: 22 + delta, weight: .semibold, design: .rounded))
            .tracking(-0.35)
    }
}

// MARK: - Iconography

/// Five sizes. SF Symbols only, and `.hierarchical` from `.row` upwards — it
/// gives multi-shape symbols the depth Apple's own UI has for the price of one
/// modifier.
enum MynahIcon: Sendable {
    /// 12/semibold. Inside a pill, next to `.label` text.
    case inline
    /// 15/medium. List-row leading glyph.
    case row
    /// 18/medium. Card header glyph.
    case card
    /// 20/semibold. Inside a 44×44 glyph well.
    case well
    /// 30/medium. The single glyph on an onboarding stage or empty state.
    case hero

    /// Raised with the type scale, because glyphs are sized against the text
    /// they stand beside rather than in the abstract.
    ///
    /// A 20pt sidebar glyph next to a 17pt label was already deliberate. Beside
    /// the new 22pt label it reads as an afterthought — the icon has to lead,
    /// which is what "large icons" meant in the reference he sent. Each step
    /// keeps its old relationship to its neighbouring text size.
    var size: CGFloat {
        switch self {
        case .inline: return 13
        case .row: return 17
        case .card: return 22
        case .well: return 26
        case .hero: return 40
        }
    }

    var weight: Font.Weight {
        switch self {
        case .inline, .well: return .semibold
        case .row, .card, .hero: return .medium
        }
    }

    var font: Font { .system(size: size, weight: weight) }

    /// `.inline` glyphs sit in a text run and must match its flat weight;
    /// everything larger gets depth.
    var renderingMode: SymbolRenderingMode {
        self == .inline ? .monochrome : .hierarchical
    }
}

extension Image {

    /// Applies a MYNAH icon token. Deliberately not size-scaled by
    /// `mynahTypeDelta`: glyph wells are fixed-size, and a growing symbol inside
    /// a fixed well clips.
    func mynahIcon(_ token: MynahIcon) -> some View {
        font(token.font).symbolRenderingMode(token.renderingMode)
    }
}

/// The one glyph-well definition in the app.
///
/// QuietType has six different wells (32 unfilled, 36 at radius 9, 46 material
/// circle, 54 white circle, 74 tile, 104 ring) which is why no two of its cards
/// look related.
struct GlyphWell: View {
    enum Size: Sendable {
        /// 32×32 — list rows.
        case row
        /// 44×44 — cards and stages.
        case card

        var side: CGFloat { self == .row ? 32 : 44 }
        var icon: MynahIcon { self == .row ? .row : .well }
    }

    let systemName: String
    var size: Size = .card
    /// Marks the active or selected thing. Swaps the well to `accent.wash` and
    /// the symbol to `accent.ink` — the only colour a well ever takes.
    var isActive: Bool = false

    init(_ systemName: String, size: Size = .card, isActive: Bool = false) {
        self.systemName = systemName
        self.size = size
        self.isActive = isActive
    }

    var body: some View {
        Image(systemName: systemName)
            .mynahIcon(size.icon)
            .foregroundStyle(isActive ? Palette.accent.ink : Palette.ink.secondary)
            .frame(width: size.side, height: size.side)
            .background(
                isActive ? Palette.accent.wash : Palette.surface.well,
                in: RoundedRectangle.mynah(r.control)
            )
    }
}

/// The single hero glyph on a stage or empty state. The only `Circle()` well in
/// the app.
struct HeroGlyph: View {
    let systemName: String
    var tone: Tone = .accent

    enum Tone: Sendable {
        /// Onboarding stage — accent wash, accent glyph.
        case accent
        /// Empty state — no fill, quaternary glyph, nothing else iconic on screen.
        case quiet
    }

    init(_ systemName: String, tone: Tone = .accent) {
        self.systemName = systemName
        self.tone = tone
    }

    var body: some View {
        Image(systemName: systemName)
            .mynahIcon(.hero)
            .foregroundStyle(tone == .accent ? Palette.accent.ink : Palette.ink.quaternary)
            .frame(width: 72, height: 72)
            .background {
                if tone == .accent {
                    Circle().fill(Palette.accent.wash)
                }
            }
    }
}

// MARK: - Motion

/// Three curves. Nothing else animates in MYNAH.
///
/// QuietType has zero springs in 14,556 lines and seven ease durations; macOS
/// itself has almost nothing but springs. `response: 0.34, dampingFraction: 0.86`
/// overshoots ~2% and settles in ~0.42s — the profile of sheet presentation and
/// Finder's sidebar reveal.
enum Motion {
    /// Position, size, insertion, removal.
    static let snap = Animation.spring(response: 0.34, dampingFraction: 0.86)
    /// Opacity, colour, stroke, hover.
    static let fade = Animation.easeOut(duration: 0.18)
    /// Press, level meters, cursors.
    static let hair = Animation.easeOut(duration: 0.10)
}

private struct MynahAnimationModifier<V: Equatable>: ViewModifier {
    let animation: Animation
    let value: V
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content.animation(reduceMotion ? nil : animation, value: value)
    }
}

extension View {

    /// `.animation(_:value:)` that already honours reduce-motion, so honouring it
    /// is not a thing an agent can forget at one of forty call sites.
    func mynahAnimation<V: Equatable>(_ animation: Animation, value: V) -> some View {
        modifier(MynahAnimationModifier(animation: animation, value: value))
    }

    /// The stage-advance transition: a 14pt parallax, not a full-width slide.
    /// A page-width slide reads as a slideshow; 14pt reads as considered.
    func mynahStageTransition() -> some View {
        transition(
            .asymmetric(
                insertion: .offset(x: 14).combined(with: .opacity),
                removal: .offset(x: -14).combined(with: .opacity)
            )
        )
    }
}

// MARK: - Elevation

/// Two shadows. A static card gets none — `surface.raised` plus a hairline is
/// what separates a considered layout from a bevelled one.
enum MynahShadow: Sendable {
    /// Cards that are draggable, selectable or otherwise interactive.
    case card
    /// Sheets, popovers and the HUD. Never combined with a second stroke.
    case float

    var color: Color {
        switch self {
        case .card: return Color.mynah(light: .mynahMono(0, 0.06), dark: .mynahMono(0, 0.32))
        case .float: return Color.mynah(light: .mynahMono(0, 0.16), dark: .mynahMono(0, 0.48))
        }
    }

    var radius: CGFloat { self == .card ? 10 : 30 }
    var y: CGFloat { self == .card ? 3 : 14 }
}

extension View {

    /// `.compositingGroup()` first, so a view with internal transparency casts
    /// one shadow rather than one per sublayer.
    func mynahShadow(_ shadow: MynahShadow) -> some View {
        compositingGroup().shadow(color: shadow.color, radius: shadow.radius, y: shadow.y)
    }

    /// A resting hairline border. `.strokeBorder`, never `.stroke`: `.stroke`
    /// centres the line on the path so half of every 1pt border is clipped away
    /// by the shape, producing a sub-pixel edge that reads blurry at 1× and thin
    /// at 2×. Invisible once; obvious across fifty cards.
    func mynahBorder(_ radius: CGFloat, _ color: Color = Palette.line.hairline, width: CGFloat = 1) -> some View {
        overlay(RoundedRectangle.mynah(radius).strokeBorder(color, lineWidth: width))
    }
}

// MARK: - Materials
//
// MARK: Live — and the two rules the glass imposes on whatever sits on it
//
// `MynahVisualEffect` and `MynahGlassBackground` are the chrome of the floating
// HUD in `Main/FloatingHUD.swift` — the panel that shows what MYNAH is doing
// once the owner closes the window, which is the capability promised in the
// welcome copy, on the Ready stage, in Settings and in `AppModel`'s own doc
// comment. `MynahVisualEffect` is also what the sidebar would use if
// `.listStyle(.sidebar)` ever stopped supplying vibrancy for free.
//
// **Text on this glass is bound by two measured rules.** Behind-window vibrancy
// composites the owner's *desktop*, so there is no single background colour to
// quote a ratio against; what can be quoted is the floor — the glass composited
// over the worst wallpaper for the scheme (pure white behind dark mode, pure
// black behind light mode), which is where legibility bottoms out.
//
//   1. Sentences take `ink.primary` and nothing softer. At the floor,
//      `ink.primary` measures 5.1:1 dark / 10.3:1 light, and `ink.secondary`
//      measures 3.7:1 dark / 4.2:1 light — under 4.5:1 in both, which is why the
//      transcript's habit of dropping to `secondary` for a supporting line does
//      not survive the move onto glass.
//   2. Nothing readable goes in the top 32pt. The sheen below is a 42pt band
//      running 0.48 → 0.14 → clear white, and at its hottest a dark-mode
//      backdrop composites to ~2.2:1 even for `ink.primary`. By y = 32 the sheen
//      is down to ~0.07 alpha and the floor is back to 5.1:1, so the HUD simply
//      insets its content by `s8` and leaves the band as the lip of the glass.
//
// `MynahShadow.float` stays a *sheet and popover* token and is deliberately not
// used by the HUD: a real `NSWindow` gets AppKit's own shadow, derived from the
// content's alpha channel and moved by the window server as the panel is
// dragged. Drawing `.float` there instead would mean padding the panel frame by
// 30pt of transparent window on every side, and that halo swallows clicks meant
// for the app behind it. `MynahThemeGallery` exercises `.float` on every build.

/// Real desktop vibrancy. Used in exactly three places: the sidebar, the
/// floating HUD, and popovers (which get it free). A `.regularMaterial` card
/// inside an opaque window blurs nothing and just looks washed out.
struct MynahVisualEffect: NSViewRepresentable {
    var material: NSVisualEffectView.Material = .sidebar
    var blendingMode: NSVisualEffectView.BlendingMode = .behindWindow
    var isEmphasized: Bool = true

    /// When the vibrancy is allowed to dim.
    ///
    /// `.followsWindowActiveState` is what makes the sidebar grey out when the
    /// window loses key — a detail people never name but always notice. The
    /// floating HUD is the exact opposite case: it is a non-activating panel
    /// whose whole job is to be watched *while the owner works in another app*,
    /// so it is almost never key. Left on the default it would render in the
    /// inactive variant permanently — the flat, washed-out look that vibrancy
    /// exists to avoid — so that one surface passes `.active`.
    var state: NSVisualEffectView.State = .followsWindowActiveState

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        apply(to: view)
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        apply(to: nsView)
    }

    private func apply(to view: NSVisualEffectView) {
        view.material = material
        view.blendingMode = blendingMode
        view.state = state
        view.isEmphasized = isEmphasized
    }
}

/// The HUD glass recipe, ported from the one genuinely expensive component in
/// QuietType. Five stacked fills plus a top sheen and a gradient border; this is
/// the only place in MYNAH where bare `Color.white`/`Color.black` are correct,
/// because they are specular highlights over a material rather than surfaces.
///
/// Read the two contrast rules above before putting text on it.
struct MynahGlassBackground: View {
    @Environment(\.colorScheme) private var colorScheme
    var radius: CGFloat = r.sheet

    /// Passed through to the vibrancy layer. See `MynahVisualEffect.state` —
    /// a floating panel has to force `.active` or its glass never lights up.
    var vibrancyState: NSVisualEffectView.State = .followsWindowActiveState

    /// Whether the glass draws the drop shadow that finishes the recipe.
    ///
    /// True inside a window, where nothing else will draw one. False when the
    /// glass *is* a window: AppKit derives a shadow from a borderless window's
    /// alpha channel for free, and stacking a second one under it would need
    /// 30pt of transparent frame all round to avoid being clipped — a halo that
    /// then eats clicks aimed at whatever is behind the panel.
    var castsShadow: Bool = true

    var body: some View {
        let shape = RoundedRectangle.mynah(radius)
        let isDark = colorScheme == .dark
        return ZStack {
            MynahVisualEffect(material: .hudWindow, blendingMode: .behindWindow, state: vibrancyState)
            shape.fill(Color.white.opacity(isDark ? 0.02 : 0.04))
            shape.fill(Color.white.opacity(isDark ? 0.08 : 0.16))
            shape.fill(
                LinearGradient(
                    colors: [
                        Color.white.opacity(0.40),
                        Color.white.opacity(0.14),
                        .clear,
                        Color.black.opacity(isDark ? 0.22 : 0.08)
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            )
            shape
                .fill(
                    RadialGradient(
                        colors: [
                            Color.white.opacity(0.42),
                            Color.white.opacity(0.12),
                            .clear
                        ],
                        center: .topLeading,
                        startRadius: 0,
                        endRadius: 190
                    )
                )
                .blendMode(.screen)
                .mask(
                    LinearGradient(
                        colors: [Color.white, Color.white.opacity(0.35), .clear],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
        }
        .clipShape(shape)
        .overlay(alignment: .topLeading) {
            shape
                .fill(
                    LinearGradient(
                        colors: [Color.white.opacity(0.48), Color.white.opacity(0.14), .clear],
                        startPoint: .topLeading,
                        endPoint: .bottom
                    )
                )
                .frame(height: 42)
                .allowsHitTesting(false)
        }
        .overlay(
            shape.strokeBorder(
                LinearGradient(
                    colors: [
                        Color.white.opacity(0.94),
                        Color.white.opacity(0.38),
                        Color.black.opacity(isDark ? 0.24 : 0.16)
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                ),
                lineWidth: 0.8
            )
        )
        .compositingGroup()
        // `.clear` rather than an `if`: branching the modifier chain would give
        // the glass two identities and rebuild the whole stack — including the
        // `NSVisualEffectView` — the moment the flag changed.
        .shadow(
            color: castsShadow ? Color.black.opacity(isDark ? 0.26 : 0.12) : .clear,
            radius: 22,
            y: 10
        )
    }
}

// MARK: - Cursor

/// A cursor rect, not a `push`/`pop` pair on hover — those go out of balance the
/// moment a view is removed while the pointer is inside it, and the owner is
/// left with a pointing hand over their whole desktop.
private struct PointingHandCursorLayer: NSViewRepresentable {
    final class CursorView: NSView {
        override func resetCursorRects() {
            discardCursorRects()
            addCursorRect(bounds, cursor: .pointingHand)
        }

        // Cursor rects are computed from the view tree, not from hit testing, so
        // refusing hits here keeps clicks flowing to the SwiftUI content beneath.
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }

    func makeNSView(context: Context) -> NSView { CursorView() }

    func updateNSView(_ nsView: NSView, context: Context) {
        nsView.window?.invalidateCursorRects(for: nsView)
    }
}

extension View {
    /// Pointing-hand cursor over a clickable card or row.
    func pointingHandCursor(_ enabled: Bool = true) -> some View {
        overlay { if enabled { PointingHandCursorLayer() } }
    }
}

// MARK: - Window plumbing

/// Reaches the `NSWindow` behind a SwiftUI scene so the titlebar can change
/// between onboarding and the app proper. Scene modifiers are static for the
/// lifetime of the scene; this is the only way to move between a hidden titlebar
/// (which makes a stage screen look like an app introducing itself) and a real
/// unified toolbar.
struct WindowConfigurator: NSViewRepresentable {
    var configure: (NSWindow) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        // The window is not attached during `makeNSView`; one runloop hop later
        // it is.
        DispatchQueue.main.async { [weak view] in
            guard let window = view?.window else { return }
            configure(window)
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        guard let window = nsView.window else { return }
        configure(window)
    }
}

extension View {
    func configureWindow(_ configure: @escaping (NSWindow) -> Void) -> some View {
        background(WindowConfigurator(configure: configure).frame(width: 0, height: 0))
    }
}

// MARK: - Theme preview

#Preview("Theme — tokens") {
    MynahThemeGallery()
        .frame(width: 900, height: 620)
}

/// Kept non-private so previews in other files can reuse the swatch layout.
struct MynahThemeGallery: View {
    var body: some View {
        HStack(spacing: 0) {
            gallery.environment(\.colorScheme, .light)
            gallery.environment(\.colorScheme, .dark)
        }
    }

    private var gallery: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: s8) {
                group("Surfaces") {
                    swatch("canvas", Palette.surface.canvas)
                    swatch("raised", Palette.surface.raised)
                    swatch("sunken", Palette.surface.sunken)
                    swatch("overlay", Palette.surface.overlay)
                }
                group("Ink") {
                    swatch("primary", Palette.ink.primary)
                    swatch("secondary", Palette.ink.secondary)
                    swatch("tertiary", Palette.ink.tertiary)
                    swatch("quaternary", Palette.ink.quaternary)
                }
                group("Accent & state") {
                    swatch("accent.fill", Palette.accent.fill)
                    swatch("accent.ink", Palette.accent.ink)
                    swatch("good", Palette.state.good)
                    swatch("critical", Palette.state.critical)
                }
                // The HUD chrome as it looks *inside a window* — glass drawing
                // its own `.float` shadow, which is the sheet-and-popover case.
                // The floating panel itself takes neither default: it forces
                // `.active` vibrancy and lets AppKit shadow the window. See the
                // note above `MynahVisualEffect`.
                VStack(alignment: .leading, spacing: s4) {
                    Text("HUD glass").mynahFont(.eyebrow).foregroundStyle(Palette.ink.tertiary)
                    Text("Answering")
                        .mynahFont(.title3)
                        .foregroundStyle(Palette.ink.primary)
                        .padding(.horizontal, s6)
                        .padding(.vertical, s5)
                        .frame(width: 320, alignment: .leading)
                        .background(MynahGlassBackground(castsShadow: false))
                        .mynahShadow(.float)
                }
                VStack(alignment: .leading, spacing: s4) {
                    Text("Type scale").mynahFont(.eyebrow).foregroundStyle(Palette.ink.tertiary)
                    Text("Where your words go").mynahFont(.display)
                    Text("Sheet title").mynahFont(.title1)
                    Text("Card title").mynahFont(.title2)
                    Text("List row").mynahFont(.title3)
                    Text("Body copy runs to about sixty-two characters a line.").mynahFont(.body)
                    Text("Secondary explanation").mynahFont(.callout)
                    Text("Field label").mynahFont(.label)
                    Text("Step 2 of 4").mynahFont(.eyebrow)
                    Text("18").mynahFont(.numeral)
                    Text("sk-ant-••••").mynahFont(.mono)
                }
                .foregroundStyle(Palette.ink.primary)
            }
            .padding(s8)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Palette.surface.canvas)
    }

    private func group<C: View>(_ title: String, @ViewBuilder content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: s4) {
            Text(title).mynahFont(.eyebrow).foregroundStyle(Palette.ink.tertiary)
            HStack(spacing: s3) { content() }
        }
    }

    private func swatch(_ name: String, _ color: Color) -> some View {
        VStack(alignment: .leading, spacing: s2) {
            RoundedRectangle.mynah(r.chip)
                .fill(color)
                .frame(width: 76, height: 44)
                .mynahBorder(r.chip)
            Text(name).mynahFont(.label).foregroundStyle(Palette.ink.tertiary)
        }
    }
}
