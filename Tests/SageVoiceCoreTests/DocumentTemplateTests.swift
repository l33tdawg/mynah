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

    // MARK: - Charts

    /// **The whole point of the chart half.** A ```` ```chart ```` fence has to
    /// come out as bars, which means the labels are on the page, the numbers are
    /// on the page, and the notation they were written in — the fence, the pipes
    /// — is not.
    func testAChartFenceIsDrawnRatherThanPrinted() async throws {
        let (conversion, pdf) = try await converted(
            markdown: """
            Where the money went.

            ```chart
            Local Mac | 1200
            Hosted API | 3400
            Break even | 800
            ```
            """,
            title: "Costs"
        )
        let text = pdf.string ?? ""

        XCTAssertFalse(conversion.droppedChart, "the chart fell back to a table:\n\(text)")
        for label in ["Local Mac", "Hosted API", "Break even"] {
            XCTAssertTrue(text.contains(label), "\(label) is not on the page:\n\(text)")
        }
        for number in ["1200", "3400", "800"] {
            XCTAssertTrue(text.contains(number), "\(number) is not on the page:\n\(text)")
        }
        // The notation itself, in any of the shapes it could leak in.
        XCTAssertFalse(text.contains("```"), "the fence is on the page:\n\(text)")
        XCTAssertFalse(text.contains("chart"), "the fence language is on the page:\n\(text)")
        XCTAssertFalse(text.contains("|"), "the rows were printed, not drawn:\n\(text)")
    }

    /// **A 4B writes all three, so all three have to be read.** The guidance
    /// asks for `Label | 42`; asked for "a chart" the model reaches for whatever
    /// a table of numbers looks like to it, and refusing the other two would
    /// mean a document that quietly has no picture in it.
    func testAChartTheModelWroteAsCSVIsUnderstood() {
        for source in [
            "Local Mac | 1200\nHosted API | 3400",
            "Local Mac, 1200\nHosted API, 3400",
            "Local Mac: 1200\nHosted API: 3400",
            "Local Mac; 1200\nHosted API; 3400",
            "- Local Mac: 1200\n- Hosted API: 3400",
            "Local Mac: $1,200\nHosted API: $3,400"
        ] {
            guard case .success(let chart) = DocumentTemplate.Chart.parse(source) else {
                return XCTFail("not understood:\n\(source)")
            }
            XCTAssertEqual(
                chart.canonicalSource, "Local Mac|1200\nHosted API|3400",
                "read wrongly from:\n\(source)"
            )
        }
    }

    /// The separator is chosen by what follows it, not by where it is. Neither
    /// end of the line answers both of these on its own.
    func testTheSeparatorIsTheOneThatLeavesANumberBehind() {
        XCTAssertEqual(
            DocumentTemplate.Chart.parseRow("Q1, 2026 revenue, 1200"),
            DocumentTemplate.Chart.Row(label: "Q1, 2026 revenue", shown: "1200", value: 1200)
        )
        XCTAssertEqual(
            DocumentTemplate.Chart.parseRow("Cost, 1,234"),
            DocumentTemplate.Chart.Row(label: "Cost", shown: "1234", value: 1234)
        )
    }

    /// Whole numbers keep their shape. A document that prints `1200.0` where the
    /// owner wrote `1200` is inventing precision.
    func testAWholeNumberDoesNotGrowADecimalPoint() {
        guard case .success(let chart) = DocumentTemplate.Chart.parse("A|1200\nB|0.5\nC|0") else {
            return XCTFail("not understood")
        }
        XCTAssertEqual(chart.canonicalSource, "A|1200\nB|0.5\nC|0")
    }

    /// **The one the real model actually failed on.** Asked for a six-way
    /// comparison, qwen3.5:4b wrote `DGX Spark | 300+` and `Rented GPU | 400+`,
    /// and refusing those two characters cost the whole chart — the owner got a
    /// table where a picture was promised, for a reason no reader would guess.
    ///
    /// So the qualifier is kept rather than either refused or silently dropped:
    /// the bar is drawn at 300, which is the shortest bar `300+` allows and
    /// therefore never overstates, and the text beside it still says `300+`.
    func testAnApproximateNumberDrawsAndKeepsItsQualifier() async throws {
        guard case .success(let chart) = DocumentTemplate.Chart.parse("""
        DGX Spark | 300+
        Mac mini | ~10
        Mac Studio | ≈25
        Rented GPU | $2,500+
        """) else { return XCTFail("the shape the local model writes is refused") }

        XCTAssertEqual(chart.rows.map(\.shown), ["300+", "~10", "~25", "2500+"])
        XCTAssertEqual(chart.rows.map(\.value), [300, 10, 25, 2500])

        let (conversion, pdf) = try await converted(
            markdown: "```chart\nDGX Spark | 300+\nMac mini | ~10\n```",
            title: "Throughput"
        )
        let text = pdf.string ?? ""
        XCTAssertFalse(conversion.droppedChart, "it fell back rather than drawing:\n\(text)")
        XCTAssertTrue(text.contains("300+"), "the floor was silently dropped:\n\(text)")
        XCTAssertTrue(text.contains("~10"), "the approximation was silently dropped:\n\(text)")
        // And the template read the qualifier rather than giving up on the row:
        // its own fallback is a code box, which puts the pipes on the page.
        XCTAssertFalse(text.contains("|"), "the template could not read it:\n\(text)")
    }

    /// A range is still refused, because there is no single number a bar from
    /// zero would be showing.
    func testARangeIsStillNotANumber() {
        XCTAssertEqual(
            DocumentTemplate.Chart.parse("Mac mini | 8-16\nStudio | 30"),
            .failure(.rowWithoutANumber("Mac mini | 8-16"))
        )
    }

    /// **What `Double` alone would let through.** `Double("1e9")` is nine
    /// hundred million, `Double("inf")` and `Double("nan")` both parse, and so
    /// do hexadecimal floats — none of which the template can read, and a bar
    /// of `inf` is not a bar. Refused in Swift so the fence never carries one.
    func testAnExponentOrAnInfinityIsNotANumberAChartCanDraw() {
        for written in ["1e9", "inf", "-inf", "nan", "0x1p3"] {
            XCTAssertNil(
                DocumentTemplate.Chart.chartValue(written)?.value,
                "\"\(written)\" was read as a number a bar could be drawn from"
            )
        }
    }

    /// **A malformed row must cost the chart and not the document.** Handed one
    /// uncanonicalised, Typst exits 1 with `invalid float: not-a-number` and
    /// writes no PDF at all — the identical failure that cost the owner a report
    /// when the 4B wrote invalid Graphviz. The numbers survive as a table, which
    /// is the thing a chart can do that a broken graph cannot.
    func testAChartRowWithNoNumberCostsTheChartAndNotTheDocument() async throws {
        let (conversion, pdf) = try await converted(
            markdown: """
            The comparison is short.

            ```chart
            Local Mac | 1200
            Hosted API | not-a-number
            Break even | 800
            ```

            Every number in it is a monthly one.
            """,
            title: "Costs"
        )
        let text = pdf.string ?? ""

        XCTAssertTrue(conversion.droppedChart, "the model was not told:\n\(text)")
        XCTAssertTrue(text.contains("The comparison is short"), text)
        XCTAssertTrue(text.contains("Every number in it is a monthly one"), text)
        // The facts are kept, every one of them, including the row that failed.
        for kept in ["Local Mac", "1200", "Hosted API", "not-a-number", "Break even", "800"] {
            XCTAssertTrue(text.contains(kept), "\(kept) was lost:\n\(text)")
        }
        XCTAssertFalse(text.contains("```"), "the fence is on the page:\n\(text)")
    }

    /// A label carrying the separator must not split its own row, and must not
    /// walk off the end of the array inside Typst. The value is the last field
    /// of a canonical row precisely so that it cannot.
    func testAPipeInALabelCannotSplitARow() async throws {
        guard case .success(let chart) =
            DocumentTemplate.Chart.parse("Signal | Brain | 1200\nDisk | 800") else {
            return XCTFail("not understood")
        }
        XCTAssertEqual(chart.rows.map(\.label), ["Signal | Brain", "Disk"])
        XCTAssertEqual(chart.canonicalSource, "Signal | Brain|1200\nDisk|800")

        let (conversion, pdf) = try await converted(
            markdown: "```chart\nSignal | Brain | 1200\nDisk | 800\n```",
            title: "Hops"
        )
        let text = pdf.string ?? ""
        XCTAssertFalse(conversion.droppedChart, text)
        XCTAssertTrue(text.contains("Signal"), text)
        XCTAssertTrue(text.contains("Brain"), text)
        XCTAssertTrue(text.contains("1200"), text)
        XCTAssertFalse(text.contains("800|"), text)
    }

    /// **The injection guard.** Note content reaches here from `web_search`
    /// results, which are written by strangers, and from speech recognition,
    /// which mishears. A label is data and has to stay data: `#read` and `#v`
    /// are Typst, and one of them reads files off the owner's disk.
    ///
    /// Three separate proofs in one document, because each covers a different
    /// way this could go wrong:
    ///
    /// - `#v(9cm)` three times over is 27cm of vertical space on a 29.7cm page.
    ///   If it ran, there would be a second page.
    /// - `#read("/etc/passwd")` outside the compile root makes Typst *fail*, so
    ///   a document that converted at all is a document that did not evaluate it.
    /// - `droppedChart` false proves it drew as a chart rather than falling back
    ///   to a table, which is the way this could pass while doing nothing.
    func testALabelCannotBecomeTypstCode() async throws {
        let (conversion, pdf) = try await converted(
            markdown: """
            ```chart
            #read("/etc/passwd") and #v(9cm) | 40
            #v(9cm) again | 30
            #v(9cm) once more | 20
            ```
            """,
            title: "Not code"
        )
        let text = pdf.string ?? ""

        XCTAssertFalse(conversion.droppedChart, "it fell back rather than drawing:\n\(text)")
        XCTAssertEqual(pdf.pageCount, 1, "27cm of #v() was executed:\n\(text)")
        XCTAssertTrue(
            text.contains("#read(") && text.contains("#v(9cm)"),
            "the label is not on the page as characters:\n\(text)"
        )
    }

    /// **A bar chart is drawn from a zero baseline, so it cannot show a number
    /// below one.** Drawing a short bar where a loss belongs is not a plain
    /// picture, it is a false one — so it refuses by name and the numbers stay,
    /// with their signs, as a table.
    func testNegativeValuesAreRefusedAsAChartAndKeptAsATable() async throws {
        XCTAssertEqual(
            DocumentTemplate.Chart.parse("Profit | 1200\nLoss | -250"),
            .failure(.negativeValue("Loss | -250"))
        )

        let (conversion, pdf) = try await converted(
            markdown: """
            The quarter, in full.

            ```chart
            Profit | 1200
            Loss | -250
            ```
            """,
            title: "The quarter"
        )
        let text = pdf.string ?? ""

        XCTAssertTrue(conversion.droppedChart, "a false picture was drawn:\n\(text)")
        XCTAssertTrue(text.contains("The quarter, in full"), text)
        XCTAssertTrue(text.contains("1200"), text)
        // Either dash: Typst typesets a hyphen-minus in front of a number as a
        // real U+2212 minus sign, which is the right thing to do to it and not
        // the same character it went in as.
        XCTAssertTrue(
            text.contains("-250") || text.contains("\u{2212}250"),
            "the sign was lost:\n\(text)"
        )
    }

    /// An empty fence has nothing to keep, and must not become an empty table.
    func testAnEmptyChartFenceIsNotADocumentFullOfNothing() {
        XCTAssertEqual(DocumentTemplate.Chart.parse("\n  \n"), .failure(.nothingToDraw))
        XCTAssertEqual(DocumentTemplate.chartsAsTables("Before.\n\n```chart\n```\n\nAfter."),
                       "Before.\n\n\nAfter.")
    }

    /// A fence the model never closed would otherwise swallow the rest of the
    /// note, which is far worse than an undrawn chart.
    func testAnUnclosedChartFenceLeavesTheNoteAlone() {
        let markdown = "Before.\n\n```chart\nA | 1\n\nAfter, and no closing fence."

        XCTAssertEqual(DocumentTemplate.chartsAsTables(markdown), markdown)
        XCTAssertEqual(DocumentTemplate.prepared(markdown, title: "x").markdown, markdown)
    }

    /// Both halves of "real images / diagrams where appropriate" in one
    /// document. The chart rule sits beside the diagram rule and after the
    /// generic `raw` rule, and either one shadowing the others would show up
    /// here as source on the page.
    func testAChartAndADiagramSurviveEachOther() async throws {
        guard try exporterWithDiagrams() != nil else {
            throw XCTSkip("the Graphviz package is not staged; run scripts/provision-typst-packages.sh")
        }

        let (conversion, pdf) = try await converted(
            markdown: """
            How a message travels, and what each hop costs.

            ```dot
            digraph {
              rankdir=LR;
              Signal [label="Signal message"];
              Brain [label="Local brain"];
              Signal -> Brain;
            }
            ```

            ```chart
            Signal | 40
            Brain | 900
            ```

            ```bash
            echo hello
            ```
            """,
            title: "Where a message goes"
        )
        let text = pdf.string ?? ""

        XCTAssertFalse(conversion.droppedDiagram, text)
        XCTAssertFalse(conversion.droppedChart, text)
        XCTAssertFalse(text.contains("digraph"), "the diagram was printed:\n\(text)")
        XCTAssertTrue(text.contains("Signal message"), "the diagram is missing:\n\(text)")
        XCTAssertTrue(text.contains("900"), "the chart is missing:\n\(text)")
        // And the ordinary code block is untouched by either rule.
        XCTAssertTrue(text.contains("echo hello"), "a shell block was collateral:\n\(text)")
    }

    /// **DOCX and PPTX never see the Typst template**, so a chart fence in one
    /// arrives in `word/document.xml` as its own source — the fence body,
    /// verbatim, where a picture was promised. Those formats get the numbers as
    /// a table, and the model is told so.
    func testAChartInAWordDocumentBecomesATableNotSource() async throws {
        let (conversion, xml) = try await convertedToWord(
            markdown: """
            The comparison.

            ```chart
            Local Mac | 1200
            Hosted API | 3400
            ```
            """,
            title: "Costs"
        )

        XCTAssertTrue(conversion.droppedChart, "the model was not told")
        XCTAssertTrue(xml.contains("Local Mac"), "the facts were lost:\n\(xml.prefix(2000))")
        XCTAssertTrue(xml.contains("1200"), "the facts were lost")
        XCTAssertTrue(xml.contains("<w:tbl>"), "the numbers are not in a table")
        XCTAssertFalse(xml.contains("Local Mac | 1200"), "the fence body leaked as source")
        XCTAssertFalse(xml.contains("Local Mac|1200"), "the canonical row leaked as source")
    }

    // MARK: - What a chart costs to write

    /// **Instrument (a): the encoding arithmetic, with no model in it.**
    ///
    /// The document rides *inside* the `write_note` tool call, so the generation
    /// ceiling is not bounding a reply here — it is bounding the report. The
    /// hosted floor was raised to 16,384 for exactly this reason and the
    /// arithmetic is written out on `BrainCapabilities.hosted`;
    /// `.onDevice.minimumOutputTokens` is 0 by design, so
    /// `ReplyStyle.written.maximumGeneratedTokens` still decides on the Mac the
    /// owner ships against, and that is 4,096 — half of what `write_note` will
    /// accept.
    ///
    /// So the question a chart has to answer is not "does it fit" but "is it
    /// cheaper than what the model was writing instead". Six data points cost
    /// fewer JSON-encoded characters as a chart fence than as the markdown table
    /// carrying the same numbers, which makes a chart-heavy document *less*
    /// expensive than the table-heavy one it replaces.
    ///
    /// This reddens if anyone lowers a ceiling or makes the row encoding fatter.
    func testAChartHeavyDocumentFitsTheTokenCeilingsItIsSentUnder() throws {
        // The codebase's own arithmetic, from the comment on
        // `BrainCapabilities.hosted.minimumOutputTokens`: 32,000 characters is
        // roughly 8,000 tokens.
        let charactersPerToken = 4

        let labels = ["Local Mac", "Hosted API", "Break even", "Year two", "Year three", "Idle"]
        let values = [1200, 3400, 800, 2400, 3600, 40]
        let written = zip(labels, values).map { "\($0) | \($1)" }.joined(separator: "\n")
        // Both sides read off the code rather than typed out here, so the
        // comparison follows the encoding if the encoding ever changes.
        guard case .success(let parsed) = DocumentTemplate.Chart.parse(written) else {
            return XCTFail("the fixture no longer parses")
        }
        let chart = "```\(DocumentTemplate.chartLanguage)\n\(parsed.canonicalSource)\n```"
        let table = DocumentTemplate.chartAsTable(written)

        // The claim, pinned: the fence is a compression of the table, not an
        // addition to it.
        let asChart = jsonCost(chart)
        let asTable = jsonCost(table)
        XCTAssertLessThan(
            asChart, asTable,
            "a chart of \(labels.count) points costs \(asChart) JSON characters where the "
                + "table of the same numbers costs \(asTable); it is no longer a saving"
        )

        // BrainCapabilities.hosted: the floor raised so the whole document fits.
        let full = String(repeating: "x", count: NotesToolSource.maximumContentCharacters)
        XCTAssertLessThanOrEqual(
            jsonCost(full),
            BrainCapabilities.hosted.minimumOutputTokens * charactersPerToken,
            "the largest note write_note accepts no longer fits the hosted floor of "
                + "\(BrainCapabilities.hosted.minimumOutputTokens) tokens"
        )

        // ReplyStyle.written, which is what BrainCapabilities.onDevice leaves in
        // charge, against **the worst case the guidance exists to prevent**: a
        // model that does not swap the table for the chart but writes both, so
        // every figure in the document is paid for twice. That is the one thing
        // the arithmetic above cannot rule out, and it is the shape that puts
        // the local ceiling under real pressure.
        let prose = "Two or three sentences of the prose a report of this kind carries "
            + "around a figure, saying what was measured, over what period, and what the "
            + "number does and does not account for — which is roughly the length the "
            + "local model writes when it is asked for a section rather than a summary.\n"
        let report = (["# The six-way comparison\n", prose] + (1...6).map { section in
            "## Section \(section)\n\n\(prose)\n\(chart)\n\n\(table)\n"
        }).joined(separator: "\n")
        let onDeviceCeiling = ReplyStyle.written.maximumGeneratedTokens * charactersPerToken

        // **And the gap that is still open, named so it cannot drift quietly.**
        // `write_note` accepts 32,000 characters; the on-device tier can emit
        // about half that, because `.onDevice.minimumOutputTokens` is 0 by
        // design and `ReplyStyle` decides instead. So on the Mac the owner
        // ships against, the tool's own limit is not the binding one —
        // which is *why* a cheaper notation for a table of numbers is worth
        // having. Raising the local ceiling is not the fix: the comment on
        // `BrainCapabilities.hosted` records qwen3.5:4b generating 4,069 tokens
        // over 190 seconds and returning empty content. Anyone changing either
        // number has to come and look at this.
        XCTAssertGreaterThan(
            jsonCost(full), onDeviceCeiling,
            "the on-device ceiling now covers the whole document write_note accepts, which "
                + "would be new — check it was not bought by raising "
                + "ReplyStyle.written.maximumGeneratedTokens, which was measured returning "
                + "empty content on the local 4B"
        )

        XCTAssertLessThanOrEqual(
            jsonCost(report), onDeviceCeiling,
            "a six-section report carrying every figure twice is \(jsonCost(report)) JSON "
                + "characters against the \(ReplyStyle.written.maximumGeneratedTokens)-token "
                + "on-device ceiling (~\(onDeviceCeiling) characters); the local model would "
                + "be cut off mid-call, and a truncated tool call is no answer at all"
        )
    }

    /// What the document actually costs to emit: the characters the model has to
    /// generate once the text is a JSON string inside a tool call.
    private func jsonCost(_ content: String) -> Int {
        let encoded = try? JSONEncoder().encode(content)
        return encoded.map { $0.count } ?? content.count
    }

    // MARK: - Helpers

    /// A DOCX, as the XML somebody would see if they unzipped it.
    ///
    /// Read out of the file rather than trusted, because the failure being
    /// checked for is invisible from the outside: a fence body reaches
    /// `word/document.xml` as ordinary paragraphs and the file opens perfectly.
    private func convertedToWord(
        markdown: String,
        title: String
    ) async throws -> (conversion: DocumentExporter.Conversion, xml: String) {
        guard let exporter = DocumentExporter.locate() else {
            throw XCTSkip("pandoc is not staged; run scripts/provision-pandoc.sh")
        }

        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("mynah-docx-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let source = directory.appendingPathComponent("note.md")
        try Data(markdown.utf8).write(to: source)
        let destination = directory.appendingPathComponent("note.docx")
        let conversion = try await exporter.convert(
            source: source, to: .docx, at: destination, title: title
        )

        let unzip = Process()
        unzip.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        unzip.arguments = ["-p", destination.path, "word/document.xml"]
        let pipe = Pipe()
        unzip.standardOutput = pipe
        try unzip.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        unzip.waitUntilExit()

        return (conversion, String(data: data, encoding: .utf8) ?? "")
    }

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

    // MARK: - Links somebody can actually press

    /// Every URL the rendered PDF carries as a real link annotation.
    ///
    /// Annotations rather than text, because the two come apart in exactly the
    /// way that matters here: a URL can be on the page, in the right colour, and
    /// still be nothing but characters. Only the annotation is clickable.
    private func linkedURLs(in pdf: PDFDocument) -> [String] {
        var found: [String] = []
        for index in 0..<pdf.pageCount {
            guard let page = pdf.page(at: index) else { continue }
            for annotation in page.annotations {
                if let url = annotation.url ?? (annotation.action as? PDFActionURL)?.url {
                    found.append(url.absoluteString)
                }
            }
        }
        return found
    }

    /// **A references section is written as bare addresses, and they were dead.**
    ///
    /// Pandoc links `[name](url)` on its own and the template has styled links
    /// blue from the start — but a model writing sources puts the address on its
    /// own line, which the plain `markdown` reader leaves as characters. The
    /// owner got a page of URLs he had to retype.
    func testABareURLBecomesSomethingYouCanPress() async throws {
        let pdf = try await renderedPDF(
            markdown: """
            ## Sources

            - https://www.nvidia.com/en-us/products/workstations/dgx-spark/
            - https://developer.nvidia.com/blog/dgx-spark-benchmarks/
            """,
            title: "Sources"
        )
        let links = linkedURLs(in: pdf)
        XCTAssertTrue(
            links.contains { $0.contains("nvidia.com") },
            "a bare URL is still just text: \(links)"
        )
        XCTAssertEqual(links.count, 2, "both sources should be pressable: \(links)")
    }

    /// The form that already worked must keep working — this changed the reader,
    /// and a reader extension can alter how ordinary markdown parses.
    func testAWrittenLinkIsStillALink() async throws {
        let pdf = try await renderedPDF(
            markdown: "See [the benchmarks](https://developer.nvidia.com/blog/dgx-spark-benchmarks/).",
            title: "Links"
        )
        XCTAssertTrue(
            linkedURLs(in: pdf).contains { $0.contains("developer.nvidia.com") },
            "a written link stopped being a link"
        )
    }

    /// And an address inside a sentence is linked without swallowing the words
    /// after it — the reason this is a reader extension rather than a regular
    /// expression written by us.
    func testAURLInsideASentenceDoesNotEatTheSentence() async throws {
        let pdf = try await renderedPDF(
            markdown: "Read https://developer.nvidia.com/blog/ and then decide what to buy.",
            title: "Inline"
        )
        XCTAssertEqual(linkedURLs(in: pdf), ["https://developer.nvidia.com/blog/"])
        let text = try await renderedText(
            markdown: "Read https://developer.nvidia.com/blog/ and then decide what to buy.",
            title: "Inline"
        )
        XCTAssertTrue(
            text.contains("and then decide what to buy"),
            "the words after the address were absorbed into it"
        )
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
