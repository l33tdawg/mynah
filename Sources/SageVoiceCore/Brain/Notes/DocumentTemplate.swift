import Foundation

/// What a generated PDF looks like.
///
/// **The owner's complaint, in his words:** *"i notice now asking the agent to
/// make a pdf, just produces a .md looking file in pdf format instead of one
/// that has rich text, headings, nice paragraphing, and real images / diagrams
/// where appropriate"*. He was right, and the cause was not the model — Pandoc's
/// stock Typst template is a centred bold line and then the same undifferentiated
/// prose the markdown had, at default leading, on US Letter.
///
/// **Deliberately not a prompt fix.** Asking a model to "write nicer markdown"
/// produces markdown with more asterisks in it. Typography is a template's job,
/// and a template is a thing that can be looked at, so this one can be checked
/// by eye and by test rather than hoped for on each turn.
///
/// ## What the design commits to
///
/// - **Serif body, sans headings.** Charter for prose because it was drawn to
///   stay readable at small sizes on bad printers, Avenir Next for headings
///   because the structure should be visible from across a desk. Every family
///   here ships with macOS and each falls back to one Typst carries itself, so a
///   missing font degrades rather than fails.
/// - **No branding.** No "made by Mynah" line, no mark, no colour scheme of its
///   own. These are documents the owner forwards to other people, and an
///   appliance that signs his work is one he has to edit before sending.
/// - **The title comes from metadata, not from the note.** Which is why
///   `withoutRepeatedTitle` exists: `write_note` puts a `# Heading` at the top of
///   every note it writes, and rendering both is the single most generated-
///   looking thing a document can do.
enum DocumentTemplate {

    // MARK: - Diagrams

    /// The Typst package that draws `dot` fences, and where it is imported from.
    ///
    /// `@local` rather than `@preview` on purpose: the preview namespace is
    /// fetched from packages.typst.org on first use, which would put a network
    /// round trip inside "make me a PDF" and make the output depend on a server
    /// being up. See `scripts/provision-typst-packages.sh`.
    static let packageNamespace = "local"
    static let packageName = "diagraph"
    static let packageVersion = "0.3.5"

    /// The fence a diagram is written in. Graphviz, because it is the diagram
    /// language a model already knows — asking for anything more bespoke means
    /// teaching a syntax in prompt space that is already full.
    static let diagramLanguage = "dot"

    static var packageImport: String {
        "@\(packageNamespace)/\(packageName):\(packageVersion)"
    }

    // MARK: - Charts

    /// The fence a chart is written in.
    ///
    /// **Data, not code — which is the whole reason this works.** A plotting
    /// package (lilaq, cetz-plot) would mean the model emitting Typst plotting
    /// syntax, and teaching a syntax in prompt space is exactly what `dot` won
    /// on: Graphviz is drawn here because a 4B already knows it. Nothing knows
    /// a Typst plotting API. So the notation the model writes is the numbers
    /// themselves, one per line, and the drawing is the template's job.
    ///
    /// Which also means **no new dependency**. A bar chart is `grid` and `rect`,
    /// both of them in Typst itself, so unlike `dot` there is no package to
    /// stage, nothing to licence and nothing to notarise — and the show rule is
    /// available wherever the PDF engine is.
    static let chartLanguage = "chart"

    /// The separators a chart row may arrive with, tried left to right.
    ///
    /// Tolerant on input the way `DocumentFormat.named` is deliberately
    /// tolerant. The guidance asks for `Label | 42`, and a 4B asked for "a
    /// chart" will write `Label, 42` and `Label: 42` just as readily, because
    /// those are what a table of numbers looks like everywhere else. Refusing
    /// them would mean a document that quietly has no picture in it.
    static let chartSeparators: [Character] = ["|", ",", ":", ";", "\t"]

    /// The numbers a chart draws, in the order the note wrote them.
    struct Chart: Equatable {
        struct Row: Equatable {
            let label: String
            /// The number exactly as it will be printed beside the bar.
            ///
            /// Kept as text rather than re-derived from `value`, because
            /// `1200` formatted back out of a `Double` is `1200.0`, and a
            /// document that adds a decimal place the owner did not write is
            /// making up precision.
            let shown: String
            let value: Double
        }

        let rows: [Row]

