import XCTest
import PDFKit
@testable import SageVoiceCore

/// **The bar the owner set: *"only when its truly generating what we would say
/// is pretty damn good for local model pdfs do we ship 1.5.0 - basically if it
/// works for local; the cloud models should just 'make it faster'"*.**
///
/// So the floor is the 4B model on this Mac, not a hosted one. Everything else
/// in `DocumentTemplateTests` hands Pandoc markdown that a person wrote; this
/// hands the real system prompt and the real tool schema to the real local brain
/// and renders whatever comes back. It is the only test that can catch the
/// failure that matters most — a template that is beautiful with hand-written
/// input and never gets any, because nothing ever told the model it could draw.
///
/// **Off by default.** A 4B model writing a report takes a minute and does not
/// write the same one twice, and 1600 tests that finish in eight seconds are
/// worth keeping. Run it with:
///
///     MYNAH_E2E=1 arch -arm64 swift test --filter DocumentGenerationE2ETests
///
/// Nothing here touches the owner's node or his notes: the tool source is built
/// on a temporary directory and no SAGE tools are in the catalogue at all.
final class DocumentGenerationE2ETests: XCTestCase {

    /// The local default, which is the floor this has to clear.
    static let model = ProcessInfo.processInfo.environment["MYNAH_E2E_MODEL"] ?? "qwen3.5:4b"

    /// **The configuration the daemon actually runs**, mirroring
    /// `loopConfiguration(for:)` in `sage-voiced`. Using `Configuration()`'s
    /// defaults instead would test a product nobody ships: the default token
    /// ceiling is the spoken one, and a document does not fit inside it.
    static var asOnSignal: ToolLoop.Configuration {
        ToolLoop.Configuration(
            systemPrompt: BrainPrompts.voiceAgentManager(style: .written),
            maxGeneratedTokens: ReplyStyle.written.maximumGeneratedTokens
        )
    }

    func testTheLocalBrainWritesAReportWorthSending() async throws {
        let backend = try await localBrain()
        let directory = try scratchDirectory()
        defer { clearUp(directory) }

        guard let exporter = DocumentExporter.locate(), exporter.canProduce(.pdf) else {
            throw XCTSkip("pandoc and typst are not staged")
        }
        let notes = NotesToolSource(
            directory: directory,
            delivery: .attachedToReply,
            exporter: exporter,
            log: { print($0) }
        )
        let loop = ToolLoop(backend: backend, mcp: notes, configuration: Self.asOnSignal)

        let result = try await loop.run(transcript: """
        Compare running a language model locally on a Mac against calling a \
        hosted API, and make me a PDF report about it. Cover cost, privacy, \
        speed and what happens when the network is out.
        """)

        // What it actually did, printed before any assertion, because when this
        // fails the interesting part is the transcript rather than the line
        // number.
        print("\n--- reply ---\n\(result.reply)\n--- trace ---\n\(result.trace.summary)\n--- tools ---")
        for call in result.trace.toolCalls {
            print("  \(call.name)\(call.failed ? " (failed)" : "")")
        }
        for turn in result.trace.modelCalls {
            print("  turn \(turn.iteration): \(turn.evalCount ?? 0) tok"
                + "\(turn.truncated ? ", TRUNCATED" : "")"
                + ", thinking \(turn.thinking?.count ?? 0) chars"
                + ", asked for \(turn.requestedTools)")
        }

        XCTAssertTrue(
            result.trace.toolCalls.contains { $0.name == NotesToolSource.writeToolName && !$0.failed },
            "the local brain never wrote a document at all"
        )

        let documents = directory.appendingPathComponent("documents", isDirectory: true)
        let produced = ((try? FileManager.default.contentsOfDirectory(
            at: documents, includingPropertiesForKeys: nil
        )) ?? []).filter { $0.pathExtension == "pdf" }
        let pdfURL = try XCTUnwrap(produced.first, "no PDF was produced in \(documents.path)")

        let pdf = try XCTUnwrap(PDFDocument(url: pdfURL), "the PDF would not open")
        let text = pdf.string ?? ""
        print("--- \(pdfURL.lastPathComponent), \(pdf.pageCount) page(s), \(text.count) characters ---")
        print(text)

        XCTAssertGreaterThanOrEqual(pdf.pageCount, 1)
        XCTAssertGreaterThan(text.count, 400, "a report this short is not a report")

        // **Markdown that did not get converted.** Any of these on the page
        // means the words reached the PDF as source rather than as typography,
        // which is the exact complaint this release is answering.
        for leak in ["```", "##", "**", "digraph {", "rankdir"] {
            XCTAssertFalse(text.contains(leak), "“\(leak)” is on the page:\n\(text)")
        }
    }

