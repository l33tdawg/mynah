import XCTest
import AppKit
@testable import MynahMac

/// *"btw the mynah icon is upside down in task bar hahahahha"* — 7 August 2026,
/// with a screenshot of the menu bar showing the bust inverted.
///
/// **The cause is a coordinate-space mismatch that only the menu bar hits.**
/// `MynahBird` is a SwiftUI `Shape`, so its points are in SwiftUI's convention:
/// y increases downward. Read the drawing and it says so — the crown is at
/// y=248 and the shoulders run off at y=1000.
///
/// `MynahMenuBarIcon.render` drew that path into
/// `NSImage(size:flipped: false)`, and `flipped: false` is AppKit's own space,
/// where y increases *upward*. Every point therefore landed mirrored about the
/// horizontal axis: shoulders at the top, crown at the bottom, beak pointing
/// down.
///
/// Nothing else was affected, which is exactly why it survived. `MynahMark` —
/// the same `MynahBird`, in the sidebar and the setup screens — is rendered by
/// SwiftUI in SwiftUI's space and is correct. The Dock icon comes from
/// `scripts/make-icon.sh`, also through SwiftUI. The menu bar was the one place
/// the shape crossed into AppKit, and it was the one place nobody had a
/// second copy to compare against.
///
/// These tests assert the anatomy rather than the pixels: a mynah bust fills
/// the bottom of its tile — that is the crop the mark is designed around — and
/// tapers toward the crown. If it is ever the other way round, it is upside
/// down again.
final class TheMenuBarBirdIsTheRightWayUpTests: XCTestCase {

    /// Fraction of each pixel row that the mark covers, top row first.
    ///
    /// The image is a template, so it is drawn in flat black and the alpha
    /// channel is the shape. Rendered large: at the 16pt this actually ships
    /// at, a row is sixteen pixels and antialiasing dominates, which makes a
    /// threshold arbitrary. The geometry is scale-free, so measuring at 128
    /// tests the same thing without arguing about single pixels.
    private func rowCoverage(side: Int = 128) throws -> [Double] {
        let image = MynahMenuBarIcon.render(side: CGFloat(side))

        let rep = try XCTUnwrap(NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: side, pixelsHigh: side,
            bitsPerSample: 8, samplesPerPixel: 4,
            hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: side * 4, bitsPerPixel: 32
        ), "could not allocate a bitmap to render into")

        let context = try XCTUnwrap(
            NSGraphicsContext(bitmapImageRep: rep), "could not make a drawing context"
        )
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        image.draw(in: NSRect(x: 0, y: 0, width: side, height: side))
        NSGraphicsContext.restoreGraphicsState()

        // NSBitmapImageRep addresses row 0 as the TOP row, which is what makes
        // the returned array read top-down like the drawing does.
        var rows: [Double] = []
        for y in 0..<side {
            var covered = 0
            for x in 0..<side {
                let alpha = try XCTUnwrap(rep.colorAt(x: x, y: y)).alphaComponent
                if alpha > 0.5 { covered += 1 }
            }
            rows.append(Double(covered) / Double(side))
        }
        return rows
    }

    func testTheBustFillsTheBottomAndNotTheTop() throws {
        let rows = try rowCoverage()
        let side = rows.count
        let top = rows[0..<(side / 5)].reduce(0, +) / Double(side / 5)
        let bottom = rows[(side * 4 / 5)...].reduce(0, +) / Double(side - side * 4 / 5)

        // The drawing is a bust cropped by the tile: shoulders span x=92…946 of
        // 1024 at the bottom edge, while the top holds only the crown.
        XCTAssertGreaterThan(
            bottom, 0.7,
            "the bottom of the mark should be nearly full — that is the bust running off the tile"
        )
        XCTAssertLessThan(
            top, 0.5,
            "the top of the mark should be mostly empty — that is the crown, not the shoulders"
        )
        XCTAssertGreaterThan(
            bottom, top * 1.5,
            "upside down: the widest part of the bird is at the top of the icon"
        )
    }

    func testTheWidestPartIsTheShouldersAndTheNarrowestIsTheCrown() throws {
        let rows = try rowCoverage()
        let side = rows.count
        let bands = (0..<5).map { band -> Double in
            let range = (side * band / 5)..<(side * (band + 1) / 5)
            return rows[range].reduce(0, +) / Double(range.count)
        }

        // **Not monotonic growth, which is what this test asserted first and
        // was wrong about.** A mynah's neck genuinely narrows between the head
        // and the shoulders, so the measured profile is
        // [0.00, 0.37, 0.48, 0.44, 0.75] — band 2 is the head and beak, band 3
        // is the throat, and band 3 is legitimately narrower than band 2.
        // Requiring each band to be at least as wide as the one above it failed
        // on a correct drawing.
        //
        // What actually separates upright from inverted is the two ends. The
        // crown is a point and the shoulders run off the tile, so upright means
        // the bottom band is the widest of the five and the top is the
        // narrowest. Inverted swaps precisely those two, whatever the middle
        // does.
        XCTAssertEqual(
            bands.firstIndex(of: bands.max()!), 4,
            "the widest band should be the shoulders at the bottom \(bands)"
        )
        XCTAssertEqual(
            bands.firstIndex(of: bands.min()!), 0,
            "the narrowest band should be the crown at the top \(bands)"
        )
    }

    func testTheMarkIsATemplateSoTheMenuBarCanTintIt() {
        XCTAssertTrue(
            MynahMenuBarIcon.image.isTemplate,
            "without this the bird stays literal black and is a hole in a dark menu bar"
        )
    }

    func testTheShippingIconIsTheMenuBarGlyphBox() {
        XCTAssertEqual(MynahMenuBarIcon.image.size, NSSize(width: 16, height: 16))
    }
}