        /// Why a fence could not honestly be drawn, when it could not.
        ///
        /// A string rather than a flag because the log has to name it. "The
        /// chart would not draw" is the sort of message that cannot be traced
        /// afterwards; "no number on the row 'Break even soon'" can.
        enum Refusal: Error, Equatable, CustomStringConvertible {
            case nothingToDraw
            case rowWithoutANumber(String)
            case negativeValue(String)

            var description: String {
                switch self {
                case .nothingToDraw:
                    return "the chart had no numbers in it"
                case .rowWithoutANumber(let row):
                    return "no number on the row \"\(row)\""
                case .negativeValue(let row):
                    return "a negative number on the row \"\(row)\", and a bar chart "
                        + "drawn from a zero baseline would misrepresent it"
                }
            }
        }

        /// The chart a fence body describes, or the reason it is not one.
        ///
        /// **Strict, because Typst is stricter.** A row Typst cannot read is not
        /// a missing bar, it is `error: invalid float: not-a-number` and *no
        /// document at all* — the identical failure that cost the owner a report
        /// when the 4B wrote invalid Graphviz. So anything doubtful is refused
        /// here, where the fallback is a table of the same numbers, rather than
        /// left for the engine, where the fallback is nothing.
        static func parse(_ source: String) -> Result<Chart, Refusal> {
            var rows: [Row] = []
            for line in source.components(separatedBy: "\n") {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                guard !trimmed.isEmpty else { continue }
                guard let row = parseRow(trimmed) else {
                    return .failure(.rowWithoutANumber(trimmed))
                }
                // A zero-baselined bar cannot show a number below the baseline,
                // so drawing one would show a short bar where a loss belongs —
                // a picture that is not merely plain but false. Refused by name,
                // and the numbers survive as a table.
                guard row.value >= 0 else { return .failure(.negativeValue(trimmed)) }
                rows.append(row)
            }
            guard !rows.isEmpty else { return .failure(.nothingToDraw) }
            return .success(Chart(rows: rows))
        }

        /// One row of a chart, out of whatever the model wrote it as.
        ///
        /// **Split at the leftmost separator whose whole remainder is a number**,
        /// rather than the first or the last separator outright. `Q1, 2026
        /// revenue, 1200` has two commas and only the second one divides a label
        /// from a value; `Cost, 1,234` has two and only the first one does.
        /// Neither end of the line answers both, and asking "does what follows
        /// read as a number" does.
        static func parseRow(_ line: String) -> Row? {
            // A model writing a list of numbers writes a list, so the bullet it
            // reached for is not part of the label.
            var text = line
            for marker in ["- ", "* ", "+ "] where text.hasPrefix(marker) {
                text = String(text.dropFirst(marker.count))
                break
            }

            let characters = Array(text)
            for index in characters.indices where chartSeparators.contains(characters[index]) {
                let after = String(characters[(index + 1)...])
                guard let read = chartValue(after) else { continue }
                let label = String(characters[..<index])
                    .trimmingCharacters(in: .whitespaces)
                return Row(label: sanitisedLabel(label), shown: read.shown, value: read.value)
            }
            return nil
        }

        /// A label with the two characters that could break the encoding taken
        /// out of it.
        ///
        /// Backticks, because a canonical row is written back inside a fenced
        /// block and Pandoc re-emits that fence verbatim; a label carrying its
        /// own fence is the one thing that could make the block end early.
        /// Nothing else is removed — in particular `|` stays, because the value
        /// is always the *last* field of a canonical row, so a label may hold as
        /// many separators as it likes without splitting anything.
        static func sanitisedLabel(_ label: String) -> String {
            label
                .replacingOccurrences(of: "`", with: "")
                .trimmingCharacters(in: .whitespaces)
        }

        /// A number as the chart prints it.
        ///
        /// Whole numbers print whole — `1200`, not `1200.0` — because a document
        /// that adds a decimal place the owner did not write is making up
        /// precision. Everything else takes Swift's shortest round-tripping
        /// form, which keeps exactly the digits that were written rather than
        /// rounding them to a fixed number of places.
        ///
        /// The exponent form is the one shape that has to be caught: `String`
        /// renders a large `Double` as `1e+20`, and neither the template's
        /// reader nor `float()` can do anything with that.
        static func shown(_ value: Double) -> String {
            if value == value.rounded(), abs(value) < 1e15 {
                return String(Int64(value))
            }
            let text = String(value)
            guard !text.lowercased().contains("e") else { return String(format: "%.0f", value) }
            return text
        }

