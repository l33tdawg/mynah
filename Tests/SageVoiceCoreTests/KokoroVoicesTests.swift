import XCTest
@testable import SageVoiceCore

/// **That the right 256 floats come out of a 28 MB archive.**
///
/// The style vector is the one input to the model that carries no redundancy.
/// The tokens are checkable by eye and the audio is checkable by ear, but a
/// style vector read from the wrong offset is 256 plausible-looking floats that
/// synthesize a real voice saying the right words with the wrong character —
/// and there is nothing in the output that points back at the parser.
///
/// So the expected values below are not derived from this implementation. They
/// were captured from `kokoro_onnx` at the moment it fed `session.run`, for two
/// sentences whose audio is on disk, and they are the only reason these tests
/// mean anything.
final class KokoroVoicesTests: XCTestCase {

    /// The real file, wherever this machine has it: the location `KokoroAssets`
    /// installs to first, then the lab directory it was originally measured in.
    private func archive() throws -> KokoroVoices {
        let candidates = [
            KokoroAssets.location(of: KokoroAssets.voices),
            URL(fileURLWithPath: "/Users/l33tdawg/sage-voice-lab/kokoro/voices-v1.0.bin")
        ]
        guard let found = candidates.first(where: { FileManager.default.fileExists(atPath: $0.path) }) else {
            throw XCTSkip("voices-v1.0.bin is not on this machine")
        }
        return try KokoroVoices(contentsOf: found)
    }

    // MARK: The golden vectors

    /// `am_michael` at row 53 — the style vector for "The quick brown fox jumps
    /// over the lazy dog." Its 53 unpadded tokens select this row.
    func testTheFoxSentenceStyleMatchesWhatPythonFedTheModel() throws {
        let style = try archive().style(for: "am_michael", tokenCount: 53)

        XCTAssertEqual(style.count, 256)

        let firstEight: [Float] = [
            -0.19103217, 0.17125607, -0.10292462, -0.20002307,
            -0.34329417, -0.16269895, -0.07197277, -0.21445279
        ]
        let lastEight: [Float] = [
            -0.21043296, -0.20595410, -0.34253886, 0.06970411,
            -0.14616387, -0.10796393, 0.13988893, 0.26682466
        ]

        for (index, expected) in firstEight.enumerated() {
            XCTAssertEqual(style[index], expected, accuracy: 1e-6, "float \(index)")
        }
        for (offset, expected) in lastEight.enumerated() {
            let index = 248 + offset
            XCTAssertEqual(style[index], expected, accuracy: 1e-6, "float \(index)")
        }
    }

    /// `am_michael` at row 7 — "Hello.", seven tokens. A second row of the same
    /// voice, because a reader that ignored `tokenCount` entirely would pass the
    /// test above.
    func testTheShortSentenceStyleMatchesADifferentRow() throws {
        let style = try archive().style(for: "am_michael", tokenCount: 7)

        let firstEight: [Float] = [
            -0.23967759, 0.17610180, -0.12917548, -0.16714133,
            -0.25939557, -0.17025118, -0.10939177, -0.22484148
        ]
        let lastEight: [Float] = [
            -0.30914873, -0.19867884, -0.31804919, 0.14732215,
            0.10523360, 0.06983010, 0.06094038, 0.31383547
        ]

        for (index, expected) in firstEight.enumerated() {
            XCTAssertEqual(style[index], expected, accuracy: 1e-6, "float \(index)")
        }
        for (offset, expected) in lastEight.enumerated() {
            XCTAssertEqual(style[248 + offset], expected, accuracy: 1e-6, "float \(248 + offset)")
        }
    }

    /// And explicitly: the two rows differ. This is the assertion that catches a
    /// reader returning row 0 regardless.
    func testDifferentTokenCountsSelectDifferentRows() throws {
        let voices = try archive()
        let short = try voices.style(for: "am_michael", tokenCount: 7)
        let long = try voices.style(for: "am_michael", tokenCount: 53)

        XCTAssertNotEqual(short, long, "the token count is being ignored")
    }

