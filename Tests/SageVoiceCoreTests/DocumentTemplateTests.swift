import XCTest
import PDFKit
@testable import SageVoiceCore

/// **"i notice now asking the agent to make a pdf, just produces a .md looking
/// file in pdf format instead of one that has rich text, headings, nice
/// paragraphing, and real images / diagrams where appropriate"**
///
/// Half of this file is about what the words say and half is about what the page
/// looks like, and the second half is the one that matters — a template that
/// compiles is not a template that reads well, and the only honest check is to
/// make the PDF and look inside it.
///
/// The rendering tests skip rather than fail on a checkout with no `vendor/`,
/// which is every fresh clone. `scripts/provision-pandoc.sh`,
/// `scripts/provision-typst.sh` and `scripts/provision-typst-packages.sh` turn
/// them on.
final class DocumentTemplateTests: XCTestCase {

    // MARK: - The heading that would otherwise be a second title

    /// `write_note` puts `# <title>` at the top of every note it writes, and the
    /// converted document sets the same words as its title. Both is what a
    /// generated document looks like.
    func testTheOpeningHeadingGoesWhenItRepeatsTheTitle() {
        let prepared = DocumentTemplate.prepared(
            "# Quarterly brief\n\nA paragraph.",
            title: "Quarterly brief"
        )

        XCTAssertEqual(prepared.markdown, "A paragraph.")
        XCTAssertNil(prepared.subtitle, "nothing was said that the title did not say")
    }

    /// Matched through the slug, so the punctuation a model puts in a heading
    /// does not decide it.
    func testPunctuationAndCaseDoNotSaveTheHeading() {
        for heading in ["# quarterly brief", "# Quarterly Brief!", "#  Quarterly — brief"] {
            let prepared = DocumentTemplate.prepared(
                "\(heading)\n\nA paragraph.",
                title: "Quarterly brief"
            )
            XCTAssertEqual(prepared.markdown, "A paragraph.", heading)
            XCTAssertNil(prepared.subtitle, heading)
        }
    }

    /// **The real one, from the owner's own Mac.** The model wrote its own,
    /// longer title, so the page carried two different sentences saying the same
    /// thing — which reads worse than a duplicate, because it looks like an
    /// editing mistake. It comes off, and it becomes the subtitle.
    func testAHeadingThatSaysSomethingElseBecomesTheSubtitle() {
        let prepared = DocumentTemplate.prepared(
            "# Local Language Model on Mac vs Hosted API: A Comparative Analysis\n\nA paragraph.",
            title: "Local LLM vs Hosted API Comparison Report"
        )

        XCTAssertEqual(prepared.markdown, "A paragraph.")
        XCTAssertEqual(
            prepared.subtitle,
            "Local Language Model on Mac vs Hosted API: A Comparative Analysis"
        )
    }

    /// Level one only. A note opening with `## Something` is opening with a
    /// section, and a document that quietly loses its first section heading is a
    /// bug nobody would find by reading the code.
    func testASecondLevelHeadingIsASectionAndStays() {
        let markdown = "## Quarterly brief\n\nA paragraph."
        let prepared = DocumentTemplate.prepared(markdown, title: "Quarterly brief")

        XCTAssertEqual(prepared.markdown, markdown)
        XCTAssertNil(prepared.subtitle)
    }

    /// Only the first one. A later heading is a section the author meant.
    func testOnlyTheOpeningHeadingIsEverRemoved() {
        let markdown = "Some prose first.\n\n# Quarterly brief\n\nMore."
        let prepared = DocumentTemplate.prepared(markdown, title: "Quarterly brief")

        XCTAssertEqual(prepared.markdown, markdown)
    }

    func testANoteWithNoHeadingIsUntouched() {
        let markdown = "Just a paragraph, with no heading at all."
        let prepared = DocumentTemplate.prepared(markdown, title: "Quarterly brief")

        XCTAssertEqual(prepared.markdown, markdown)
        XCTAssertNil(prepared.subtitle)
    }

    func testAnEmptyNoteDoesNotCrash() {
        XCTAssertEqual(DocumentTemplate.prepared("", title: "Anything").markdown, "")
        XCTAssertEqual(DocumentTemplate.prepared("\n\n", title: "Anything").markdown, "\n\n")
    }

    /// A heading with nothing after the hash is not a title, and must not be
    /// promoted into an empty subtitle.
    func testAWordlessHeadingIsLeftAlone() {
        let markdown = "#\n\nA paragraph."
        let prepared = DocumentTemplate.prepared(markdown, title: "Quarterly brief")

        XCTAssertEqual(prepared.markdown, markdown)
        XCTAssertNil(prepared.subtitle)
    }