        /// The number a field holds and the text to print beside its bar, or
        /// `nil` when the field is not a number at all.
        ///
        /// Thousands separators, a currency mark and a trailing `%` are things a
        /// model writes around a number and none of them changes it, so they
        /// come off and are not printed.
        ///
        /// **`~300` and `300+` are different, and they are kept.** Both are what
        /// the local 4B actually writes — measured, on the run this paragraph
        /// was written from, where `300+` and `400+` on two rows cost the whole
        /// chart and the owner got a table. Refusing a picture over one
        /// character is the wrong trade, and so is quietly printing `300` for a
        /// number the note said was more than that. So the bar is drawn at 300
        /// and the text beside it still reads `300+`: a floor draws the shortest
        /// bar its own claim allows, which understates rather than overstates,
        /// and the qualifier is on the page where the reader can see it.
        ///
        /// `<` and ranges stay refused, because for those the number is not the
        /// one a bar from zero would be showing.
        ///
        /// The final check is deliberately narrow: `Double` accepts `1e9`,
        /// `inf`, `nan` and hexadecimal floats, and every one of those would
        /// reach Typst as something it cannot draw a bar for.
        static func chartValue(_ raw: String) -> (value: Double, shown: String)? {
            // Folded to ASCII first: the template measures its match in bytes,
            // and `≈` is three of them.
            var text = raw
                .trimmingCharacters(in: .whitespaces)
                .replacingOccurrences(of: "≈", with: "~")
            var about = ""
            if text.hasPrefix("~") {
                about = "~"
                text.removeFirst()
                text = text.trimmingCharacters(in: .whitespaces)
            }
            for symbol in ["$", "£", "€", "¥", "₹"] where text.hasPrefix(symbol) {
                text.removeFirst()
                break
            }
            if text.hasSuffix("%") { text.removeLast() }
            var atLeast = ""
            if text.hasSuffix("+") {
                atLeast = "+"
                text.removeLast()
            }
            text = text
                .replacingOccurrences(of: ",", with: "")
                .replacingOccurrences(of: " ", with: "")
                .trimmingCharacters(in: .whitespaces)
            guard !text.isEmpty else { return nil }
            guard text.allSatisfy({ $0.isASCII && ($0.isNumber || $0 == "." || $0 == "-") }) else {
                return nil
            }
            guard let value = Double(text) else { return nil }
            return (value, about + shown(value) + atLeast)
        }

        /// The rows as the template reads them: one `Label|number` per line.
        ///
        /// **Strict on output even though the parser is loose on input**, so
        /// that the Typst side is a split and a `float()` with nothing to guess
        /// at. The value is the last field, always, which is what makes a label
        /// containing `|` harmless.
        ///
        /// Tabs were the obvious separator and are ruled out: Pandoc's reader
        /// silently expands them to spaces, so a tab-separated row arrives at
        /// Typst with no separator at all and the compile dies on an
        /// out-of-bounds. Anyone changing this encoding has to re-check it
        /// through Pandoc, not just in Typst.
        var canonicalSource: String {
            rows.map { "\($0.label)|\($0.shown)" }.joined(separator: "\n")
        }
    }

    /// Whether the note asks for a chart at all.
    static func hasChart(_ markdown: String) -> Bool {
        markdown.range(
            of: "(?m)^\\s*(```|~~~)\\s*\(chartLanguage)\\b",
            options: .regularExpression
        ) != nil
    }

