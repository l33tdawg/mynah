import SwiftUI

// MARK: - The five drawings
//
// Setup is five screens with a 240pt column standing empty beside each of them.
// One SF Symbol per screen used that column to say nothing five times, so this
// file spends it on a single story instead: the same two objects — a phone and
// this Mac — appear throughout, stand on the same floor every time, and the
// small marks between them keep one meaning across all five screens. A dot is
// something in flight; a solid line is a link that stays up; the accent appears
// once per drawing and only on the thing that is alive. An owner who has read
// the welcome drawing can read the pairing drawing without being told what it is.
//
// All of it is `Shape` work. No image assets, nothing fetched, and no symbol
// carrying a whole drawing on its own: the app is notarised and has to be right
// on a machine that has never been online.

/// Every number in these drawings that is not a coordinate, and every colour
/// they are allowed to use.
private enum Mark {

    /// 200 inside the 240pt mark column. The 40pt of slack is not decoration —
    /// nothing here is measured by the layout engine, so a drawing sized to
    /// exactly fit is a drawing that clips the first time a number is off by two.
    static let canvas = CGSize(width: 200, height: 132)

    /// Every device stands on this line. It is what makes five separate
    /// compositions read as one continuing scene rather than five marks that
    /// happen to follow each other.
    static let floor: CGFloat = 104

    /// One stroke weight for every outline, so no object looks nearer than
    /// another.
    static let line: CGFloat = 1.5

    /// Outlines. `tertiary` is a marks-only ink, which is exactly what this is.
    static let outline = Palette.ink.tertiary
    /// What a device is made of. `surface.well` is ink at a low alpha, so it
    /// sits correctly on the stage's canvas in both schemes.
    static let body = Palette.surface.well
    /// Feet, links and the shelf — the parts that hold things up rather than
    /// the things themselves.
    static let quiet = Palette.ink.quaternary
    /// Anything travelling. Strong enough to be followed across a gap.
    static let moving = Palette.ink.secondary
    /// The one live thing in a drawing. Never more than one.
    static let live = Palette.accent.fill
    /// The accent where it has to hold a shape rather than a fill — darkened in
    /// light mode, so a 2.5pt stroke still reads.
    static let liveInk = Palette.accent.ink

    // A Mac is a screen with a foot under it. These proportions are shared so
    // the machine is recognisably the same object at every size it is drawn at.

    /// 0.62 of the width: a laptop screen, not a monitor and not a phone lying
    /// on its side.
    static func macScreen(_ width: CGFloat) -> CGFloat { (width * 0.62).rounded() }
    static let macFootGap: CGFloat = 5
    static let macFoot: CGFloat = 5
    static func macHeight(_ width: CGFloat) -> CGFloat { macScreen(width) + macFootGap + macFoot }

    /// Where to centre a Mac so it stands on the floor.
    static func macCentre(_ width: CGFloat) -> CGFloat { floor - macHeight(width) / 2 }

    /// 1.75 of the width — a phone held upright.
    static func phoneHeight(_ width: CGFloat) -> CGFloat { (width * 1.75).rounded() }
    static func phoneCentre(_ width: CGFloat) -> CGFloat { floor - phoneHeight(width) / 2 }
}

// MARK: - The two objects

/// This Mac, with whatever it happens to be doing shown on its screen.
///
/// The foot is drawn wider than the screen because a laptop seen from the front
/// is wider at the base; without it the shape is just a rounded rectangle and
/// could be anything.
private struct MacMark<Screen: View>: View {
    let width: CGFloat
    let screen: Screen

    init(width: CGFloat, @ViewBuilder screen: () -> Screen) {
        self.width = width
        self.screen = screen()
    }

    var body: some View {
        VStack(spacing: Mark.macFootGap) {
            RoundedRectangle.mynah(r.control)
                .fill(Mark.body)
                .frame(width: width, height: Mark.macScreen(width))
                .mynahBorder(r.control, Mark.outline, width: Mark.line)
                .overlay { screen }
            Capsule()
                .fill(Mark.quiet)
                .frame(width: width + 12, height: Mark.macFoot)
        }
    }
}