    /// A second, narrower run: told plainly that a diagram would help, does the
    /// local model produce one, and does it come out drawn?
    ///
    /// Separate from the test above on purpose. Whether a 4B model reaches for a
    /// diagram unprompted is a question about the model; whether the machinery
    /// draws one when it does is a question about this release, and only the
    /// second is something a failure here should be blamed on.
    func testTheLocalBrainCanDrawADiagramWhenItReachesForOne() async throws {
        let backend = try await localBrain()
        let directory = try scratchDirectory()
        defer { clearUp(directory) }

        guard let exporter = DocumentExporter.locate(), exporter.drawsDiagrams else {
            throw XCTSkip("the Graphviz package is not staged")
        }
        let notes = NotesToolSource(
            directory: directory,
            delivery: .attachedToReply,
            exporter: exporter,
            log: { print($0) }
        )
        let loop = ToolLoop(backend: backend, mcp: notes, configuration: Self.asOnSignal)

        _ = try await loop.run(transcript: """
        Make me a PDF that explains how a Signal message reaches an answer: the \
        message arrives, the brain reads it, it looks something up in memory, it \
        replies. Include a diagram of that path.
        """)

        let documents = directory.appendingPathComponent("documents", isDirectory: true)
        let produced = ((try? FileManager.default.contentsOfDirectory(
            at: documents, includingPropertiesForKeys: nil
        )) ?? []).filter { $0.pathExtension == "pdf" }
        let pdfURL = try XCTUnwrap(produced.first, "no PDF was produced")

        let markdown = try XCTUnwrap(
            (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil))?
                .first { $0.pathExtension == "md" }
                .flatMap { try? String(contentsOf: $0, encoding: .utf8) },
            "no note was written"
        )
        print("--- note as the model wrote it ---\n\(markdown)")

        try XCTSkipUnless(
            markdown.contains("```dot"),
            "the local model did not reach for a diagram this run; the machinery is "
                + "covered by DocumentTemplateTests.testADotFenceIsDrawnRatherThanPrinted"
        )

        let text = PDFDocument(url: pdfURL)?.string ?? ""
        XCTAssertFalse(text.contains("digraph"), "the diagram was printed, not drawn:\n\(text)")
    }

    // MARK: - Helpers

    private func localBrain() async throws -> BrainBackend {
        guard ProcessInfo.processInfo.environment["MYNAH_E2E"] == "1" else {
            throw XCTSkip("set MYNAH_E2E=1 to run the end-to-end document tests")
        }
        let backend = OllamaBackend(model: Self.model)
        guard await backend.isAvailable() else {
            throw XCTSkip("ollama is not running, or \(Self.model) is not pulled")
        }
        return backend
    }

    /// `MYNAH_E2E_KEEP=<dir>` puts the run somewhere it survives, because the
    /// only real check on "is this pretty damn good" is opening the PDF.
    private func scratchDirectory() throws -> URL {
        let root = ProcessInfo.processInfo.environment["MYNAH_E2E_KEEP"]
            .map { URL(fileURLWithPath: $0) }
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        let directory = root.appendingPathComponent("mynah-e2e-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        keep = ProcessInfo.processInfo.environment["MYNAH_E2E_KEEP"] != nil
        if keep { print("--- keeping the run at \(directory.path) ---") }
        return directory
    }

    private var keep = false

    private func clearUp(_ directory: URL) {
        guard !keep else { return }
        try? FileManager.default.removeItem(at: directory)
    }
}
