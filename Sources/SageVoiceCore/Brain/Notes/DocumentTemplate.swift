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

        \(diagramImport)
        #set terms(hanging-indent: 1.5em)

        // Pandoc writes `#horizontalrule` on older versions and `#divider()` on
        // newer ones, so both exist and both are the same short centred rule. A
        // thematic break is a pause, not a border.
        #let horizontalrule = align(center, block(above: 1.7em, below: 1.7em,
          line(length: 26%, stroke: 0.6pt + luma(185))))
        #let divider() = horizontalrule

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
    }

    /// The note as the document should be made from it.
    ///
    /// Two repairs, both of them for things seen coming out of the 4B model on
    /// the owner's own Mac rather than imagined.
    static func prepared(_ markdown: String, title: String) -> Prepared {
        let (body, subtitle) = withoutOpeningTitle(markdown, title: title)
        return Prepared(markdown: splitRunOnBullets(body), subtitle: subtitle)
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
