import AppKit
import SwiftUI

// MARK: - The app's own mark
//
// The same bird as the Dock icon, drawn from the same curves.
//
// `scripts/make-icon.sh` draws `resources/Mynah.icns` from Swift source on a
// 1024pt canvas, and the paths below are those curves verbatim. Keeping them in
// sync by hand is a small tax; the alternative was worse in both directions.
// `NSImage(named: NSImage.applicationIconName)` returns the *generic* app icon
// for a process that is not in a bundle, so every preview and every `swift run`
// would have shown a blank sheet of paper where the mark should be — a preview
// that lies is how a design regression ships. Embedding a PNG would have put a
// second, staler copy of the drawing in the repository.
//
// So: vectors, no assets, correct at any size, correct on a machine that has
// never been online — the same reasoning `Style/StageIllustration.swift` gives
// for drawing the five setup marks rather than shipping pictures of them.

/// Every number the mark is built from, in the icon's own 1024pt coordinates.
///
/// Not private: the geometry is the part that silently breaks. A transform that
/// is off by a factor renders as a mark that is merely the wrong size — nothing
/// throws, nothing logs, and it is invisible until somebody opens the window.
enum MynahMarkGeometry {

    /// The design canvas the curves below were drawn on.
    static let canvas: CGFloat = 1024

    /// The tile itself. macOS 11+ app icons are an 824pt rounded tile centred in
    /// a 1024pt canvas; the ~100pt margin around it is where the tile's drop
    /// shadow lives. `MynahMark` sizes itself by the *tile*, not the canvas, so
    /// a 26pt mark is optically the same size as a 26pt SF Symbol beside it.
    static let tile = CGRect(x: 100, y: 90, width: 824, height: 824)

    /// 185 on the 824 tile. Expressed as a ratio so the corner stays the macOS
    /// squircle at every size the mark is drawn at.
    static let cornerRatio: CGFloat = 185 / 824

    /// Maps the icon's canvas coordinates onto a box of the given side.
    static func transform(toTileOfSide side: CGFloat, origin: CGPoint = .zero) -> CGAffineTransform {
        let scale = side / tile.width
        return CGAffineTransform(translationX: -tile.minX, y: -tile.minY)
            .concatenating(CGAffineTransform(scaleX: scale, y: scale))
            .concatenating(CGAffineTransform(translationX: origin.x, y: origin.y))
    }
}

/// A mynah in profile, head and shoulders, facing right.
///
/// Drawn as a bust that runs off the bottom of the tile rather than a silhouette
/// floating in the middle: the crop is what lets the head be large enough to
/// survive 16pt, and it removes the "sticker dropped on a square" look a centred
/// mark has at every size. The last points on each shoulder sit *outside* the
/// tile on purpose — the clip does the cropping, so the bust reaches the rounded
/// bottom corners instead of leaving a pale crescent under each shoulder.
struct MynahBird: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: 516, y: 248))                                  // crown
        path.addCurve(to: CGPoint(x: 652, y: 330),                              // brow
                      control1: CGPoint(x: 592, y: 248), control2: CGPoint(x: 628, y: 286))
        path.addCurve(to: CGPoint(x: 686, y: 386),                              // forehead
                      control1: CGPoint(x: 670, y: 348), control2: CGPoint(x: 682, y: 370))
        path.addCurve(to: CGPoint(x: 846, y: 446),                              // upper mandible
                      control1: CGPoint(x: 762, y: 388), control2: CGPoint(x: 816, y: 414))
        path.addCurve(to: CGPoint(x: 688, y: 484),                              // lower mandible
                      control1: CGPoint(x: 818, y: 478), control2: CGPoint(x: 756, y: 490))
        path.addCurve(to: CGPoint(x: 652, y: 570),                              // chin, throat
                      control1: CGPoint(x: 672, y: 514), control2: CGPoint(x: 658, y: 542))
        path.addCurve(to: CGPoint(x: 776, y: 786),                              // breast
                      control1: CGPoint(x: 646, y: 660), control2: CGPoint(x: 716, y: 722))
        path.addCurve(to: CGPoint(x: 946, y: 1000),                             // right shoulder
                      control1: CGPoint(x: 840, y: 842), control2: CGPoint(x: 906, y: 906))
        path.addLine(to: CGPoint(x: 92, y: 1000))
        path.addCurve(to: CGPoint(x: 256, y: 776),                              // left shoulder
                      control1: CGPoint(x: 128, y: 902), control2: CGPoint(x: 194, y: 828))
        path.addCurve(to: CGPoint(x: 346, y: 600),                              // nape
                      control1: CGPoint(x: 296, y: 730), control2: CGPoint(x: 336, y: 668))
        path.addCurve(to: CGPoint(x: 322, y: 430),                              // back of head
                      control1: CGPoint(x: 350, y: 540), control2: CGPoint(x: 322, y: 486))
        path.addCurve(to: CGPoint(x: 516, y: 248),                              // crown
                      control1: CGPoint(x: 322, y: 336), control2: CGPoint(x: 404, y: 248))
        path.closeSubpath()
        return path.applying(
            MynahMarkGeometry.transform(toTileOfSide: rect.width, origin: rect.origin)
        )
    }
}