    // MARK: - The list that arrived as a paragraph

    /// **What the 4B model on this Mac actually writes.** Everything else about
    /// the typography is wasted if a list reaches the page as a paragraph full
    /// of hyphens, and this is the shape it comes in.
    func testAListStrungAlongOneLineBecomesAList() {
        let tidied = DocumentTemplate.splitRunOnBullets(
            "**Running Locally:** - One-time hardware cost - No per-token fees - Works offline"
        )

        XCTAssertEqual(tidied, """
        **Running Locally:**

        - One-time hardware cost
        - No per-token fees
        - Works offline
        """)
    }

    /// A bullet that is itself three bullets keeps being a bullet.
    func testABulletHoldingThreeBulletsBecomesThree() {
        let tidied = DocumentTemplate.splitRunOnBullets("- Alpha - Bravo - Charlie")

        XCTAssertEqual(tidied, "- Alpha\n- Bravo\n- Charlie")
    }

    /// One dash is a sentence. Two is a list. Prose keeps its dash.
    func testASentenceWithOneDashIsLeftAlone() {
        let prose = "Travel insurance - the old policy lapsed in May."

        XCTAssertEqual(DocumentTemplate.splitRunOnBullets(prose), prose)
    }

    /// Long stretches between separators are a person writing, not a flattened
    /// list, so the guard is a length as well as a count.
    func testALongProseLineWithTwoDashesIsLeftAlone() {
        let prose = "The ferry was cancelled - which nobody told us until the morning of the "
            + "crossing, by which point the hotel had already been paid for and the car was in "
            + "the wrong town - so the whole plan had to be redrawn over breakfast in a cafe "
            + "that did not take cards and had run out of the only thing on the menu."

        XCTAssertEqual(DocumentTemplate.splitRunOnBullets(prose), prose)
    }

    /// Code is code. A shell line full of ` - ` flags must survive exactly.
    func testNothingInsideAFenceIsTouched() {
        let markdown = """
        ```bash
        ffmpeg -i in.wav - out.wav - done
        ```
        """

        XCTAssertEqual(DocumentTemplate.splitRunOnBullets(markdown), markdown)
    }

    /// Table rows and headings look like run-ons and are not.
    func testTableRowsAndHeadingsAreLeftAlone() {
        for line in [
            "| Local - fast | Hosted - slow | Either - fine |",
            "## Cost - privacy - speed",
            "> Local - fast - offline"
        ] {
            XCTAssertEqual(DocumentTemplate.splitRunOnBullets(line), line, line)
        }
    }

    // MARK: - What the template says

    /// Typst has no conditional import, so the decision has to be made in Swift.
    /// A template that imports a package this Mac has not got does not degrade —
    /// it fails to compile, and every PDF fails with it, diagrams or no diagrams.
    func testTheDiagramImportIsAbsentWhenThePackageIs() {
        let without = DocumentTemplate.typst(withDiagrams: false)

        XCTAssertFalse(without.contains("@local/diagraph"), "an import of something absent")
        XCTAssertFalse(without.contains("render-graph"), "a call to something never imported")
        XCTAssertTrue(without.contains("$body$"), "still has to be a usable pandoc template")
    }

    func testTheDiagramRuleIsThereWhenThePackageIs() {
        let with = DocumentTemplate.typst(withDiagrams: true)

        XCTAssertTrue(with.contains("#import \"@local/diagraph:0.3.5\""), with.prefix(400).description)
        XCTAssertTrue(with.contains("raw.where(lang: \"dot\")"))
    }

    /// The variables pandoc fills in. A typo in one of these is silent — the
    /// template still compiles and the title simply never appears.
    func testItFillsInTheVariablesPandocActuallyPasses() {
        let template = DocumentTemplate.typst(withDiagrams: true)

        for variable in ["$if(title)$", "$title$", "$if(date)$", "$date$", "$body$"] {
            XCTAssertTrue(template.contains(variable), variable)
        }
    }

    /// **No byline, no mark, no "generated by".** These are documents the owner
    /// forwards to other people; an appliance that signs his work is one he has
    /// to edit before sending.
    func testNothingInTheTemplateSignsTheDocument() {
        let template = DocumentTemplate.typst(withDiagrams: true).lowercased()

        for branding in ["mynah", "sage", "generated by", "created with"] {
            XCTAssertFalse(template.contains(branding), "the template says “\(branding)”")
        }
    }

