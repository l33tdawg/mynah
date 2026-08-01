import XCTest
@testable import SageVoiceCore

/// Turning a note into a document somebody can open.
///
/// The conversion itself is Pandoc's job and is not re-tested here — what is
/// tested is everything around it, because that is where this product can get
/// it wrong: a format nobody asked for, a promise on a Mac that cannot keep it,
/// a `.pdf` that is secretly markdown, or a failure that loses the note.
final class DocumentExportTests: XCTestCase {

    // MARK: What the model asked for

    func testTheOwnersOwnWordsAreUnderstood() {
        // A 4B model writes what the owner said, not what the schema listed.
        XCTAssertEqual(DocumentFormat.named("pdf"), .pdf)
        XCTAssertEqual(DocumentFormat.named("PDF"), .pdf)
        XCTAssertEqual(DocumentFormat.named("word"), .docx)
        XCTAssertEqual(DocumentFormat.named("Word Document"), nil)
        XCTAssertEqual(DocumentFormat.named("powerpoint"), .pptx)
        XCTAssertEqual(DocumentFormat.named("slides"), .pptx)
        XCTAssertEqual(DocumentFormat.named("deck"), .pptx)
        XCTAssertEqual(DocumentFormat.named("presentation"), .pptx)
    }

    func testNoFormatMeansANote() {
        XCTAssertEqual(DocumentFormat.named(""), .markdown)
        XCTAssertEqual(DocumentFormat.named("  "), .markdown)
        XCTAssertEqual(DocumentFormat.named("markdown"), .markdown)
    }

    func testSomethingUnrecognisedIsRefusedRatherThanGuessedAt() {
        // Guessing `pdf` here would hand the owner a file they cannot open and
        // no explanation. The caller says what it did not understand instead.
        XCTAssertNil(DocumentFormat.named("epub"))
        XCTAssertNil(DocumentFormat.named("a really nice one"))
    }

    // MARK: What this Mac can actually do

    func testAMacWithNoPDFEngineDoesNotOfferPDFs() {
        let exporter = DocumentExporter(
            pandoc: URL(fileURLWithPath: "/usr/bin/true"),
            pdfEngine: nil
        )

        XCTAssertFalse(exporter.canProduce(.pdf), "pandoc alone cannot write a PDF")
        XCTAssertTrue(exporter.canProduce(.docx))
        XCTAssertTrue(exporter.canProduce(.pptx))
        XCTAssertTrue(exporter.canProduce(.markdown))
    }

    func testAskingForAPDFWithNoEngineFailsRatherThanWritingSomethingElse() async throws {
        let exporter = DocumentExporter(
            pandoc: URL(fileURLWithPath: "/usr/bin/true"),
            pdfEngine: nil
        )
        let source = try write("# Hello\n")
        defer { try? FileManager.default.removeItem(at: source) }

        do {
            try await exporter.convert(
                source: source,
                to: .pdf,
                at: source.deletingPathExtension().appendingPathExtension("pdf"),
                title: "Hello"
            )
            XCTFail("a .pdf that is secretly markdown is worse than no file")
        } catch {
            XCTAssertEqual(error as? DocumentExporter.Failure, .pdfEngineMissing)
        }
    }

    func testAConverterThatWritesNothingIsNotReportedAsSuccess() async throws {
        // `/usr/bin/true` exits 0 and produces no file, which is exactly the
        // shape of the bug this catches: a zero exit status is not evidence
        // that a document exists.
        let exporter = DocumentExporter(
            pandoc: URL(fileURLWithPath: "/usr/bin/true"),
            pdfEngine: URL(fileURLWithPath: "/usr/bin/true")
        )
        let source = try write("# Hello\n")
        defer { try? FileManager.default.removeItem(at: source) }

        do {
            try await exporter.convert(
                source: source,
                to: .docx,
                at: source.deletingPathExtension().appendingPathExtension("docx"),
                title: "Hello"
            )
            XCTFail("nothing was written and the caller was told it worked")
        } catch {
            XCTAssertEqual(error as? DocumentExporter.Failure, .producedNothing)
        }
    }

