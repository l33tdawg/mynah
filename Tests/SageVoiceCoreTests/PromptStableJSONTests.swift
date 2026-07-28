import XCTest
@testable import SageVoiceCore

final class PromptStableJSONTests: XCTestCase {

    /// An unencodable body must be an error, not the end of the process.
    ///
    /// JSONSerialization does not report this by throwing a Swift error — it
    /// raises an Objective-C exception, which `try` cannot catch and which
    /// aborts. Every call site is wrapped in a `do/catch` that reads as though
    /// it handles this and does not.
    ///
    /// It cost a crash: the Ollama pull request was built from JSONValue rather
    /// than Foundation values, and the app died the first time anybody chose to
    /// run the model on their own Mac. Choosing a brain should not be able to
    /// close the application.
    func testAnUnencodableBodyThrowsRatherThanAborting() {
        let body: [String: JSONValue] = ["model": .string("qwen3.5:4b"), "stream": .bool(true)]
        XCTAssertThrowsError(try PromptStableJSON.data(from: body)) { error in
            XCTAssertTrue(
                "\(error)".contains("Foundation values"),
                "the error should say what to do about it, got: \(error)"
            )
        }
    }

    /// The shape the pull request actually uses now.
    func testAFoundationBodyEncodes() throws {
        let body: [String: Any] = ["model": "qwen3.5:4b", "stream": true]
        let data = try PromptStableJSON.data(from: body)
        let text = String(decoding: data, as: UTF8.self)
        XCTAssertTrue(text.contains("\"model\":\"qwen3.5:4b\""), text)
        XCTAssertTrue(text.contains("\"stream\":true"), text)
    }

    /// Keys ascend at every depth, which is the whole reason this exists: an
    /// unsorted body changes the prompt from its first token and costs a full
    /// re-prefill on Ollama, and full price on a cached API.
    func testKeysAreSortedAtEveryDepth() throws {
        let body: [String: Any] = [
            "zebra": 1,
            "alpha": ["nested_z": 1, "nested_a": 2],
            "middle": [["b": 1, "a": 2]]
        ]
        let text = String(decoding: try PromptStableJSON.data(from: body), as: UTF8.self)
        XCTAssertLessThan(text.range(of: "alpha")!.lowerBound, text.range(of: "middle")!.lowerBound)
        XCTAssertLessThan(text.range(of: "middle")!.lowerBound, text.range(of: "zebra")!.lowerBound)
        XCTAssertLessThan(
            text.range(of: "nested_a")!.lowerBound,
            text.range(of: "nested_z")!.lowerBound
        )
    }
}

final class LocalBrainInstallerCopyTests: XCTestCase {

    /// A multi-gigabyte progress bar has to say what it is fetching.
    ///
    /// "Downloading the brain — this is the big one, a few gigabytes" was true
    /// and alarming: with no name on it, the owner's first guess is that
    /// something they already have is being downloaded again. Nothing in this
    /// installer fetches SAGE — it ships inside the app.
    func testEveryDownloadPhaseNamesWhatItIsFetching() {
        let model = LocalBrainInstaller.Phase.downloadingModel(
            status: "pulling 61aa3858e9d3", completedBytes: 1, totalBytes: 2
        )
        XCTAssertTrue(
            model.sentence.contains(LocalBrainModelCatalog.preferredModel),
            "the model download does not say what it is: \(model.sentence)"
        )

        let embedding = LocalBrainInstaller.Phase.downloadingEmbeddingModel(
            status: "", completedBytes: nil, totalBytes: nil
        )
        XCTAssertTrue(
            embedding.sentence.contains(LocalBrainModelCatalog.embeddingModel),
            "the memory model download does not say what it is: \(embedding.sentence)"
        )

        let runtime = LocalBrainInstaller.Phase.downloadingRuntime(
            completedBytes: 0, totalBytes: nil
        )
        XCTAssertTrue(
            runtime.sentence.lowercased().contains("ollama"),
            "the runtime download does not say what it is: \(runtime.sentence)"
        )
    }

    /// None of it is SAGE, and the copy must not imply otherwise.
    func testNoDownloadClaimsToBeFetchingSage() {
        let phases: [LocalBrainInstaller.Phase] = [
            .downloadingRuntime(completedBytes: 0, totalBytes: nil),
            .downloadingModel(status: "", completedBytes: nil, totalBytes: nil),
            .downloadingEmbeddingModel(status: "", completedBytes: nil, totalBytes: nil)
        ]
        for phase in phases {
            XCTAssertFalse(
                phase.sentence.lowercased().contains("sage"),
                "\(phase.sentence) implies SAGE is being downloaded; it ships in the app"
            )
        }
    }
}