    /// Every family named has a fallback that Typst carries itself, so a Mac
    /// missing a font renders in a different one rather than not at all.
    func testEveryFontFallsBackToOneTypstShipsWith() {
        let template = DocumentTemplate.typst(withDiagrams: false)

        for line in template.split(separator: "\n")
        where line.hasPrefix("#let sans") || line.hasPrefix("#let serif") || line.hasPrefix("#let mono") {
            XCTAssertTrue(
                line.contains("Libertinus Serif") || line.contains("DejaVu Sans Mono"),
                String(line)
            )
        }
    }

    // MARK: - The page itself

    /// **The complaint, checked.** The title used to appear twice: once from the
    /// metadata and once from the note's own opening heading.
    func testTheTitleIsOnThePageExactlyOnce() async throws {
        let text = try await renderedText(
            markdown: "# Quarterly brief\n\nA paragraph of prose.",
            title: "Quarterly brief"
        )

        XCTAssertEqual(occurrences(of: "Quarterly brief", in: text), 1, text)
    }

    /// The date it was made is a fact this appliance knows. Upper-cased in the
    /// template, so that is how it comes back out.
    func testTheDateIsOnThePage() async throws {
        let text = try await renderedText(
            markdown: "A paragraph of prose.",
            title: "Quarterly brief",
            date: "3 August 2026"
        )

        XCTAssertTrue(text.uppercased().contains("3 AUGUST 2026"), text)
    }

    /// **The whole point of the exercise.** A `dot` fence has to come out as a
    /// drawn graph, which means the words inside it — `digraph`, the braces, the
    /// arrows — must not be on the page, and the labels must.
    func testADotFenceIsDrawnRatherThanPrinted() async throws {
        guard try exporterWithDiagrams() != nil else {
            throw XCTSkip("the Graphviz package is not staged; run scripts/provision-typst-packages.sh")
        }

        let text = try await renderedText(
            markdown: """
            How a message travels.

            ```dot
            digraph {
              rankdir=LR;
              Signal [label="Signal message"];
              Brain [label="Local brain"];
              Signal -> Brain;
            }
            ```
            """,
            title: "Where a message goes"
        )

        XCTAssertFalse(text.contains("digraph"), "the source was printed instead of drawn:\n\(text)")
        XCTAssertFalse(text.contains("rankdir"), text)
        XCTAssertTrue(text.contains("Signal message"), "the drawn labels are missing:\n\(text)")
        XCTAssertTrue(text.contains("Local brain"), text)
    }

    /// A diagram wider than the measure is scaled down to it. Without this the
    /// graph runs off the right-hand side of the page and the PDF is unusable
    /// for the one thing it was asked to show.
    func testAWideDiagramStaysInsideTheMargins() async throws {
        guard try exporterWithDiagrams() != nil else {
            throw XCTSkip("the Graphviz package is not staged; run scripts/provision-typst-packages.sh")
        }

        let nodes = (1...9).map { "N\($0) [label=\"A fairly long label \($0)\"];" }.joined(separator: "\n  ")
        let chain = (1...8).map { "N\($0) -> N\($0 + 1);" }.joined(separator: "\n  ")
        let pdf = try await renderedPDF(
            markdown: "```dot\ndigraph {\n  rankdir=LR;\n  \(nodes)\n  \(chain)\n}\n```",
            title: "A wide one"
        )
        let page = try XCTUnwrap(pdf.page(at: 0))
        let paper = page.bounds(for: .mediaBox)

        // A4 at 3.2cm side margins, in points, with a hair of tolerance for the
        // stroke width of a box that sits exactly on the measure.
        let margin = 3.2 / 2.54 * 72
        for annotationless in [page.bounds(for: .artBox), page.bounds(for: .cropBox)] {
            XCTAssertEqual(annotationless.width, paper.width, accuracy: 1)
        }
        let drawn = page.selection(for: paper).map { $0.bounds(for: page) } ?? .zero
        XCTAssertLessThanOrEqual(
            drawn.maxX, paper.width - margin + 6,
            "the diagram ran into the right margin"
        )
    }

    /// Tables come out as tables — a header row that is set apart, and cells that
    /// are not all centred, which is what Pandoc's own `align: auto` produces.
    func testATableSurvivesAsATable() async throws {
        let text = try await renderedText(
            markdown: """
            | What | When |
            | --- | --- |
            | SQ 972 to Bangkok | 12 Aug |
            """,
            title: "Bookings"
        )

        for cell in ["What", "When", "SQ 972 to Bangkok", "12 Aug"] {
            XCTAssertTrue(text.contains(cell), "\(cell) missing from:\n\(text)")
        }
    }

    // MARK: - A diagram that will not draw

