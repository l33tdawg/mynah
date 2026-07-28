import SwiftUI
import XCTest
@testable import MynahMac

/// The app's mark, which is the one drawing in this app that has a second copy.
///
/// `scripts/make-icon.sh` draws `resources/Mynah.icns` from the same curves, and
/// the two are kept in step by hand. Nothing here can catch them drifting apart
/// — only a person comparing the Dock icon to the sidebar can — so what these
/// assertions cover is the half that *is* mechanical and *is* silent: the
/// transform that maps the icon's 1024pt canvas onto whatever size the mark is
/// asked for. Get it wrong and the mark renders at the wrong size, or off the
/// edge of its own box, or as nothing at all. None of those throw, none log, and
/// a 26pt square is small enough that "slightly wrong" survives review.
@MainActor
final class MynahMarkTests: XCTestCase {

    /// The mark measures itself by the tile, not by the 1024 canvas, so that a
    /// 26pt mark is optically the same size as a 26pt symbol beside it. The
    /// ~100pt margin the canvas carries is only there for the icns' own drop
    /// shadow.
    func testTheTileIsCentredInTheCanvasWithRoomForItsShadow() {
        let canvas = MynahMarkGeometry.canvas
        let tile = MynahMarkGeometry.tile
        XCTAssertEqual(tile.midX, canvas / 2, accuracy: 0.001, "the tile is off-centre horizontally")
        XCTAssertEqual(tile.width, tile.height, accuracy: 0.001, "the tile is not square")
        XCTAssertLessThan(tile.width, canvas, "the tile fills the canvas, leaving no room for its shadow")
    }

    /// The macOS squircle at 824pt is radius 185. Expressed as a ratio so the
    /// corner survives every size — a fixed radius would make a 16pt mark a
    /// circle and a 64pt one a rectangle.
    func testTheCornerIsARatioRatherThanAFixedRadius() {
        XCTAssertEqual(MynahMarkGeometry.cornerRatio, 185 / 824, accuracy: 0.0001)
        for side in [16, 26, 64, 512] as [CGFloat] {
            let radius = side * MynahMarkGeometry.cornerRatio
            XCTAssertLessThan(radius, side / 2, "at \(side)pt the corner has eaten the whole tile")
            XCTAssertGreaterThan(radius, 0)
        }
    }

    // MARK: The transform

    /// A mark that draws nothing is a blank square, which reads as a loading
    /// state that never finished.
    func testBothShapesDrawSomething() {
        let box = CGRect(x: 0, y: 0, width: 100, height: 100)
        XCTAssertFalse(MynahBird().path(in: box).isEmpty, "the bird draws nothing")
        XCTAssertFalse(MynahEyePatch().path(in: box).isEmpty, "the eye patch draws nothing")
    }

    /// The bird is a bust drawn to be cropped: it fills its box horizontally,
    /// starts a fifth of the way down where the crown is, and runs off the
    /// bottom so the shoulders reach the rounded corners rather than leaving a
    /// pale crescent under each one.
    func testTheBirdFillsTheBoxItIsCroppedIn() {
        let side: CGFloat = 100
        let bounds = MynahBird().path(in: CGRect(x: 0, y: 0, width: side, height: side)).boundingRect

        XCTAssertLessThan(bounds.minX, 0.02 * side, "the bird does not reach the left edge")
        XCTAssertGreaterThan(bounds.maxX, 0.98 * side, "the bird does not reach the right edge")
        // The crown. Too high and the head is clipped; too low and the mark is a
        // shape sitting in the bottom half of an empty tile.
        XCTAssertGreaterThan(bounds.minY, 0.12 * side, "the crown is above the tile")
        XCTAssertLessThan(bounds.minY, 0.28 * side, "the head has sunk down the tile")
        XCTAssertGreaterThan(bounds.maxY, side, "the bust stops inside the tile instead of being cropped by it")
    }

    /// It is the bird's eye. Anywhere else on the tile it is a yellow smudge.
    func testTheEyePatchSitsInTheHead() {
        let side: CGFloat = 100
        let box = CGRect(x: 0, y: 0, width: side, height: side)
        let head = MynahBird().path(in: box).boundingRect
        let patch = MynahEyePatch().path(in: box).boundingRect

        XCTAssertTrue(head.contains(patch), "the eye patch is outside the bird")
        // Upper half, right of centre — a mynah in profile facing right.
        XCTAssertLessThan(patch.maxY, side / 2, "the eye patch has slipped below the beak")
        XCTAssertGreaterThan(patch.minX, side / 2, "the eye patch is on the back of the head")
        // Small enough to be a field mark rather than a cartoon eye.
        XCTAssertLessThan(patch.width * patch.height, 0.06 * side * side)
    }

    /// The whole reason the paths go through a transform rather than being drawn
    /// at one size: doubling the box has to double the drawing, or the mark is
    /// only correct at whatever size somebody last looked at.
    func testTheDrawingScalesWithItsBox() {
        let small = MynahBird().path(in: CGRect(x: 0, y: 0, width: 50, height: 50)).boundingRect
        let large = MynahBird().path(in: CGRect(x: 0, y: 0, width: 200, height: 200)).boundingRect

        XCTAssertEqual(large.minX, small.minX * 4, accuracy: 0.01)
        XCTAssertEqual(large.minY, small.minY * 4, accuracy: 0.01)
        XCTAssertEqual(large.width, small.width * 4, accuracy: 0.01)
        XCTAssertEqual(large.height, small.height * 4, accuracy: 0.01)
    }

    /// A shape laid out anywhere but the origin has to move with its box. This
    /// is the case a `ZStack` produces and the one an off-by-a-translation bug
    /// hides in, because at the origin the wrong transform looks right.
    func testTheDrawingFollowsItsBox() {
        let atOrigin = MynahBird().path(in: CGRect(x: 0, y: 0, width: 80, height: 80)).boundingRect
        let moved = MynahBird().path(in: CGRect(x: 37, y: 11, width: 80, height: 80)).boundingRect

        XCTAssertEqual(moved.minX, atOrigin.minX + 37, accuracy: 0.01)
        XCTAssertEqual(moved.minY, atOrigin.minY + 11, accuracy: 0.01)
        XCTAssertEqual(moved.size.width, atOrigin.size.width, accuracy: 0.01)
    }
}