    /// Two voices at the same row must also differ, which catches a reader that
    /// resolves every name to the same member.
    func testDifferentVoicesAreDifferentData() throws {
        let voices = try archive()
        let michael = try voices.style(for: "am_michael", tokenCount: 20)
        let bella = try voices.style(for: "af_bella", tokenCount: 20)

        XCTAssertNotEqual(michael, bella, "every voice is resolving to the same member")
    }

    // MARK: The archive

    func testEveryVoiceInTheFileIsFound() throws {
        let names = try archive().names

        XCTAssertEqual(names.count, 54)
        XCTAssertTrue(names.contains("am_michael"), "the default voice is missing")
        XCTAssertTrue(names.contains("af_heart"))
        XCTAssertTrue(names.contains("zm_yunyang"), "the last voice alphabetically is missing")
        XCTAssertFalse(names.contains { $0.hasSuffix(".npy") }, "the member extension leaked into a name")
    }

    /// Every row must be readable, not just the two the golden vectors cover —
    /// an offset that is right at the start and drifts would otherwise pass.
    func testEveryRowIsReadable() throws {
        let voices = try archive()
        for row in [0, 1, 255, 508, KokoroVoices.styleRows - 1] {
            let style = try voices.style(for: "am_michael", tokenCount: row)
            XCTAssertEqual(style.count, 256, "row \(row)")
            XCTAssertTrue(style.allSatisfy { $0.isFinite }, "row \(row) contains garbage")
        }
    }

    /// Style vectors are small numbers. A misaligned read produces values in the
    /// 1e30 range or denormals, so this catches an off-by-a-few-bytes that the
    /// spot checks might straddle.
    func testEveryRowLooksLikeAStyleVectorRatherThanGarbage() throws {
        let voices = try archive()
        for row in stride(from: 0, to: KokoroVoices.styleRows, by: 37) {
            let style = try voices.style(for: "am_michael", tokenCount: row)
            let peak = style.map(abs).max() ?? 0
            XCTAssertLessThan(peak, 100, "row \(row) is not plausibly a style vector")
            XCTAssertGreaterThan(peak, 0.001, "row \(row) is empty")
        }
    }

    // MARK: Refusing

    func testAnUnknownVoiceIsNamedRatherThanGuessedAt() throws {
        // `archive()` outside the assertion, deliberately.
        //
        // It throws `XCTSkip` when `voices-v1.0.bin` is not on the machine —
        // and inside `XCTAssertThrowsError` that skip is caught as "an error
        // was thrown", so the closure then compared `XCTSkip` against
        // `.unknownVoice` and failed. The test reported a broken product on
        // every machine without the 28 MB asset, which is every fresh clone and
        // every CI runner.
        let voices = try archive()
        XCTAssertThrowsError(try voices.style(for: "am_nobody", tokenCount: 10)) { error in
            XCTAssertEqual(error as? KokoroVoices.Failure, .unknownVoice("am_nobody"))
        }
    }

    /// The array has 510 rows, so 510 is one past the end. This is the exact
    /// index the shipping Python reaches on a 510-token sequence and raises
    /// `IndexError` on — here it is a named failure rather than a crash.
    func testARowPastTheEndIsRefused() throws {
        let voices = try archive()
        XCTAssertThrowsError(try voices.style(for: "am_michael", tokenCount: 510)) { error in
            XCTAssertEqual(error as? KokoroVoices.Failure, .tokenCountOutOfRange(510))
        }
        XCTAssertThrowsError(try voices.style(for: "am_michael", tokenCount: -1))
        XCTAssertNoThrow(try voices.style(for: "am_michael", tokenCount: 509))
    }

    func testSomethingThatIsNotAnArchiveIsRefused() throws {
        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("not-a-zip-\(UUID().uuidString)")
        try Data("this is not a zip file".utf8).write(to: scratch)
        defer { try? FileManager.default.removeItem(at: scratch) }

        XCTAssertThrowsError(try KokoroVoices(contentsOf: scratch))
    }

    func testAMissingFileIsRefusedRatherThanCrashing() {
        let missing = URL(fileURLWithPath: "/nowhere/voices-v1.0.bin")
        XCTAssertThrowsError(try KokoroVoices(contentsOf: missing)) { error in
            XCTAssertEqual(error as? KokoroVoices.Failure, .cannotRead("voices-v1.0.bin"))
        }
    }
}