/// The common mynah's bare yellow skin, which sits behind the eye and tapers
/// toward the nape.
///
/// Drawn rather than an ellipse: the taper is the whole difference between a
/// field mark and a cartoon eye.
struct MynahEyePatch: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: 692, y: 380))
        path.addCurve(to: CGPoint(x: 682, y: 452),
                      control1: CGPoint(x: 710, y: 406), control2: CGPoint(x: 704, y: 438))
        path.addCurve(to: CGPoint(x: 540, y: 428),
                      control1: CGPoint(x: 636, y: 466), control2: CGPoint(x: 578, y: 450))
        path.addCurve(to: CGPoint(x: 692, y: 380),
                      control1: CGPoint(x: 562, y: 388), control2: CGPoint(x: 628, y: 368))
        path.closeSubpath()
        return path.applying(
            MynahMarkGeometry.transform(toTileOfSide: rect.width, origin: rect.origin)
        )
    }
}

/// The mark as it appears inside the app.
///
/// **The one place in MYNAH where colours are literals rather than `Palette`
/// tokens, and the reason is that this is a logo.** Every token in `Palette`
/// flips with the system appearance, which is correct for a surface and wrong
/// for a mark: the Dock icon is a light tile with near-black plumage in dark
/// mode too, and a sidebar mark that inverted itself at sunset would be a
/// different logo twice a day. These are the icon's own values.
struct MynahMark: View {

    /// The side of the *tile*, matching how an SF Symbol beside it is measured.
    var side: CGFloat = 26

    init(side: CGFloat = 26) {
        self.side = side
    }

    /// Plumage, tile and the one accent, at the values `scripts/make-icon.sh`
    /// uses. `Palette.accent.fill` is this same yellow in light mode and a
    /// lighter one in dark; on a tile that never darkens, the light value is the
    /// only one that stays right.
    private enum Paint {
        // Black, asked for directly. It was a slate blue-grey (0x333E46 →
        // 0x101315) — the common mynah's actual plumage is nearer that than it
        // is to black, and at 26pt on a white tile it read as washed out rather
        // than as ornithology.
        //
        // Still a gradient rather than one flat fill: the silhouette has no
        // internal lines, so a single value turns the breast and the shoulder
        // into one shape. The range is just narrow enough now to read as black.
        static let plumageLight = Color(nsColor: .mynahHex(0x232323))
        static let plumageDark = Color(nsColor: .mynahHex(0x000000))
        static let tileTop = Color(nsColor: .mynahHex(0xFFFFFF))
        static let tileBottom = Color(nsColor: .mynahHex(0xF1F0ED))
        static let eyePatch = Color(nsColor: .mynahHex(0xF0A020))
        /// The icon's own hairline, which is what keeps a white tile from
        /// dissolving into a light sidebar.
        static let edge = Color(nsColor: .mynahHex(0xDCDAD5, alpha: 0.55))
    }