extension MacMark where Screen == EmptyView {
    /// A Mac that is not doing anything on this screen.
    init(width: CGFloat) {
        self.init(width: width) { EmptyView() }
    }
}

/// The owner's phone.
private struct PhoneMark: View {
    let width: CGFloat

    var body: some View {
        RoundedRectangle.mynah(r.chip)
            .fill(Mark.body)
            .frame(width: width, height: Mark.phoneHeight(width))
            .mynahBorder(r.chip, Mark.outline, width: Mark.line)
            .overlay(alignment: .top) {
                // The earpiece slot. It is the only detail on the phone, and it
                // is there because without it a tall rounded rectangle reads as
                // a card rather than a handset.
                Capsule()
                    .fill(Mark.outline)
                    .frame(width: (width * 0.34).rounded(), height: 2)
                    .padding(.top, 6)
            }
    }
}

// MARK: - Welcome

/// The whole product in one picture: you speak into your phone, and this Mac is
/// what hears it.
///
/// Left to right, because that is the order it happens in. The phone is small
/// and the Mac is large — the phone is the thing you hold, the Mac is the thing
/// that does the work, and the difference in size says which is which without a
/// label.
private struct WelcomeDrawing: View {
    // The same two sizes the pairing drawing uses, so the later screen is
    // recognisably these two objects again rather than a similar pair.
    private let macWidth: CGFloat = 96
    private let phoneWidth: CGFloat = 36

    /// Four bars, tall in the middle: the shape of a voice note in every
    /// messaging app the owner has ever used, which is the point.
    private let voiceBars: [CGFloat] = [8, 17, 12, 6]

    var body: some View {
        ZStack {
            PhoneMark(width: phoneWidth)
                .position(x: 24, y: Mark.phoneCentre(phoneWidth))

            // Sitting between the two devices rather than against either one, so
            // it reads as crossing the gap rather than belonging to the phone.
            HStack(spacing: 6) {
                ForEach(voiceBars, id: \.self) { height in
                    Capsule()
                        .fill(Mark.live)
                        .frame(width: 3, height: height)
                }
            }
            .position(x: 67, y: 70)

            MacMark(width: macWidth)
                .position(x: 140, y: Mark.macCentre(macWidth))
        }
    }
}

// MARK: - Brain

/// The one choice on the screen: the thinking stays in this Mac, or it goes
/// somewhere else.
///
/// The two destinations are drawn with the same stroke, the same fill and the
/// same three marks, because the owner may quite reasonably pick either and a
/// drawing that pre-judged it would be arguing with the screen it sits beside.
/// This is also the only drawing with no accent in it: the accent means "the one
/// recommended thing", and nothing here is recommended.
private struct BrainDrawing: View {
    private let macWidth: CGFloat = 96

    /// The gap between the two machines, crossed in three steps. Points rather
    /// than a stroked path so the marks are the same dots that sit inside the
    /// Mac — the same thing, in one place or the other.
    private let trail: [CGPoint] = [
        CGPoint(x: 113, y: 45),
        CGPoint(x: 123, y: 41),
        CGPoint(x: 133, y: 37)
    ]

    var body: some View {
        ZStack {
            // Somewhere else: the same family of shape, smaller and higher up,
            // which is distance rather than menace. It is deliberately not a
            // cloud and deliberately not locked.
            RoundedRectangle.mynah(r.control)
                .fill(Mark.body)
                .frame(width: 54, height: 38)
                .mynahBorder(r.control, Mark.outline, width: Mark.line)
                .position(x: 164, y: 30)

            MacMark(width: macWidth) {
                HStack(spacing: 7) {
                    ForEach(0..<3) { _ in
                        Circle().fill(Mark.moving).frame(width: 5, height: 5)
                    }
                }
            }
            .position(x: 58, y: Mark.macCentre(macWidth))

            ForEach(Array(trail.enumerated()), id: \.offset) { _, point in
                Circle()
                    .fill(Mark.moving)
                    .frame(width: 5, height: 5)
                    .position(point)
            }
        }
    }
}

