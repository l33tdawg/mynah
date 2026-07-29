import XCTest
@testable import KokoroEngine
@testable import SageVoiceCore

/// **That the graph runs in this process and says what Python's did.**
///
/// These need the 325 MB model, so they skip where it has not been provisioned.
/// That is deliberate rather than lazy: the alternative is a fixture nobody can
/// check, and the whole point of this port is that every stage is compared
/// against captured output from the real thing.
final class KokoroSessionTests: XCTestCase {

    private func modelURL() throws -> URL {
        let candidates = [
            KokoroAssets.location(of: KokoroAssets.model),
            URL(fileURLWithPath: "/Users/l33tdawg/sage-voice-lab/kokoro/kokoro-v1.0.onnx")
        ]
        guard let found = candidates.first(where: { FileManager.default.fileExists(atPath: $0.path) }) else {
            throw XCTSkip("kokoro-v1.0.onnx is not on this machine")
        }
        return found
    }

    private func voices() throws -> KokoroVoices {
        let candidates = [
            KokoroAssets.location(of: KokoroAssets.voices),
            URL(fileURLWithPath: "/Users/l33tdawg/sage-voice-lab/kokoro/voices-v1.0.bin")
        ]
        guard let found = candidates.first(where: { FileManager.default.fileExists(atPath: $0.path) }) else {
            throw XCTSkip("voices-v1.0.bin is not on this machine")
        }
        return try KokoroVoices(contentsOf: found)
    }

    // MARK: Loading

    func testTheModelLoads() async throws {
        _ = try KokoroSession(modelPath: try modelURL())
    }

    func testAMissingModelIsNamedRatherThanCrashing() {
        XCTAssertThrowsError(
            try KokoroSession(modelPath: URL(fileURLWithPath: "/nowhere/kokoro-v1.0.onnx"))
        ) { error in
            XCTAssertEqual(error as? KokoroSession.Failure, .modelNotFound("kokoro-v1.0.onnx"))
        }
    }

    // MARK: Against the golden vectors

    /// **The whole point.** The phonemes Python produced, the style row Python
    /// selected, and the same speed — the output should be the array Python
    /// captured, sample for sample.
    ///
    /// Compared with a tolerance rather than for equality: the reference was
    /// produced by onnxruntime 1.28.0 on CPU on this machine, and while that is
    /// deterministic run to run, nothing establishes bit-exactness across
    /// builds. A tolerance this tight would still catch a wrong style row, a
    /// wrong token, or a transposed tensor — all of which move samples by far
    /// more than this.
    func testTheFoxSentenceMatchesWhatPythonSynthesized() async throws {
        let session = try KokoroSession(modelPath: try modelURL())
        let style = try voices().style(for: "am_michael", tokenCount: 53)

        let audio = try await session.audio(
            phonemes: "ðə kwˈɪk bɹˈaʊn fˈɑːks dʒˈʌmps ˌoʊvɚ ðə lˈeɪzi dˈɑːɡ.",
            style: style,
            speed: 1.0
        )

        XCTAssertEqual(audio.count, 90_600, "the model produced a different number of samples")

        guard let reference = try golden("samples") else {
            throw XCTSkip("the captured samples are not on this machine")
        }
        var worst: Float = 0
        for index in 0..<min(audio.count, reference.count) {
            worst = max(worst, abs(audio[index] - reference[index]))
        }
        XCTAssertLessThan(worst, 1e-4, "the native output diverged from Python's")
    }

    func testTheShortSentenceMatchesWhatPythonSynthesized() async throws {
        let session = try KokoroSession(modelPath: try modelURL())
        let style = try voices().style(for: "am_michael", tokenCount: 7)

        let audio = try await session.audio(phonemes: "həlˈoʊ.", style: style, speed: 1.0)

        XCTAssertEqual(audio.count, 34_200)
    }

    // MARK: Refusing

    func testEmptyPhonemesAreRefusedRatherThanRun() async throws {
        let session = try KokoroSession(modelPath: try modelURL())
        let style = try voices().style(for: "am_michael", tokenCount: 7)

        do {
            _ = try await session.audio(phonemes: "", style: style)
            XCTFail("an empty sequence reached the graph")
        } catch {
            XCTAssertEqual(error as? KokoroSession.Failure, .emptyText)
        }
    }

    /// A style vector of the wrong width would be read past its end by the
    /// runtime — a crash rather than an error, and only on some inputs.
    func testAStyleVectorOfTheWrongWidthIsRefused() async throws {
        let session = try KokoroSession(modelPath: try modelURL())

        do {
            _ = try await session.audio(phonemes: "həlˈoʊ.", style: [0, 1, 2])
            XCTFail("a short style vector was accepted")
        } catch {
            guard case .cannotBuildInput = (error as? KokoroSession.Failure) else {
                return XCTFail("expected cannotBuildInput, got \(error)")
            }
        }
    }

    // MARK: Helpers

    private func golden(_ name: String) throws -> [Float]? {
        let path = "/private/tmp/claude-501/-Users-l33tdawg-nodejs-projects-sage"
            + "/caf51fc9-1b10-4011-b26e-a33a6bb8ec9a/scratchpad/kokoro-golden/\(name).f32"
        guard FileManager.default.fileExists(atPath: path) else { return nil }
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        return data.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
    }
}
