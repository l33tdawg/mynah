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

    /// A mynah is near-black with a saturated warm-yellow eye patch. That patch
    /// is the entire accent, and it appears at most twice on any screen: the one
    /// recommended choice, and the one live thing.
    ///
    /// **Scope, decided once: these tokens are for MYNAH's own surfaces only.**
    /// Platform chrome — the sidebar's selection capsule, pop-up buttons,
    /// confirmation dialogs' default button — keeps the *system* accent the
    /// owner set in System Settings, because that is what every other Mac app on
    /// their machine does and overriding it is how a sidebar row ends up with a
    /// white label on yellow. So the app deliberately sets no root `.tint`.
    /// Anything MYNAH draws itself — a selected option card, the recommendation
    /// sparkle, a focus ring, a switch, a spinner inside one of our own fields —
    /// uses these. Having taken neither position is what could not ship; this is
    /// the position.
    enum accent {
        /// Selection fills, the recommendation marker, the listening ring.
        static let fill = Color.mynah(light: .mynahHex(0xF0A020), dark: .mynahHex(0xFFB833))
        /// Accent-coloured *text and glyphs*. Darkened in light mode so it keeps
        /// 5.1:1 against `surface.raised` — `accent.fill` as text would not.
        static let ink = Color.mynah(light: .mynahHex(0x8A5000), dark: .mynahHex(0xFFC451))
        /// Selected-row background, chip background.
        static let wash = Color.mynah(
            light: .mynahHex(0xF0A020, alpha: 0.12),
            dark: .mynahHex(0xFFB833, alpha: 0.16)
        )
        /// Anything sitting *on* `accent.fill`. Dark in both schemes, because
        /// the fill is light in both.
        static let onFill = Color.mynah(light: .mynahHex(0x1A1206), dark: .mynahHex(0x1A1206))
    }

    /// Deliberately disjoint from `accent`. Green means "your words stay here";
    /// yellow means "MYNAH is doing something". Conflating them would make the
    /// privacy signal indistinguishable from a spinner.
    enum state {
        static let good = Color.mynah(light: .mynahHex(0x1D8A4E), dark: .mynahHex(0x3FD07E))
        static let caution = Color.mynah(light: .mynahHex(0x9C5F00), dark: .mynahHex(0xF0A73B))
        static let critical = Color.mynah(light: .mynahHex(0xC0392B), dark: .mynahHex(0xFF6B5E))

        /// Low-alpha backgrounds for inline notes.
        static let goodWash = Color.mynah(
            light: .mynahHex(0x1D8A4E, alpha: 0.10),
            dark: .mynahHex(0x3FD07E, alpha: 0.12)
        )
        static let cautionWash = Color.mynah(
            light: .mynahHex(0x9C5F00, alpha: 0.10),
            dark: .mynahHex(0xF0A73B, alpha: 0.12)
        )
        static let criticalWash = Color.mynah(
            light: .mynahHex(0xC0392B, alpha: 0.09),
            dark: .mynahHex(0xFF6B5E, alpha: 0.12)
        )
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
enum r {
    /// Pills, chips, keycaps, tiny badges.
    static let chip: CGFloat = 7
    /// Buttons, text fields, list rows, segmented track.
    static let control: CGFloat = 10
    /// Cards, panels, wells, group containers.
    static let card: CGFloat = 14
    /// Sheets, floating HUD, modal overlays.
    static let sheet: CGFloat = 22
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
    /// The onboarding stage column.
    static let stageColumn: CGFloat = 520
    /// Prose inside that column — ~62 characters at 13pt.
    static let prose: CGFloat = 460
    /// A settings pane.
    static let settings: CGFloat = 640
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

    var size: CGFloat {
        switch self {
        case .display: return 32
        case .title1: return 22
        case .title2: return 17
        case .title3: return 15
        case .body, .bodyEmphasis: return 13
        case .callout, .mono: return 12
        case .label: return 11
        case .eyebrow: return 10
        case .numeral: return 28
        }
    }

    var weight: Font.Weight {
        switch self {
        case .display: return .bold
        case .title1, .title2, .title3, .eyebrow, .numeral: return .semibold
        case .body, .callout: return .regular
        case .bodyEmphasis, .label, .mono: return .medium
        }
    }

    /// SF Pro's default tracking is metrically correct at 13pt and visibly loose
    /// above 20pt. Apple's own display type is always tightened; without this
    /// every heading in the app is 3–4% wider than it should be.
    var tracking: CGFloat {
        switch self {
        case .display: return -0.6
        case .title1: return -0.35
        case .title2: return -0.2
        case .title3: return -0.1
        case .body, .bodyEmphasis, .mono: return 0
        case .callout: return 0.05
        case .label: return 0.15
        case .eyebrow: return 0.8
        case .numeral: return -0.4
        }
    }

    var lineSpacing: CGFloat {
        switch self {
        case .display: return 5
        case .title1, .body, .bodyEmphasis: return 4
        case .title2, .callout: return 3
        case .title3: return 2
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

    var size: CGFloat {
        switch self {
        case .inline: return 12
        case .row: return 15
        case .card: return 18
        case .well: return 20
        case .hero: return 30
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
// MARK: Dormant on purpose — read before wiring these in
//
// `MynahVisualEffect` and `MynahGlassBackground` below are not reachable from
// any shipping screen, and `MynahShadow.float` is unused for the same reason.
// Silent dead code in a style layer is how a design system rots, so this says
// why out loud rather than leaving it to be discovered.
//
// They exist for the floating HUD — the panel that shows what MYNAH is doing
// once the owner closes the window. That capability is *promised*, in the
// welcome copy, on the Ready stage, in Settings, and in `AppModel`'s own doc
// comment, and today the whole feedback surface for it is one template-rendered
// menu-bar glyph. There is no `NSPanel` anywhere in the app.
//
// TO LIGHT IT UP: build a `FloatingHUD` as an `NSPanel` with
// `[.borderless, .nonactivatingPanel]`, `level = .statusBar`,
// `isFloatingPanel = true`, a clear non-opaque background, `hasShadow = false`
// and `collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary,
// .ignoresCycle]`; host `MynahGlassBackground` plus a 40×40 `GlyphWell`, a
// `.title3` state line read off `AppModel.effectivePresence`, and the existing
// `Waveform`; persist its dragged position in `UserDefaults` and
// screen-intersection-check it on restore; and show it from `MynahAppDelegate`
// when the last window closes while `keepsAnsweringWhenClosed` is on.
//
// `MynahVisualEffect` is also what the sidebar would use if `.listStyle(.sidebar)`
// ever stopped supplying vibrancy for free. Both are compiled and exercised by
// `MynahThemeGallery` on every build, so neither can rot while it waits.

/// Real desktop vibrancy. Used in exactly three places: the sidebar, the
/// floating HUD, and popovers (which get it free). A `.regularMaterial` card
/// inside an opaque window blurs nothing and just looks washed out.
struct MynahVisualEffect: NSViewRepresentable {
    var material: NSVisualEffectView.Material = .sidebar
    var blendingMode: NSVisualEffectView.BlendingMode = .behindWindow
    var isEmphasized: Bool = true

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
        // `.followsWindowActiveState` is what makes the sidebar dim when the
        // window loses key — a detail people never name but always notice.
        view.state = .followsWindowActiveState
        view.isEmphasized = isEmphasized
    }
}

/// The HUD glass recipe, ported from the one genuinely expensive component in
/// QuietType. Five stacked fills plus a top sheen and a gradient border; this is
/// the only place in MYNAH where bare `Color.white`/`Color.black` are correct,
/// because they are specular highlights over a material rather than surfaces.
struct MynahGlassBackground: View {
    @Environment(\.colorScheme) private var colorScheme
    var radius: CGFloat = r.sheet

    var body: some View {
        let shape = RoundedRectangle.mynah(radius)
        let isDark = colorScheme == .dark
        return ZStack {
            MynahVisualEffect(material: .hudWindow, blendingMode: .behindWindow)
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
        .shadow(color: Color.black.opacity(isDark ? 0.26 : 0.12), radius: 22, y: 10)
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
                    swatch("caution", Palette.state.caution)
                    swatch("critical", Palette.state.critical)
                }
                // The dormant HUD chrome, kept on screen so it cannot rot while
                // it waits for the panel that will host it. See the note above
                // `MynahVisualEffect`.
                VStack(alignment: .leading, spacing: s4) {
                    Text("Dormant — HUD glass").mynahFont(.eyebrow).foregroundStyle(Palette.ink.tertiary)
                    Text("Answering")
                        .mynahFont(.title3)
                        .foregroundStyle(Palette.ink.primary)
                        .padding(.horizontal, s6)
                        .padding(.vertical, s5)
                        .frame(width: 320, alignment: .leading)
                        .background(MynahGlassBackground())
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
