// **Mac-only, because it tests `MynahMac`.**
//
// `MynahMac` is the AppKit/SwiftUI half of this package, and Package.swift does
// not declare that target off Darwin — so the import below resolves on a Mac
// and nowhere else. The guard wraps the whole file rather than just the import,
// because every test in here drives a Mac type: a file that compiled down to an
// empty test class would let Linux report a green suite that ran nothing, which
// is the exact failure this branch exists to stop. See `coreTestDependencies`
// in Package.swift.
#if os(macOS)
import SwiftUI
import XCTest
@testable import MynahMac

/// Draws the composer row so somebody can look at it. Opt-in via
/// `MYNAH_RENDER_PNGS=1`.
///
/// **What this cannot draw, stated plainly rather than discovered later.**
/// `ImageRenderer` refuses anything AppKit-backed, and the composer is mostly
/// that: `TextField` comes out blank, `MynahButton` and the mic carry
/// `.pointingHandCursor()`. So the field is a `Text` at the same font and the
/// buttons are their chrome without the cursor modifier.
///
/// That makes this useful for exactly the three things the owner reported —
/// **where the text sits vertically, what colour the focus ring is, and whether
/// the mic reads as a mic to the left of a bigger Send** — because all three
/// are properties of the layout and the palette rather than of the live
/// controls. It says nothing about typing, growth past one line, or the gesture.
@MainActor
final class ComposerRenderHarness: XCTestCase {

    func testRenderComposer() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["MYNAH_RENDER_PNGS"] == "1", "opt-in")

        for scheme in [ColorScheme.light, .dark] {
            let sheet = VStack(alignment: .leading, spacing: s6) {
                label("Resting — one line, which is almost always")
                composer(text: "Ask Mynah something…", isPlaceholder: true, focused: false)

                label("Focused — the ring the owner called “the yellow box”")
                composer(text: "what did I say about the pricing page", focused: true)

                label("Recording")
                composer(text: "Release to send", recording: true)
            }
            .frame(width: 760)
            .padding(s7)
            .background(Palette.surface.canvas)
            .environment(\.colorScheme, scheme)

            let renderer = ImageRenderer(content: sheet)
            renderer.scale = 2
            guard let image = renderer.nsImage,
                  let tiff = image.tiffRepresentation,
                  let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:])
            else { return XCTFail("render produced nothing") }
            let url = URL(fileURLWithPath: "/tmp/composer-\(scheme == .light ? "light" : "dark").png")
            try png.write(to: url)
            print("wrote \(url.path)")
        }
    }

    private func label(_ text: String) -> some View {
        Text(text.uppercased())
            .mynahFont(.eyebrow)
            .foregroundStyle(Palette.ink.secondary)
    }

    /// The composer's own body, with the two unrenderable controls substituted
    /// and everything else — spacing, alignment, radii, colours — taken from
    /// the real thing by hand. Kept in step manually, which is the standing
    /// cost of reconstructing rather than rendering.
    private func composer(
        text: String,
        isPlaceholder: Bool = false,
        focused: Bool = false,
        recording: Bool = false
    ) -> some View {
        HStack(alignment: .center, spacing: s4) {
            Text(text)
                .mynahFont(.body)
                .foregroundStyle(isPlaceholder ? Palette.ink.tertiary : Palette.ink.primary)
            Spacer(minLength: s4)
            Image(systemName: recording ? "mic.fill" : "mic")
                .mynahIcon(.well)
                .foregroundStyle(recording ? Palette.accent.ink : Palette.ink.secondary)
                .frame(width: 30, height: 30)
                .background(
                    recording ? Palette.accent.wash : Color.clear,
                    in: RoundedRectangle.mynah(r.chip)
                )
            Text("Send")
                .mynahFont(.title3)
                .foregroundStyle(Palette.button.primaryInk)
                .padding(.horizontal, s6)
                .padding(.vertical, 8)
                .background(Palette.button.primaryFill, in: RoundedRectangle.mynah(r.control))
        }
        .frame(minHeight: 28)
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .background(Palette.surface.sunken, in: RoundedRectangle.mynah(r.card))
        .overlay {
            RoundedRectangle.mynah(r.card)
                .strokeBorder(
                    recording ? Palette.accent.fill : Palette.line.hairline,
                    lineWidth: 1
                )
        }
        .overlay {
            if focused && !recording {
                RoundedRectangle.mynah(r.card + 3)
                    .strokeBorder(Color.accentColor.opacity(0.55), lineWidth: 3)
                    .padding(-3)
            }
        }
    }
}
#endif  // os(macOS)