// MARK: - Connect

/// The key, drawn inside the machine that keeps it.
///
/// The screen's promise is that the key stays on this Mac and is never shown
/// again, so the key is drawn held rather than handed over. It is the only
/// object in the flow shown at this size, because on this screen it is the whole
/// subject.
private struct ConnectDrawing: View {
    private let macWidth: CGFloat = 132

    var body: some View {
        ZStack {
            MacMark(width: macWidth) { key }
                .position(x: 100, y: Mark.macCentre(macWidth))
        }
    }

    /// Bow, shaft, two teeth, laid out in a 76×26 box. The pieces overlap by a
    /// point or two on purpose: a key that comes apart at the joins looks like
    /// three unrelated shapes.
    private var key: some View {
        ZStack {
            Circle()
                .strokeBorder(Mark.liveInk, lineWidth: 2.5)
                .frame(width: 24, height: 24)
                .position(x: 12, y: 13)
            Capsule()
                .fill(Mark.liveInk)
                .frame(width: 48, height: 4)
                .position(x: 46, y: 13)
            tooth.position(x: 54, y: 17.5)
            tooth.position(x: 64, y: 17.5)
        }
        .frame(width: 76, height: 26)
    }

    private var tooth: some View {
        RoundedRectangle.mynah(1.5)
            .fill(Mark.liveInk)
            .frame(width: 3.5, height: 9)
    }
}

// MARK: - Phone

/// The two devices, joined.
///
/// The same pair as the welcome drawing and deliberately closer together, facing
/// each other rather than pointing one at the other: this screen is about the
/// two of them being a set, not about anything travelling yet. The link is a
/// solid line for the same reason the welcome drawing used dots — one is a thing
/// in flight, the other is a connection that stays up — and the single accent
/// dot at its middle is the joint itself.
private struct PhoneDrawing: View {
    private let macWidth: CGFloat = 96
    private let phoneWidth: CGFloat = 36

    /// Level with both bodies rather than with either centre, so the line
    /// touches the two devices at a height that exists on both of them.
    private let linkY: CGFloat = 68

    var body: some View {
        ZStack {
            MacMark(width: macWidth)
                .position(x: 60, y: Mark.macCentre(macWidth))

            // Long enough to touch both bodies. A link drawn with a gap at
            // either end is a link that has not been made.
            Capsule()
                .fill(Mark.quiet)
                .frame(width: 44, height: 2)
                .position(x: 130, y: linkY)
            Circle()
                .fill(Mark.live)
                .frame(width: 8, height: 8)
                .position(x: 130, y: linkY)

            PhoneMark(width: phoneWidth)
                .position(x: 170, y: Mark.phoneCentre(phoneWidth))
        }
    }
}

// MARK: - Ready

/// Nothing happening, on purpose.
///
/// The end of a setup flow is where most apps put a tick and a celebration. This
/// is an appliance that will sit in someone's house holding their private
/// conversations, so it gets the opposite: one machine, settled onto a shelf,
/// with a small light on it. The rings are quiet enough to read as "listening"
/// rather than "transmitting".
private struct ReadyDrawing: View {
    private let macWidth: CGFloat = 108

    var body: some View {
        ZStack {
            // The shelf. It is the only line in the five drawings that is wider
            // than the object standing on it, and it is what turns "a Mac" into
            // "a Mac that has been put somewhere".
            Capsule()
                .fill(Mark.quiet)
                .frame(width: 176, height: 1)
                .position(x: 100, y: 108)

            MacMark(width: macWidth) { listening }
                .position(x: 100, y: Mark.macCentre(macWidth))
        }
    }