    var body: some View {
        let corner = side * MynahMarkGeometry.cornerRatio
        let tile = RoundedRectangle.mynah(corner)
        return ZStack {
            tile.fill(
                LinearGradient(
                    colors: [Paint.tileTop, Paint.tileBottom],
                    startPoint: UnitPoint(x: 0.18, y: 0.12),
                    endPoint: UnitPoint(x: 0.80, y: 0.88)
                )
            )

            ZStack {
                MynahBird()
                    .fill(
                        LinearGradient(
                            colors: [Paint.plumageLight, Paint.plumageDark],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                MynahEyePatch().fill(Paint.eyePatch)
            }
            // The pupil the icon draws at 32px and above is deliberately absent
            // here. At the sizes this mark is used it lands on a point and a
            // half of near-black inside near-black plumage, so it costs a shape
            // and shows nothing.
            .clipShape(tile)

            // Last, so it is a single hairline rather than a stroke competing
            // with the plumage's own edge.
            tile.strokeBorder(Paint.edge, lineWidth: 1)
        }
        .frame(width: side, height: side)
        // It is the app's name drawn instead of spelled, and the wordmark beside
        // it already says "Mynah" — announcing it twice is noise in VoiceOver.
        .accessibilityHidden(true)
    }
}

// MARK: - Previews

#Preview("Mark") {
    HStack(spacing: 0) {
        MynahMarkGallery().environment(\.colorScheme, .light)
        MynahMarkGallery().environment(\.colorScheme, .dark)
    }
    .frame(width: 700, height: 240)
}

/// Every size the mark is drawn at in the app, plus the ones either side of
/// them, because a mark that only survives one size is a picture rather than a
/// logo.
private struct MynahMarkGallery: View {
    var body: some View {
        VStack(alignment: .leading, spacing: s6) {
            Text("Mark").mynahFont(.eyebrow).foregroundStyle(Palette.ink.tertiary)
            HStack(alignment: .bottom, spacing: s6) {
                ForEach([16, 20, 26, 32, 64] as [CGFloat], id: \.self) { side in
                    MynahMark(side: side)
                }
            }
            HStack(spacing: s4) {
                MynahMark(side: 26)
                Text("Mynah").mynahWordmark().foregroundStyle(Palette.ink.primary)
            }
            Spacer(minLength: 0)
        }
        .padding(s8)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Palette.surface.canvas)
    }
}

// MARK: - Menu bar

/// The mark as a menu-bar template image.
///
/// *"we also don't have a system tray icon"* — there was one, drawing
/// `waveform`, `moon` or `exclamationmark.circle` depending on what the
/// appliance was doing. Which is to say there was an icon nobody recognised as
/// Mynah: a generic waveform in a bar full of generic glyphs is indistinguishable
/// from some other app's, so the owner looked for their bird, did not find it,
/// and reasonably concluded it was missing.
///
/// So it is the bird, always, and the state moved to where there is room for a
/// word — the menu's first line already reads "Mynah — listening". A silhouette
/// at 16pt cannot carry four states legibly anyway; it was three symbols
/// pretending to.
///
/// `isTemplate` is the whole trick: AppKit then tints it for a light bar, a dark
/// bar, and the inverted state while the menu is open, which is why this is a
/// filled silhouette with no eye patch and no colour. A mark that keeps its own
/// colours in the menu bar is the one that looks wrong there.
enum MynahMenuBarIcon {

    /// 16pt is the conventional menu-bar glyph box; the bird is drawn to the
    /// tile, so it fills it the way an SF Symbol would.
    static let image: NSImage = render(side: 16)

    static func render(side: CGFloat) -> NSImage {
        // **`flipped: true`, and the bird was upside down in the menu bar until
        // it was.** *"btw the mynah icon is upside down in task bar"* — 7 August
        // 2026, with a screenshot.
        //
        // `MynahBird` is a SwiftUI `Shape`, so its points are in SwiftUI's
        // convention, y increasing downward: the drawing above puts the crown at
        // y=248 and runs the shoulders off at y=1000. `flipped: false` asks for
        // AppKit's own space, where y increases *upward*, so every point landed
        // mirrored about the horizontal axis — shoulders along the top, crown at
        // the bottom, beak pointing down.
        //
        // It survived because this is the only place the shape crosses out of
        // SwiftUI. `MynahMark` draws the identical `MynahBird` in the sidebar
        // and the setup screens and is correct; `scripts/make-icon.sh` draws the
        // Dock icon through SwiftUI and is correct. With every other copy right,
        // there was nothing to compare the wrong one against, and at 16pt in a
        // menu bar an inverted silhouette reads as a slightly odd glyph rather
        // than as a bird facing the floor.
        //
        // Measured rather than reasoned about, because "which way does this
        // coordinate space go" is exactly the question everyone answers
        // confidently and wrongly: row coverage from top to bottom was
        // [0.76, 0.44, 0.47, 0.38, 0.005] before, and is the reverse of that
        // now. TheMenuBarBirdIsTheRightWayUpTests holds those numbers.
        let image = NSImage(size: NSSize(width: side, height: side), flipped: true) { rect in
            let path = MynahBird().path(in: rect)
            NSColor.black.setFill()
            NSBezierPath(cgPath: path.cgPath).fill()
            return true
        }
        // Without this the bird is drawn in literal black and stays black on a
        // dark menu bar, which is a hole where the icon should be.
        image.isTemplate = true
        return image
    }
}
