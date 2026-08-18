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

    /// **Instrument (b): the real number, from the real model.**
    ///
    /// `BrainCapabilities.hosted.minimumOutputTokens` answered the token
    /// question for hosted brains and only for hosted brains — `.onDevice` is 0
    /// by design, so `ReplyStyle.written.maximumGeneratedTokens` still decides
    /// here, and that is 4,096 against the 32,000 characters `write_note`
    /// accepts. The owner's shipping bar is the local 4B, so a chart-heavy
    /// document bites on device first or nowhere.
    ///
    /// The arithmetic says a chart fence is a compression of the table it
    /// replaces (`DocumentTemplateTests.testAChartHeavyDocumentFitsTheToken\
    /// CeilingsItIsSentUnder`), so the pressure should go *down*. The thing
    /// arithmetic cannot answer is whether the model swaps or merely adds — if
    /// it writes the table **and** the chart the cost roughly doubles, and that
    /// is what this run is for.
    ///
    /// What it asserts is only ever about the machinery: no model call came back
    /// truncated, `write_note` was not handed a cut-off argument, and whatever
    /// chart did arrive is drawn rather than printed. Whether a 4B reaches for a
    /// chart at all on a given run is a question about the model, so that half
    /// skips rather than fails — the deterministic assertion lives in
    /// `DocumentTemplateTests.testAChartFenceIsDrawnRatherThanPrinted`.
    ///
    /// The number worth reading is printed, not asserted: `evalCount` for the
    /// writing turn, against 4,096.
    func testTheLocalBrainWritesAChartHeavyReportWithoutBeingCutOff() async throws {
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
        Make me a PDF comparing six ways of running a language model: a Mac \
        mini, a Mac Studio, a DGX Spark, an OpenAI subscription, an Anthropic \
        subscription and a rented GPU. For each one give a monthly cost in \
        dollars and a tokens-per-second figure, and chart both.
        """)

        print("\n--- reply ---\n\(result.reply)\n--- trace ---\n\(result.trace.summary)")
        var peak = 0
        for turn in result.trace.modelCalls {
            print("  turn \(turn.iteration): \(turn.evalCount ?? 0) tok"
                + "\(turn.truncated ? ", TRUNCATED" : "")"
                + ", thinking \(turn.thinking?.count ?? 0) chars"
                + ", asked for \(turn.requestedTools)")
            peak = max(peak, turn.evalCount ?? 0)
            XCTAssertFalse(
                turn.truncated,
                "turn \(turn.iteration) was cut off at "
                    + "\(ReplyStyle.written.maximumGeneratedTokens) tokens; a truncated tool "
                    + "call is not a short answer, it is no answer at all"
            )
        }
        print("--- the measured number: \(peak) tokens against a ceiling of "
            + "\(ReplyStyle.written.maximumGeneratedTokens) ---")

        // What a cut-off tool call looks like from inside: the JSON parses far
        // enough to route, and `content` is empty or gone.
        let written = result.trace.toolCalls.filter { $0.name == NotesToolSource.writeToolName }
        for call in written {
            XCTAssertFalse(
                call.result.contains("No content was given"),
                "the write_note argument arrived truncated: \(call.result)"
            )
        }

        let markdown = try XCTUnwrap(
            (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil))?
                .first { $0.pathExtension == "md" }
                .flatMap { try? String(contentsOf: $0, encoding: .utf8) },
            "no note was written"
        )
        print("--- note as the model wrote it ---\n\(markdown)")

        try XCTSkipUnless(
            markdown.contains("```chart"),
            "the local model did not reach for a chart this run; the machinery is covered by "
                + "DocumentTemplateTests.testAChartFenceIsDrawnRatherThanPrinted"
        )

        let documents = directory.appendingPathComponent("documents", isDirectory: true)
        let produced = ((try? FileManager.default.contentsOfDirectory(
            at: documents, includingPropertiesForKeys: nil
        )) ?? []).filter { $0.pathExtension == "pdf" }
        let pdfURL = try XCTUnwrap(produced.first, "no PDF was produced")
        let text = PDFDocument(url: pdfURL)?.string ?? ""

        // True either way: the notation is never on the page.
        XCTAssertFalse(text.contains("```"), "the fence is on the page:\n\(text)")

        // **Both branches are asserted, because both are real.** On the run this
        // test was written from, the 4B wrote a chart of ranges rather than
        // numbers — so the honest outcome was the table, and the thing that
        // mattered was that the model was *told*. Its reply then said the
        // figures were "presented as a table instead of a visual chart", which
        // is the whole point of `droppedChart` existing.
        let becameATable = written.contains { $0.result.contains("could not be drawn") }
        if becameATable {
            XCTAssertTrue(
                written.contains { $0.result.contains("as a table instead") },
                "the chart fell back and nothing told the model, so it is free to describe "
                    + "bars that are not on the page: \(written.map(\.result))"
            )
        } else {
            // The rows themselves, not the pipe character. On a real run the
            // model wrote `- Mac mini | $8/month, ~10 tokens/sec` as an ordinary
            // bullet in its prose, so a blanket search for `|` accuses the
            // template of something the model did. A drawn chart puts the label
            // and the number in separate cells; a printed one puts the row on
            // the page exactly as it was written.
            for row in chartRows(of: markdown) {
                XCTAssertFalse(
                    text.contains(row), "the row \"\(row)\" was printed, not drawn:\n\(text)"
                )
            }
        }
    }

    /// The lines inside every ```` ```chart ```` fence of a note.
    private func chartRows(of markdown: String) -> [String] {
        var rows: [String] = []
        var inside = false
        for line in markdown.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") {
                inside = trimmed.lowercased() == "```chart"
                continue
            }
            if inside, !trimmed.isEmpty { rows.append(trimmed) }
        }
        return rows
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