    /// A lit point and two rings around it. The rings are the accent at a low
    /// alpha rather than a second colour, so this stays one mark rather than
    /// becoming a glow.
    private var listening: some View {
        ZStack {
            Circle()
                .strokeBorder(Mark.live.opacity(0.30), lineWidth: 1.5)
                .frame(width: 40, height: 40)
            Circle()
                .strokeBorder(Mark.live.opacity(0.60), lineWidth: 1.5)
                .frame(width: 24, height: 24)
            Circle()
                .fill(Mark.live)
                .frame(width: 7, height: 7)
        }
    }
}

// MARK: - The illustration

/// The drawing that stands in a setup stage's mark column.
///
/// Nothing moves. A drawing that breathed would be noticed exactly once — the
/// first time, by someone who is trying to read the sentence beside it.
struct StageIllustration: View {

    /// One per stage of the setup flow, in the order they are seen.
    enum Subject: String, CaseIterable, Sendable {
        case welcome
        case brain
        case connect
        case phone
        case ready
    }

    let subject: Subject

    init(_ subject: Subject) {
        self.subject = subject
    }

    var body: some View {
        drawing
            .frame(width: Mark.canvas.width, height: Mark.canvas.height)
            // It restates the screen it sits on and adds nothing a screen reader
            // could act on, so it stays out of the way of the title and the copy
            // that carry the actual meaning.
            .accessibilityHidden(true)
    }

    @ViewBuilder
    private var drawing: some View {
        switch subject {
        case .welcome: WelcomeDrawing()
        case .brain: BrainDrawing()
        case .connect: ConnectDrawing()
        case .phone: PhoneDrawing()
        case .ready: ReadyDrawing()
        }
    }
}

// MARK: - Asking for one

extension StageIllustration {

    /// A colon, because no SF Symbol name contains one. That is what makes a
    /// request for a drawing impossible to confuse with a request for a symbol,
    /// in either direction.
    private static let markPrefix = "stage:"

    /// What a stage passes to `StageShell(glyph:)` when it wants a drawing
    /// rather than a symbol.
    static func mark(_ subject: Subject) -> String { markPrefix + subject.rawValue }

    /// The drawing a mark name asks for, or nothing if it names a symbol.
    static func subject(named mark: String) -> Subject? {
        guard mark.hasPrefix(markPrefix) else { return nil }
        return Subject(rawValue: String(mark.dropFirst(markPrefix.count)))
    }
}

/// Whatever stands in a stage's mark column.
///
/// `StageShell` takes one name for its mark. The five stages of the setup story
/// pass `StageIllustration.mark(_:)` and get a drawing; everything else that
/// borrows the stage layout — the microphone screen, the "nothing to connect"
/// detour — still names an SF Symbol and still gets the hero glyph, because a
/// one-off screen has no place in a story told across five.
struct StageMark: View {
    let name: String

    init(_ name: String) {
        self.name = name
    }

    var body: some View {
        if let subject = StageIllustration.subject(named: name) {
            StageIllustration(subject)
        } else {
            HeroGlyph(name)
        }
    }
}

// MARK: - Previews

#Preview("Stage illustrations") {
    HStack(spacing: 0) {
        StageIllustrationGallery().environment(\.colorScheme, .light)
        StageIllustrationGallery().environment(\.colorScheme, .dark)
    }
    .frame(width: 720, height: 900)
}

/// Every drawing at the width it actually gets, in the column it actually sits
/// in. The tinted band behind each one is the column's own bounds — anything
/// crossing it on screen is overflowing in the app.
private struct StageIllustrationGallery: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: s7) {
                ForEach(StageIllustration.Subject.allCases, id: \.self) { subject in
                    VStack(alignment: .leading, spacing: s2) {
                        Text(subject.rawValue)
                            .mynahFont(.eyebrow)
                            .foregroundStyle(Palette.ink.tertiary)
                        StageIllustration(subject)
                            .frame(width: MynahWidth.stageMarkColumn, alignment: .leading)
                            .background(Palette.surface.well)
                    }
                }
            }
            .padding(s8)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Palette.surface.canvas)
    }
}