    /// The same numbers, as a markdown table.
    ///
    /// **A chart that will not draw becomes a table, not a deletion.** This is
    /// the one place the chart path can do better than `withoutDiagrams`: a
    /// broken graph has no textual equivalent, so it has to go, but a chart's
    /// data *is* a table. The reader loses the picture and keeps every fact.
    ///
    /// Built from the raw lines rather than from a parsed `Chart`, because the
    /// case that needs it most is the fence that would not parse — the numbers
    /// on the rows that were fine still belong in the document.
    static func chartAsTable(_ source: String) -> String {
        func cell(_ text: String) -> String {
            // A pipe inside a cell would otherwise open a third column.
            text.replacingOccurrences(of: "|", with: "\\|")
        }

        var rows: [String] = []
        for line in source.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { continue }
            if let row = Chart.parseRow(trimmed) {
                rows.append("| \(cell(row.label)) | \(row.shown) |")
            } else {
                // Not a number, so it is not a value; the line is kept whole
                // rather than guessed at, because losing it would be the lie.
                rows.append("| \(cell(trimmed)) |  |")
            }
        }
        guard !rows.isEmpty else { return "" }
        return (["| Item | Value |", "| --- | --- |"] + rows).joined(separator: "\n")
    }

    /// The note with every chart fence replaced by a table of its numbers.
    ///
    /// For DOCX and PPTX, which never see the Typst template at all, and as the
    /// second attempt when a PDF failed with a chart in it.
    static func chartsAsTables(_ markdown: String) -> String {
        rewritingChartFences(markdown) { body, _ in
            let table = chartAsTable(body)
            return table.isEmpty ? [] : table.components(separatedBy: "\n")
        }.markdown
    }

    /// Every chart fence rewritten by `replacement`, fence lines and all.
    ///
    /// - Returns: the rewritten note, and the first refusal a fence produced.
    ///   A fence the model never closed leaves the note exactly as it was, for
    ///   the same reason `withoutDiagrams` does: swallowing the rest of the
    ///   document is far worse than an undrawn chart.
    private static func rewritingChartFences(
        _ markdown: String,
        replacement: (_ body: String, _ parsed: Result<Chart, Chart.Refusal>) -> [String]
    ) -> (markdown: String, refusal: Chart.Refusal?) {
        var output: [String] = []
        var collecting: (fence: String, body: [String])?
        var refusal: Chart.Refusal?
        var sawAFence = false

        for line in markdown.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if let open = collecting {
                if trimmed.hasPrefix(open.fence) {
                    let body = open.body.joined(separator: "\n")
                    let parsed = Chart.parse(body)
                    if case .failure(let why) = parsed, refusal == nil { refusal = why }
                    output.append(contentsOf: replacement(body, parsed))
                    collecting = nil
                } else {
                    collecting?.body.append(line)
                }
                continue
            }
            var opened = false
            for fence in ["```", "~~~"] where trimmed.hasPrefix(fence) {
                let language = trimmed.dropFirst(fence.count).trimmingCharacters(in: .whitespaces)
                if language.lowercased() == chartLanguage {
                    collecting = (fence, [])
                    sawAFence = true
                    opened = true
                }
                break
            }
            if !opened { output.append(line) }
        }
        guard collecting == nil else { return (markdown, nil) }
        guard sawAFence else { return (markdown, nil) }
        return (output.joined(separator: "\n"), refusal)
    }

    // MARK: - The template

    /// The Pandoc template, ready to write to a file and pass as `--template=`.
    ///
    /// - Parameter withDiagrams: whether the Graphviz package was staged on this
    ///   Mac. When it was not, the import and the show rule are both left out and
    ///   a `dot` fence renders as an ordinary code block — visible, honest, and
    ///   not a document that fails to compile at all. Typst has no conditional
    ///   import, so this decision has to be made out here.
    static func typst(withDiagrams: Bool) -> String {
        let diagramImport = withDiagrams
            ? "#import \"\(packageImport)\": render as render-graph\n"
            : ""
        // Scaled down to the measure, never up. `render`'s own `width` is a
        // stretch, so a small graph handed 100% comes out blown up to the full
        // column and a large one runs into the margin; measuring and scaling
        // does what a person means by "make it fit".
        let diagramRule = withDiagrams ? """

          show raw.where(lang: "\(diagramLanguage)"): it => block(
            width: 100%, above: 1.7em, below: 1.7em,
            layout(space => {
              let drawn = render-graph(it.text)
              let natural = measure(drawn).width
              let fit = if natural > space.width and natural > 0pt { space.width / natural } else { 1.0 }
              align(center, scale(drawn, x: fit * 100%, y: fit * 100%, reflow: true))
            }),
          )

        """ : ""

        return """
        #let sans = ("Avenir Next", "Helvetica Neue", "Libertinus Serif")
        #let serif = ("Charter", "Palatino", "Georgia", "Libertinus Serif")
        #let mono = ("Menlo", "DejaVu Sans Mono")
        #let ink = luma(26)
        #let quiet = luma(120)
        #let hairline = luma(205)
        #let linkcolour = rgb("#1F6FEB")
        // Grey rather than a colour of its own, for the same reason there is no
        // mark on the page: these are documents the owner forwards to other
        // people, and a house palette in the middle of one is his to explain.
        #let chartink = luma(88)

        \(diagramImport)
        #set terms(hanging-indent: 1.5em)

        // Pandoc writes `#horizontalrule` on older versions and `#divider()` on
        // newer ones, so both exist and both are the same short centred rule. A
        // thematic break is a pause, not a border.
        #let horizontalrule = align(center, block(above: 1.7em, below: 1.7em,
          line(length: 26%, stroke: 0.6pt + luma(185))))
        #let divider() = horizontalrule

        // A bar chart, drawn from the numbers rather than from a plotting
        // language, and drawn by Typst itself — `grid` and `rect` and nothing
        // else, which is why this needs no package and is therefore available
        // on every Mac that can make a PDF at all.
        //
        // The encoding is one `Label|number` per line with the number **last**,
        // so a label carrying its own `|` rejoins instead of splitting the row.
        // `DocumentTemplate.Chart` guarantees that shape before Pandoc ever sees
        // it; the check below is the second layer, because a row this cannot
        // read would otherwise be `invalid float` and no document at all.
        // Falling back to the source in a code box is ugly and honest, which is
        // the right way round for something that should never happen.
        #let bar-chart(source) = {
          let rows = ()
          let readable = true
          for line in source.split("\\n") {
            let cleaned = line.trim()
            if cleaned == "" { continue }
            let fields = cleaned.split("|")
            let shown = fields.last().trim()
            // Matched from the front and then measured to the end, rather than
            // anchored with the obvious end-of-string metacharacter. This file
            // is a *Pandoc* template before it is a Typst one, and Pandoc reads
            // that character as the opening of a variable — it refuses the whole
            // template, and every PDF fails, including ones with no chart in
            // them. Which is also why this sentence does not print it.
            // A leading `~` and a trailing `+` are allowed through and printed —
            // see `Chart.chartValue` for why the qualifier stays on the page —
            // but the bar itself is drawn from the bare number.
            let number = shown.match(regex("^[~]?[0-9]+([.][0-9]+)?[+]?"))
            if fields.len() < 2 or number == none or number.end != shown.len() {
              readable = false
              break
            }
            rows.push((
              label: fields.slice(0, fields.len() - 1).join("|").trim(),
              shown: shown,
              value: float(shown.replace("~", "").replace("+", "")),
            ))
          }
          if not readable or rows.len() == 0 { return raw(source, block: true) }
          let peak = calc.max(..rows.map(row => row.value))
          if peak <= 0.0 { peak = 1.0 }
          block(width: 100%, above: 1.6em, below: 1.6em, grid(
            // A fixed measure for the labels rather than `auto`: it keeps every
            // bar in a document starting at the same place, and it lets a long
            // label wrap instead of squeezing the bars into nothing.
            columns: (26%, 1fr, auto),
            column-gutter: (0.9em, 1.4em),
            row-gutter: 0.55em,
            align: (right + horizon, left + horizon, right + horizon),
            ..rows.map(row => (
              text(font: sans, size: 9pt, fill: quiet, hyphenate: false)[#row.label],
              // A hair of width on a zero, so the row still reads as a row.
              box(width: 100%, rect(
                width: calc.max(row.value / peak, 0.004) * 100%,
                height: 0.72em, radius: 1pt, stroke: none, fill: chartink,
              )),
              text(font: sans, size: 9pt, fill: ink)[#row.shown],
            )).flatten(),
          ))
        }

        #show figure.where(kind: table): set figure.caption(position: top)
        #show figure.where(kind: image): set figure.caption(position: bottom)

        $if(highlighting-definitions)$
        $highlighting-definitions$

        $endif$
        #let conf(
          title: none,
          subtitle: none,
          date: none,
          doc,
        ) = {
          set document(title: title)

          set page(
            paper: "a4",
            margin: (x: 3.2cm, top: 2.8cm, bottom: 2.6cm),
            numbering: none,
            header: context {
              if counter(page).get().first() > 1 and title != none {
                set text(font: sans, size: 8pt, fill: quiet)
                block(width: 100%, inset: (bottom: 6pt), stroke: (bottom: 0.4pt + hairline))[#title]
              }
            },
            footer: context {
              set align(center)
              set text(font: sans, size: 8.5pt, fill: quiet)
              counter(page).display("1")
            },
          )

          set text(font: serif, size: 11pt, fill: ink, lang: "en", hyphenate: true)
          set par(justify: true, leading: 0.78em, spacing: 0.95em)

          show heading: set text(font: sans, fill: black)
          show heading.where(level: 1): set text(size: 15.5pt, weight: 700)
          show heading.where(level: 2): set text(size: 13pt, weight: 600)
          show heading.where(level: 3): set text(size: 11pt, weight: 600)
          show heading.where(level: 4): set text(size: 10pt, weight: 600, fill: quiet)
          show heading: it => block(
            above: if it.level == 1 { 1.9em } else { 1.5em },
            below: 0.65em,
            it,
          )

          set list(indent: 0.6em, spacing: 0.62em, marker: text(fill: quiet)[•])
          set enum(indent: 0.6em, spacing: 0.62em)

          show quote.where(block: true): it => block(
            above: 1.2em, below: 1.2em, width: 100%,
            inset: (left: 1em, y: 0.35em),
            stroke: (left: 2pt + luma(180)),
            text(fill: luma(70), it.body),
          )

          show raw.where(block: false): it => box(
            fill: luma(243), inset: (x: 2pt), outset: (y: 2.5pt), radius: 2pt,
            text(font: mono, size: 0.86em, it),
          )
          show raw.where(block: true): it => block(
            width: 100%, fill: luma(246), inset: 9pt, radius: 3pt,
            above: 1.2em, below: 1.2em,
            text(font: mono, size: 9pt, it),
          )

          // Pandoc draws its own rule under the header row, and this draws one
          // too; hiding its line is what stops the two landing a hair apart.
          show table.hline: none
          set table(
            inset: (x: 8pt, y: 6.5pt),
            align: left + horizon,
            stroke: (_, y) => (bottom: if y == 0 { 0.8pt + luma(60) } else { 0.4pt + hairline }),
          )
          // Pandoc writes `align: (auto, auto, …)` on every table and wraps the
          // whole thing in `align(center)`, so `auto` resolves to centred and
          // every cell of every generated table comes out centred. A show rule
          // beats the argument.
          show table.cell: set align(left + horizon)
          // A justified cell in a narrow column hyphenates, and "Speed Consis-
          // tency" across two lines of a table is the sort of thing that makes a
          // document look machine-made.
          show table: set par(justify: false)
          show table: set text(hyphenate: false)
          show table.cell.where(y: 0): set text(font: sans, size: 9.5pt, weight: 600)
          show figure.where(kind: table): set align(left)
          show figure.where(kind: table): set block(above: 1.4em, below: 1.4em)
        \(diagramRule)
          // **Not gated on `withDiagrams`, and the asymmetry is the point.** A
          // `dot` fence needs a package staged on this Mac, so the diagram rule
          // above has to be left out where it was not; a chart is drawn by
          // Typst itself, so there is no second thing that can be missing. If
          // this template is being used at all, charts draw.
          show raw.where(lang: "\(chartLanguage)"): it => bar-chart(it.text)

          show link: set text(fill: linkcolour)

          if title != none {
            block(below: 2.2em, width: 100%)[
              #set par(justify: false)
              #text(font: sans, size: 21pt, weight: 700, hyphenate: false)[#title]
              #if subtitle != none {
                linebreak()
                text(font: sans, size: 13pt, weight: 500, fill: quiet, hyphenate: false)[#subtitle]
              }
              #if date != none {
                linebreak()
                v(0.35em)
                text(font: sans, size: 9pt, fill: quiet, tracking: 0.04em)[#upper[#date]]
              }
              #v(0.7em)
              #line(length: 100%, stroke: 0.8pt + luma(60))
            ]
          }

          doc
        }

        $for(header-includes)$
        $header-includes$

        $endfor$
        #show: doc => conf(
        $if(title)$
          title: [$title$],
        $endif$
        $if(subtitle)$
          subtitle: [$subtitle$],
        $endif$
        $if(date)$
          date: [$date$],
        $endif$
          doc,
        )

        $if(toc)$
        #outline(title: auto, depth: $toc-depth$)

        $endif$
        $body$

        """
    }

    // MARK: - Getting the markdown ready

    /// A note, straightened out for conversion.
    struct Prepared: Equatable {
        let markdown: String
        /// The note's own opening heading, when it said something the title did
        /// not. Drawn under the title in grey rather than thrown away.
        let subtitle: String?
        /// Why a chart in the note ended up as a table of the same numbers, when
        /// one did. `nil` means every chart in the note is being drawn.
        ///
        /// A sentence rather than a flag because two different things reach the
        /// owner from it: the log needs the row that caused it, and the model
        /// needs only to know it happened. `DocumentExporter` splits them.
        let chartBecameATable: String?
    }

    /// The note as the document should be made from it.
    ///
    /// Three repairs, all of them for things seen coming out of the 4B model on
    /// the owner's own Mac rather than imagined.
    ///
    /// - Parameter drawingCharts: whether the format about to be produced can
    ///   draw one. Only the PDF path goes through the Typst template, so a chart
    ///   fence in a DOCX or a PPTX would otherwise arrive as literal text in
    ///   `word/document.xml` — the fence body, verbatim, where a picture was
    ///   promised. Those formats get the table instead.
    static func prepared(
        _ markdown: String,
        title: String,
        drawingCharts: Bool = true
    ) -> Prepared {
        let (body, subtitle) = withoutOpeningTitle(markdown, title: title)
        let tidied = splitRunOnBullets(body)

        guard hasChart(tidied) else {
            return Prepared(markdown: tidied, subtitle: subtitle, chartBecameATable: nil)
        }
        guard drawingCharts else {
            return Prepared(
                markdown: chartsAsTables(tidied),
                subtitle: subtitle,
                chartBecameATable: "this format is not typeset by Typst, so a chart cannot be drawn"
            )
        }
        // Canonicalised here rather than trusted to the engine. A row Typst
        // cannot read is not a missing bar — it is `error: invalid float` and no
        // PDF at all, and the whole document is lost to a decoration.
        let rewritten = rewritingChartFences(tidied) { body, parsed in
            switch parsed {
            case .success(let chart):
                return ["```\(chartLanguage)"] + chart.canonicalSource.components(separatedBy: "\n")
                    + ["```"]
            case .failure:
                let table = chartAsTable(body)
                return table.isEmpty ? [] : table.components(separatedBy: "\n")
            }
        }
        return Prepared(
            markdown: rewritten.markdown,
            subtitle: subtitle,
            chartBecameATable: rewritten.refusal.map(\.description)
        )
    }

    // MARK: The heading that would otherwise be a second title

    /// The note without its opening `#` heading, and that heading when it is
    /// worth keeping as a subtitle.
    ///
    /// **Every note has two titles and only one of them belongs on the page.**
    /// `write_note` takes a short `title` — which names the file, and which the
    /// template sets — and then writes `# <title>` at the top of the markdown so
    /// the file is self-describing in a Signal thread. Converted, that is the
    /// same words twice in two sizes.
    ///
    /// When the model wrote its own heading instead, the two are *different*
    /// words saying the same thing — "Local LLM vs Hosted API Comparison Report"
    /// under "Local Language Model on Mac vs Hosted API: A Comparative Analysis",
    /// which is worse, because it reads as an editing mistake rather than a
    /// duplicate. So the heading comes off either way, and becomes the subtitle
    /// when it is not simply the title again.
    ///
    /// Level one only. `## Something` at the top of a note is a section, and a
    /// document that silently loses its first section heading is a bug nobody
    /// would find by looking at the code.
    static func withoutOpeningTitle(
        _ markdown: String,
        title: String
    ) -> (body: String, subtitle: String?) {
        let lines = markdown.components(separatedBy: "\n")
        guard let first = lines.firstIndex(where: {
            !$0.trimmingCharacters(in: .whitespaces).isEmpty
        }) else { return (markdown, nil) }

        let heading = lines[first].trimmingCharacters(in: .whitespaces)
        guard heading.hasPrefix("# ") else { return (markdown, nil) }
        let written = heading.dropFirst(2).trimmingCharacters(in: .whitespaces)
        guard !written.isEmpty else { return (markdown, nil) }

        var remaining = Array(lines[(first + 1)...])
        while let next = remaining.first, next.trimmingCharacters(in: .whitespaces).isEmpty {
            remaining.removeFirst()
        }
        // Matched through the slug so that punctuation and case do not decide
        // it: "Quarterly brief" and "# Quarterly Brief!" are the same title.
        let same = !title.isEmpty && NoteSlug.slug(from: written) == NoteSlug.slug(from: title)
        return (remaining.joined(separator: "\n"), same ? nil : written)
    }

    // MARK: The diagram that will not draw

    /// Whether the note asks for a diagram at all.
    static func hasDiagram(_ markdown: String) -> Bool {
        markdown.range(
            of: "(?m)^\\s*(```|~~~)\\s*\(diagramLanguage)\\b",
            options: .regularExpression
        ) != nil
    }

    /// The note with its diagram fences taken out entirely.
    ///
    /// **Because a broken diagram must not take the document with it.** Graphviz
    /// is a language, the model is a 4B, and it writes invalid ones — the first
    /// it produced on this Mac used `edge` as a node name and an unquoted
    /// `#FF6347`, either of which stops Typst dead. That failed the whole
    /// conversion, so a syntax error in a decoration cost the owner the report.
    ///
    /// Removed rather than shown as source: the point of the second attempt is a
    /// document that reads properly, and a page of `digraph {` in a monospace box
    /// is the thing this release exists to stop. The prose around it always
    /// survives, and the tool result says the diagram was dropped so the model
    /// can mention it rather than pretending it is there.
    static func withoutDiagrams(_ markdown: String) -> String {
        var output: [String] = []
        var droppingUntilFenceEnds: String?

        for line in markdown.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if let fence = droppingUntilFenceEnds {
                if trimmed.hasPrefix(fence) { droppingUntilFenceEnds = nil }
                continue
            }
            for fence in ["```", "~~~"] where trimmed.hasPrefix(fence) {
                let language = trimmed.dropFirst(fence.count).trimmingCharacters(in: .whitespaces)
                if language.lowercased() == diagramLanguage {
                    droppingUntilFenceEnds = fence
                }
                break
            }
            if droppingUntilFenceEnds == nil { output.append(line) }
        }
        // A fence that never closed would otherwise swallow the rest of the
        // note, which is a far worse outcome than an undrawn diagram.
        guard droppingUntilFenceEnds == nil else { return markdown }
        return output.joined(separator: "\n")
    }

    // MARK: The list that arrived as a paragraph

    /// The longest a run-on item can be before this leaves the line alone.
    ///
    /// A guard against prose, and measured rather than picked: the longest item
    /// in the report the local model wrote on the owner's Mac was 88 characters,
    /// and the shortest dashed clause in a paragraph of real prose that tripped
    /// this was 130. Anything in between is a coin toss, and the cheaper mistake
    /// is leaving a run-on alone — a paragraph broken into bullets that were
    /// never a list is unreadable, where a list left as a paragraph is merely
    /// ugly.
    static let longestRunOnItem = 100

    /// Bullets that arrived on one line, put back on separate lines.
    ///
    /// **What the local model actually writes.** Asked for a report it produces
    ///
    ///     **Running Locally:** - One-time hardware investment - No per-token
    ///     fees after setup - Electricity costs for inference
    ///
    /// which is a list in every sense except the one Pandoc can see, so it sets
    /// as a run-on paragraph full of hyphens. This is the single largest
    /// difference between what a 4B model produces and something worth sending.
    ///
    /// Conservative on purpose: two or more separators on one line, nothing
    /// inside a fence, nothing that is already a heading or a table row, and no
    /// item longer than `longestRunOnItem`. A sentence with one dash in it is
    /// untouched, which is most sentences that have one at all.
    static func splitRunOnBullets(_ markdown: String) -> String {
        var output: [String] = []
        var insideFence = false

        for line in markdown.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
                insideFence.toggle()
                output.append(line)
                continue
            }
            guard !insideFence,
                  !trimmed.isEmpty,
                  !trimmed.hasPrefix("#"),
                  !trimmed.hasPrefix(">"),
                  !trimmed.contains("|")
            else {
                output.append(line)
                continue
            }

            // A line that is itself a bullet counts too: "- a - b - c" is one
            // list item holding three.
            var body = trimmed
            var marker = ""
            for prefix in ["- ", "* ", "+ "] where body.hasPrefix(prefix) {
                marker = prefix
                body = String(body.dropFirst(prefix.count))
                break
            }

            let parts = body.components(separatedBy: " - ")
            guard parts.count >= 3 else {
                output.append(line)
                continue
            }
            let items = parts.dropFirst().map { $0.trimmingCharacters(in: .whitespaces) }
            guard items.allSatisfy({ $0.count > 1 && $0.count <= longestRunOnItem }) else {
                output.append(line)
                continue
            }

            // Whatever came before the first separator keeps its own line — it
            // is usually the bolded lead-in the list belongs to. When the line
            // was already a bullet, it stays a bullet.
            let lead = parts[0].trimmingCharacters(in: .whitespaces)
            if !lead.isEmpty {
                output.append(marker.isEmpty ? lead : marker + lead)
                if marker.isEmpty { output.append("") }
            }
            output.append(contentsOf: items.map { "- " + $0 })
        }
        return output.joined(separator: "\n")
    }
}