    func testAConverterThatFailsSaysWhy() async throws {
        let exporter = DocumentExporter(
            pandoc: URL(fileURLWithPath: "/usr/bin/false"),
            pdfEngine: nil
        )
        let source = try write("# Hello\n")
        defer { try? FileManager.default.removeItem(at: source) }

        do {
            try await exporter.convert(
                source: source,
                to: .docx,
                at: source.deletingPathExtension().appendingPathExtension("docx"),
                title: "Hello"
            )
            XCTFail("a non-zero exit is a failure")
        } catch let failure as DocumentExporter.Failure {
            guard case .conversionFailed = failure else {
                return XCTFail("expected a conversion failure, got \(failure)")
            }
        }
    }

    // MARK: The real thing, where it is staged

    /// Skipped rather than failed on a checkout with no `vendor/pandoc`, which
    /// is every fresh clone — `vendor/` is gitignored. Run
    /// `scripts/provision-pandoc.sh` and this starts running.
    func testPandocWritesRealFilesWhenItIsHere() async throws {
        guard let exporter = DocumentExporter.locate() else {
            throw XCTSkip("pandoc is not staged; run scripts/provision-pandoc.sh")
        }

        let source = try write("""
        # Quarterly brief

        A paragraph of prose.

        ## What we found

        - One thing
        - Another thing
        """)
        let directory = source.deletingLastPathComponent()
        defer { try? FileManager.default.removeItem(at: directory) }

        for format in [DocumentFormat.docx, .pptx, .pdf] where exporter.canProduce(format) {
            let destination = directory
                .appendingPathComponent("brief." + format.fileExtension)
            try await exporter.convert(
                source: source,
                to: format,
                at: destination,
                title: "Quarterly brief"
            )

            let size = (try FileManager.default.attributesOfItem(atPath: destination.path)[.size]
                as? NSNumber)?.intValue ?? 0
            XCTAssertGreaterThan(size, 1000, "\(format.rawValue) came out suspiciously small")

            // The first bytes, because "it exists and is big" is also true of a
            // text file with an error message in it. PDFs start `%PDF`; DOCX
            // and PPTX are zips, so they start `PK`.
            let handle = try FileHandle(forReadingFrom: destination)
            defer { try? handle.close() }
            let magic = try handle.read(upToCount: 4) ?? Data()
            switch format {
            case .pdf:
                XCTAssertEqual(String(decoding: magic, as: UTF8.self), "%PDF")
            case .docx, .pptx:
                XCTAssertEqual(Array(magic.prefix(2)), [0x50, 0x4B])
            case .markdown:
                break
            }
        }
    }

    // MARK: Finding the binaries

    func testItLooksInsideTheAppBundleAndInAcheckout() {
        let roots = DocumentExporter.searchRoots("pandoc").map(\.path)

        XCTAssertTrue(
            roots.contains { $0.hasSuffix("Resources/pandoc") },
            "package-app.sh stages it in Contents/Resources/pandoc and nothing would find it"
        )
        XCTAssertTrue(
            roots.contains { $0.hasSuffix("vendor/pandoc") },
            "a development checkout has it in vendor/"
        )
    }

    func testAnOverrideThatPointsAtNothingIsNotUsed() {
        setenv("SAGE_VOICE_PANDOC", "/nowhere/pandoc", 1)
        defer { unsetenv("SAGE_VOICE_PANDOC") }

        XCTAssertNil(
            DocumentExporter.find("pandoc", override: "SAGE_VOICE_PANDOC"),
            "an override naming a file that does not exist must not fall through to "
                + "a different pandoc — the build asked for that one"
        )
    }

    // MARK: Helpers

    private func write(_ markdown: String) throws -> URL {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("documents-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let source = directory.appendingPathComponent("brief.md")
        try Data(markdown.utf8).write(to: source)
        return source
    }
}