    func testFindingAndRemovingADiagramFence() {
        let markdown = """
        Before.

        ```dot
        digraph { a -> b }
        ```

        After.
        """

        XCTAssertTrue(DocumentTemplate.hasDiagram(markdown))
        XCTAssertEqual(DocumentTemplate.withoutDiagrams(markdown), "Before.\n\n\nAfter.")
    }

    /// Only the diagram. A shell block in the same document is not collateral.
    func testOtherCodeBlocksSurviveTheRemoval() {
        let markdown = """
        ```bash
        echo hello
        ```

        ```dot
        digraph { a -> b }
        ```
        """

        let left = DocumentTemplate.withoutDiagrams(markdown)
        XCTAssertTrue(left.contains("echo hello"))
        XCTAssertFalse(left.contains("digraph"))
    }

    /// A fence the model never closed would otherwise swallow the rest of the
    /// note, which is far worse than an undrawn diagram.
    func testAnUnclosedFenceLeavesTheNoteAlone() {
        let markdown = "Before.\n\n```dot\ndigraph { a -> b }\n\nAfter, and no closing fence."

        XCTAssertEqual(DocumentTemplate.withoutDiagrams(markdown), markdown)
    }

    /// **The failure that cost a report on this Mac.** The 4B's first diagram
    /// used `edge` as a node name and an unquoted `#FF6347`; Graphviz refused,
    /// Typst died, and the whole PDF failed — so asking for a report with a
    /// picture in it produced no report at all.
    func testABrokenDiagramCostsTheDiagramAndNotTheDocument() async throws {
        guard try exporterWithDiagrams() != nil else {
            throw XCTSkip("the Graphviz package is not staged; run scripts/provision-typst-packages.sh")
        }

        let markdown = """
        The path a message takes is short.

        ```dot
        digraph MessageFlow {
            node [shape=cylinder];
            edge -> msg_arrival;
            reply_gen [label="Generates Reply", fillcolor=#FF6347];
        }
        ```

        Every hop of it is on this Mac.
        """

        let (conversion, pdf) = try await converted(markdown: markdown, title: "How a message travels")
        let text = pdf.string ?? ""

        XCTAssertTrue(conversion.droppedDiagram, "the fallback did not run")
        XCTAssertTrue(text.contains("The path a message takes is short"), text)
        XCTAssertTrue(text.contains("Every hop of it is on this Mac"), text)
        XCTAssertFalse(text.contains("digraph"), "the broken source ended up on the page:\n\(text)")
    }

    /// And a diagram that draws reports nothing, so the model has nothing to
    /// apologise for.
    func testAWorkingDiagramReportsNoLoss() async throws {
        guard try exporterWithDiagrams() != nil else {
            throw XCTSkip("the Graphviz package is not staged")
        }

        let (conversion, _) = try await converted(
            markdown: "```dot\ndigraph { a -> b }\n```",
            title: "Fine"
        )

        XCTAssertFalse(conversion.droppedDiagram)
    }

    // MARK: - Helpers

    private func exporterWithDiagrams() throws -> DocumentExporter? {
        guard let exporter = DocumentExporter.locate(), exporter.canProduce(.pdf) else { return nil }
        return exporter.drawsDiagrams ? exporter : nil
    }

    private func renderedText(
        markdown: String,
        title: String,
        date: String? = nil
    ) async throws -> String {
        try await renderedPDF(markdown: markdown, title: title, date: date).string ?? ""
    }

    private func renderedPDF(
        markdown: String,
        title: String,
        date: String? = nil
    ) async throws -> PDFDocument {
        try await converted(markdown: markdown, title: title, date: date).pdf
    }

    private func converted(
        markdown: String,
        title: String,
        date: String? = nil
    ) async throws -> (conversion: DocumentExporter.Conversion, pdf: PDFDocument) {
        guard let exporter = DocumentExporter.locate(), exporter.canProduce(.pdf) else {
            throw XCTSkip("pandoc and typst are not staged; run scripts/provision-typst.sh")
        }

        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("mynah-template-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let source = directory.appendingPathComponent("note.md")
        try Data(markdown.utf8).write(to: source)
        let destination = directory.appendingPathComponent("note.pdf")
        let conversion = try await exporter.convert(
            source: source, to: .pdf, at: destination, title: title, date: date
        )

        return (conversion, try XCTUnwrap(PDFDocument(url: destination), "the PDF would not open"))
    }

    private func occurrences(of needle: String, in haystack: String) -> Int {
        guard !needle.isEmpty else { return 0 }
        var count = 0
        var searched = haystack[haystack.startIndex...]
        while let found = searched.range(of: needle) {
            count += 1
            searched = searched[found.upperBound...]
        }
        return count
    }
}
