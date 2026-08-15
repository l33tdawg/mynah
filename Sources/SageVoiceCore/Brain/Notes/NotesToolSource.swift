import Foundation

/// Publishes `write_note`, `read_note` and `list_notes` to the agent loop.
///
/// A `ToolProviding` for the same reason `WebSearchToolSource` is one: there is
/// nothing to talk to, so an MCP server would be a child process and a JSON-RPC
/// handshake wrapped around three file operations.
///
/// ## Why the model never sees a path
///
/// Every other file-writing tool in this class of product takes a path, and then
/// spends its life defending one: reject `..`, reject absolute paths, resolve
/// symlinks, re-check after resolving, remember that `%2e%2e` and `‥` exist.
/// That defence has to be perfect and the attack has to work once.
///
/// This takes a *title* instead and derives the filename itself, keeping only
/// alphanumerics and turning everything else into a hyphen. Traversal is not
/// blocked here; it is unrepresentable. There is no input to `write_note` that
/// produces a file outside the notes directory, because the only thing joined to
/// that directory is a string this file built out of a restricted alphabet.
///
/// That matters more here than in most places. The instructions reaching this
/// tool have passed through speech recognition, which mishears, and through
/// `web_search` results, which are written by strangers — the same context that
/// holds a tool able to write to disk also holds text an attacker chose. The
/// containment cannot be the model's judgement.
public final class NotesToolSource: ToolProviding, @unchecked Sendable {

    public static let writeToolName = "write_note"
    public static let readToolName = "read_note"
    public static let listToolName = "list_notes"
    public static let sendToolName = "send_file"

    /// For `CompositeToolSource.Source.expectedToolNames` and the prompt allowlist.
    public static let toolNames: Set<String> = [writeToolName, readToolName, listToolName, sendToolName]

    /// The largest file that goes out over Signal.
    ///
    /// Signal's own ceiling is 100 MiB, and the last few of those are envelope
    /// and encryption overhead. Refusing at 95 MB with a sentence beats letting
    /// signal-cli reject the send: that failure path drops **the whole reply**
    /// and retries as text, so the owner would lose the answer as well as the
    /// file and be told why by nothing at all.
    public static let maximumAttachmentBytes = 95 * 1024 * 1024

    /// Roughly fifteen pages. Large enough for any document a 4B model will
    /// actually produce in one turn, small enough that a reasoning runaway
    /// cannot fill the appliance's disk before anyone notices.
    public static let maximumContentCharacters = 32_000

    /// A ceiling on the directory, not a retention policy. It refuses rather
    /// than pruning: deleting the owner's oldest note to make room for one the
    /// model decided to write is not a trade anything here is entitled to make.
    public static let maximumNoteCount = 500

    /// Longest slug before truncation. Well inside every filesystem limit, and
    /// short enough to stay readable in a Signal attachment row.
    public static let maximumSlugLength = 60

    /// Entries `list_notes` will name before it stops and says how many are left.
    public static let maximumListedNotes = 40

    public enum Failure: Error, CustomStringConvertible, Equatable {
        case noteDirectoryFull(limit: Int)

        public var description: String {
            switch self {
            case .noteDirectoryFull(let limit):
                return "there are already \(limit) notes, which is the limit; nothing was written"
            }
        }
    }

    /// What happens to a note once it is written, in the words the model will
    /// read back.
    ///
    /// Injected rather than fixed because the two hosts genuinely differ, and
    /// the difference is one the model will say out loud. The daemon attaches
    /// the file to the Signal reply; Mynah has no attachment channel and only
    /// saves it. A single hardcoded "the file is attached to your reply" would
    /// have been true on the appliance and a lie in the app — and a lie the
    /// owner cannot check, because they would go looking for a file that never
    /// arrived and conclude the appliance had eaten it.
    public enum Delivery: Sendable {
        /// The host sends the file with the reply that mentions it.
        case attachedToReply
        /// The host writes it and nothing more.
        case savedOnDisk

        var sentence: String {
            switch self {
            case .attachedToReply:
                return "The file is attached to your reply, so do not read it out loud — just say what it covers in one sentence."
            case .savedOnDisk:
                return "The file is saved in the owner's notes, not sent anywhere. Tell them its title in one sentence; do not read it out loud."
            }
        }

        /// The same distinction for a file the owner already had, which is a
        /// different sentence because the owner already knows what is in it.
        ///
        /// After `write_note` the model has to say what it wrote. After
        /// `send_file` it does not — they asked for their own ferry ticket back,
        /// and a paragraph describing the ticket to the person who bought it is
        /// the appliance filling silence.
        var handbackSentence: String {
            switch self {
            case .attachedToReply:
                return "It is attached to your reply. Say in one line that it is on its way and stop; do not describe what is in it."
            case .savedOnDisk:
                return "It is on this answer for the owner to click and open. Say in one line that it is there and stop; do not describe what is in it."
            }
        }
    }

    private let directory: URL
    private let delivery: Delivery
    private let exporter: DocumentExporter?
    private let fileManager: FileManager
    private let log: @Sendable (String) -> Void

    private let lock = NSLock()
    /// Files this turn is handing the owner, so the host can put them on the
    /// reply that mentions them. Notes `write_note` just made, and files
    /// `send_file` was asked to give back.
    private var outgoing: [URL] = []

    /// - Parameter delivery: defaults to the honest-anywhere answer. A host that
    ///   actually ships the file has to say so explicitly.
    /// - Parameter exporter: what turns a note into a PDF, a Word document or a
    ///   deck. `nil` on a Mac where Pandoc was never staged — a development
    ///   checkout without `vendor/pandoc`, which is every fresh clone — and the
    ///   tool then offers markdown only rather than promising a file it cannot
    ///   produce.
    public init(
        directory: URL = NotesToolSource.defaultDirectory(),
        delivery: Delivery = .savedOnDisk,
        exporter: DocumentExporter? = DocumentExporter.locate(),
        fileManager: FileManager = .default,
        log: @escaping @Sendable (String) -> Void = { _ in }
    ) {
        self.directory = directory
        self.delivery = delivery
        self.exporter = exporter
        self.fileManager = fileManager
        self.log = log
    }

    /// Where converted documents go.
    ///
    /// Beside the notes rather than among them: `list_notes` and `read_note`
    /// work on the markdown, and a folder holding both `budget.md` and
    /// `budget.pdf` would list the same document twice and read back the wrong
    /// one.
    public var documentsDirectory: URL {
        directory.appendingPathComponent("documents", isDirectory: true)
    }

    /// Alongside the provider keys and the OAuth token, for the same reason they
    /// are there: it is the owner's data, on the owner's machine, and it is not
    /// something they should find in a Finder window by accident.
    public static func defaultDirectory(
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> URL {
        homeDirectory
            .appendingPathComponent("Library/Application Support/SAGE Voice Bridge", isDirectory: true)
            .appendingPathComponent("Notes", isDirectory: true)
    }

    /// Where notes are kept. Exposed so the daemon can name it in a log line and
    /// a test can assert on it.
    public var notesDirectory: URL { directory }

    // MARK: - File handoff

    /// Records a file for the reply to carry, once.
    ///
    /// The duplicate is reachable in one ordinary turn: the model writes a
    /// document and then, being helpful, calls `send_file` on the thing it just
    /// wrote. Both queue the same URL and Signal shows the owner two identical
    /// attachments — which reads as the appliance having lost track of itself.
    ///
    /// Its own synchronous method because taking a lock inside an async
    /// function is a suspension point away from a deadlock, and the compiler
    /// says so.
    /// Compared on the resolved path, not the URL. `write_note` builds its URL
    /// by appending to the notes directory and `send_file` reads one back from
    /// `contentsOfDirectory`, and on macOS those are `/var/…` and `/private/var/…`
    /// for the same file — so `==` sees two different files and the owner gets
    /// their document twice.
    private func deliver(_ file: URL) {
        let resolved = file.resolvingSymlinksInPath().standardizedFileURL.path
        lock.lock()
        let known = outgoing.contains {
            $0.resolvingSymlinksInPath().standardizedFileURL.path == resolved
        }
        if !known { outgoing.append(file) }
        lock.unlock()
    }

    /// The files this turn is handing over, and clears the list.
    ///
    /// Draining rather than reading is deliberate: the host attaches these to
    /// one reply, and a file that rode along with a second reply because nobody
    /// cleared the list would be a confusing bug to chase from the phone — and
    /// a worse one now that `send_file` can put the owner's own documents in
    /// here, because the second reply might be in a different thread.
    public func drainOutgoingFiles() -> [URL] {
        lock.lock()
        defer { lock.unlock() }
        let drained = outgoing
        outgoing = []
        return drained
    }

    // MARK: - ToolProviding

    /// Descriptions are terse on purpose.
    ///
    /// Catalogue *size* — not prompt wording — was the dominant factor in
    /// routing accuracy for this model: 27 tools scored 5–6/12 where 14 scored
    /// 12/12 (see `BrainPrompts.voiceToolAllowlist`). These three take the voice
    /// catalogue from 15 to 18, so every sentence here has to earn its tokens.
    public func listTools() async throws -> [MCPTool] {
        [
            MCPTool(
                name: Self.writeToolName,
                description: """
                Save a document and send it to the owner as a file. Use this when they ask for \
                notes, a written summary, a document, a PDF, a Word file, a deck or a list they \
                want to keep. Not for ordinary answers, which you just speak.
                """,
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "title": .object([
                            "type": .string("string"),
                            "description": .string("Short title for the document, in plain words.")
                        ]),
                        "content": .object([
                            "type": .string("string"),
                            "description": .string(contentGuidance)
                        ]),
                        // Offered only where it can be honoured. A model told
                        // `pdf` is available on a Mac with no converter will use
                        // it, say it has, and be wrong — and the owner would go
                        // looking for a file that was never made.
                        "format": .object([
                            "type": .string("string"),
                            "enum": .array(offeredFormats.map { .string($0.rawValue) }),
                            "description": .string(
                                "markdown for a plain note. pdf, docx or pptx when the owner "
                                    + "asked for that kind of file. For pptx write each slide as "
                                    + "a `## Heading` with a few short bullets under it."
                            )
                        ])
                    ]),
                    "required": .array([.string("title"), .string("content")])
                ])
            ),
            MCPTool(
                name: Self.readToolName,
                description: """
                Read back a document you saved earlier with write_note, by its title.
                """,
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "title": .object([
                            "type": .string("string"),
                            "description": .string("The title the document was saved under.")
                        ])
                    ]),
                    "required": .array([.string("title")])
                ])
            ),
            MCPTool(
                name: Self.listToolName,
                description: """
                List the titles of documents saved with write_note.
                """,
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([:])
                ])
            ),
            // **The second half of a two-step, and the description says so.**
            //
            // A one-shot "send the thing about X" tool would have to search and
            // send in one call, which means the model never sees what it is
            // about to hand over — and the owner asked for the opposite: *"maybe
            // do it in 2 steps - look it up; then send - this way we don't burn
            // the context window in 1 go."*
            //
            // So the first step is `list_notes`, which already exists and
            // already sees files the owner sent, because `SignalAttachmentStore`
            // writes a note for each one. Naming it here is what stops the model
            // guessing a title and getting the "did you mean" line instead of
            // sending anything.
            MCPTool(
                name: Self.sendToolName,
                description: """
                Give the owner back a file that is already saved — something they sent you \
                earlier, or a document you wrote before. Use it when they ask you to send, \
                share or resend a file, photo, ticket, receipt or PDF. Call list_notes first \
                and use a title from that list.
                """,
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "title": .object([
                            "type": .string("string"),
                            "description": .string(
                                "The title it is saved under, as list_notes shows it."
                            )
                        ])
                    ]),
                    "required": .array([.string("title")])
                ])
            )
        ]
    }

    /// What to put in a document, said where it costs nothing.
    ///
    /// **Here rather than in the system prompt on purpose.** The prompt is held
    /// under a hard character budget because every line of it is prefilled on
    /// every turn, including the thousands of turns that never write a document.
    /// A tool schema is read at the moment the model is choosing to write one,
    /// which is both cheaper and better placed.
    ///
    /// The diagram sentence appears only where a diagram can actually be drawn.
    /// A model told it can draw one on a Mac with no Graphviz staged would write
    /// the fence, and the owner would get a page of `digraph {` in a monospace
    /// box where a picture was promised.
    var contentGuidance: String {
        var lines = [
            "The document itself. Markdown is fine here — headings, lists, "
                + "tables and short paragraphs all come out properly typeset. "
                + "Put every list item on its own line starting with \"- \"; "
                + "items strung along one line read as a paragraph full of hyphens."
        ]
        if exporter?.drawsDiagrams == true, offeredFormats.contains(.pdf) {
            lines.append(
                "Where a picture says it better than a sentence — a flow, a "
                    + "comparison, how things connect — include a ```dot fenced block "
                    + "of Graphviz and it is drawn into the document. Plain nodes and "
                    + "edges with labels; no subgraphs or clusters, and quote every "
                    + "colour. One or two at most, and only where one genuinely helps."
            )
        }
        return lines.joined(separator: " ")
    }

    /// The formats this Mac can actually produce, markdown always first.
    ///
    /// Read off the exporter rather than listed: a bundle with Pandoc but no
    /// Typst can write a deck and cannot write a PDF, and the schema should say
    /// so rather than leave the model to find out.
    var offeredFormats: [DocumentFormat] {
        DocumentFormat.allCases.filter { format in
            format == .markdown || (exporter?.canProduce(format) ?? false)
        }
    }

    public func call(name: String, arguments: [String: JSONValue]) async throws -> String {
        switch name {
        case Self.writeToolName:
            return try await write(arguments: arguments)
        case Self.readToolName:
            return try read(arguments: arguments)
        case Self.listToolName:
            return try list()
        case Self.sendToolName:
            return handBack(arguments: arguments)
        default:
            throw CompositeToolSource.Failure.unknownTool(name)
        }
    }

    // MARK: - write_note

    private func write(arguments: [String: JSONValue]) async throws -> String {
        let content = arguments["content"]?.stringValue ?? ""
        guard !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            // **Names the cause, because the model cannot see it.** A document
            // travels inside this call, so a call that ran past the turn's token
            // ceiling arrives here looking exactly like one where the model
            // forgot the argument — and the old sentence described only the
            // second. Told nothing else, the model tried again identically:
            // eight `write_note` calls in one 130-second turn, all empty, all
            // reported the same way, before the iteration cap ended it.
            //
            // Cheaper than plumbing truncation down into the tool, and it works
            // for whichever of the two actually happened.
            return """
            No content was given, so no note was written. If your reply was cut off partway \
            through this call, the document was too long to send in one piece — write a \
            shorter one, or split it across two notes.
            """
        }

        let requestedTitle = (arguments["title"]?.stringValue ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        // A titleless note is still a note the owner asked for. Falling back to
        // the document's own first line beats refusing, and beats "untitled".
        let title = requestedTitle.isEmpty ? NoteSlug.titleFromContent(content) : requestedTitle
        let slug = NoteSlug.slug(from: title)
        let filename = slug + ".md"

        try OwnerOnlyFileSecurity.prepareDirectory(directory)
        let destination = directory.appendingPathComponent(filename, isDirectory: false)
        let isReplacement = fileManager.fileExists(atPath: destination.path)

        if !isReplacement {
            let existing = try existingNoteURLs().count
            guard existing < Self.maximumNoteCount else {
                throw Failure.noteDirectoryFull(limit: Self.maximumNoteCount)
            }
        }

        let body = NoteSlug.truncate(content, to: Self.maximumContentCharacters)
        // A heading, because these are read as documents rather than as speech,
        // and because it is what makes the file self-describing once it has left
        // the appliance and is sitting in someone's Signal thread.
        let document = body.hasPrefix("#") ? body : "# \(title)\n\n\(body)"

        try Data(document.utf8).write(to: destination, options: [.atomic])
        try OwnerOnlyFileSecurity.protectFile(destination)

        log("[notes] wrote \(filename) (\(document.count) characters)\(isReplacement ? ", replacing an earlier note" : "")")

        var sentences = [
            isReplacement
                ? "Replaced the earlier note titled \"\(title)\". The new file is \(filename)."
                : "Wrote \"\(title)\" as \(filename)."
        ]
        if body.count < content.count {
            sentences.append("It was too long and was cut at \(Self.maximumContentCharacters) characters — tell the owner that.")
        }

        // The markdown is always written first and always kept. It is what
        // `read_note` reads back, what survives a converter that is not there,
        // and what the owner can still open in ten years — a `.docx` is a
        // format, a note is the thing they asked for.
        let (delivered, note) = await export(
            source: destination,
            slug: slug,
            title: title,
            asked: arguments["format"]?.stringValue ?? ""
        )
        if let note { sentences.append(note) }

        deliver(delivered)

        // Says what already happened to the file, so the model does not go on to
        // offer a delivery it cannot perform. Which host is speaking matters:
        // see `Delivery`.
        sentences.append(delivery.sentence)
        return sentences.joined(separator: " ")
    }

    /// Turns the note into whatever was asked for, or explains why it did not.
    ///
    /// - Returns: the file to hand the owner, and a sentence for the model when
    ///   something is worth saying. The markdown is the fallback in every
    ///   failing case, because a note the owner did not quite ask for is worth
    ///   more than an apology with no file attached.
    private func export(
        source: URL,
        slug: String,
        title: String,
        asked: String
    ) async -> (URL, String?) {
        guard let format = DocumentFormat.named(asked) else {
            return (source, "\"\(asked)\" isn't a format Mynah writes, so it saved a note "
                + "instead — say so, and offer a PDF, a Word document or a deck.")
        }
        guard format != .markdown else { return (source, nil) }

        guard let exporter, exporter.canProduce(format) else {
            return (source, "This Mynah can't make \(format.spokenName) — the converter isn't "
                + "installed on this Mac — so it saved a note instead. Tell the owner that "
                + "plainly rather than pretending.")
        }

        let destination = documentsDirectory
            .appendingPathComponent(slug + "." + format.fileExtension, isDirectory: false)
        do {
            try OwnerOnlyFileSecurity.prepareDirectory(documentsDirectory)
            let conversion = try await exporter.convert(
                source: source,
                to: format,
                at: destination,
                title: title,
                date: DocumentExporter.writtenDate()
            )
            var note = "It was made into \(format.spokenName): "
                + destination.lastPathComponent + "."
            // Said rather than swallowed. The owner asked for a diagram and is
            // getting a document without one; a model that does not know that
            // will describe a picture that is not on the page.
            if conversion.droppedDiagram {
                note += " The diagram in it would not draw, so the document was made without it —"
                    + " say so in passing, in one short clause."
            }
            return (destination, note)
        } catch {
            log("[notes] could not convert \(slug) to \(format.rawValue): \(error)")
            let reason = (error as? DocumentExporter.Failure)?.description
                ?? error.localizedDescription
            return (source, "Making \(format.spokenName) failed — \(reason) — so the note itself "
                + "is what the owner gets. Say so in one sentence.")
        }
    }

    // MARK: - read_note

    private func read(arguments: [String: JSONValue]) throws -> String {
        let title = (arguments["title"]?.stringValue ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else {
            return "No title was given, so no note was read."
        }

        let slug = NoteSlug.slug(from: title)
        let source = directory.appendingPathComponent(slug + ".md", isDirectory: false)
        guard let data = fileManager.contents(atPath: source.path),
              let text = String(data: data, encoding: .utf8) else {
            let known = (try? existingNoteURLs()) ?? []
            guard !known.isEmpty else {
                return "There is no note titled \"\(title)\", and no notes have been written yet."
            }
            let titles = known.prefix(Self.maximumListedNotes)
                .map { NoteSlug.readableTitle(fromFilename: $0.lastPathComponent) }
            return """
            There is no note titled "\(title)". The notes that do exist are: \
            \(titles.joined(separator: ", ")).
            """
        }
        return text
    }

    // MARK: - send_file

    /// Hands back something the owner already has.
    ///
    /// Everything that can go wrong here has the same failure mode if it is
    /// worded loosely: the model reads a sentence that does not clearly say
    /// *nothing left this machine* and tells the owner their file is on its way.
    /// That is the class the owner called *"quite dangerous"* — confident,
    /// complete and wrong — so every branch below says what did not happen
    /// first, and then what to do instead. A dead end with no door is how an
    /// appliance strands somebody.
    private func handBack(arguments: [String: JSONValue]) -> String {
        let asked = (arguments["title"]?.stringValue ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !asked.isEmpty else {
            return "No title was given, so nothing was sent. Call \(Self.listToolName) and ask the owner which one they mean."
        }

        let stored = StoredFiles(directory: directory, fileManager: fileManager)
        switch stored.match(title: asked) {
        case .nothing(let available):
            guard !available.isEmpty else {
                return "NOTHING WAS SENT. There is no file saved under \"\(asked)\", and nothing has been "
                    + "saved on this Mac yet. Tell the owner there is nothing to send, and that anything "
                    + "they send you in a linked chat is kept and can be asked for later."
            }
            return "NOTHING WAS SENT. There is no file saved under \"\(asked)\". What is saved: "
                + "\(available.joined(separator: ", ")). Ask the owner which of those they meant, or say "
                + "you cannot find it — do not tell them a file is on its way."

        case .several(let titles):
            // Deliberately not a best guess. See `StoredFiles.Resolution`.
            return "NOTHING WAS SENT. More than one saved file matches \"\(asked)\": "
                + "\(titles.joined(separator: ", ")). Ask the owner which one they want, then call "
                + "\(Self.sendToolName) again with that exact title."

        case .one(let match):
            return send(match, stored: stored)
        }
    }

    private func send(_ match: StoredFiles.Match, stored: StoredFiles) -> String {
        var sending: [URL] = []
        var refused: [String] = []

        for file in match.files {
            // Only where a size limit is real. In the window the file is a chip
            // the owner clicks, and a 200 MB video opens as happily as a 2 KB
            // note — refusing it there would be borrowing Signal's constraint
            // for a surface that does not have it.
            if delivery == .attachedToReply,
               let bytes = stored.sizeInBytes(of: file),
               bytes > Self.maximumAttachmentBytes {
                refused.append("\(file.lastPathComponent) is \(Self.megabytes(bytes)) and too big to attach")
                continue
            }
            sending.append(file)
        }

        guard !sending.isEmpty else {
            log("[notes] refused to send \(match.slug): \(refused.joined(separator: "; "))")
            return "NOTHING WAS SENT — \(refused.joined(separator: "; ")). Tell the owner plainly that the "
                + "file is too large to attach and is still saved on the Mac, so they can open it there."
        }

        for file in sending { deliver(file) }

        let names = sending.map(\.lastPathComponent).joined(separator: ", ")
        log("[notes] sending \(sending.count) file(s) for \"\(match.slug)\": \(names)")

        var sentences = [
            sending.count == 1
                ? "Sending \(names), saved as \"\(match.title)\"."
                : "Sending \(sending.count) files saved as \"\(match.title)\": \(names)."
        ]
        if !refused.isEmpty {
            sentences.append("Not sending \(refused.joined(separator: "; ")) — say so.")
        }
        sentences.append(delivery.handbackSentence)
        return sentences.joined(separator: " ")
    }

    /// Rounded, because "99.7 MB" and "100 MB" call for the same reaction and
    /// only one of them sounds like a machine reading a number aloud.
    static func megabytes(_ bytes: Int) -> String {
        "\(max(1, Int((Double(bytes) / (1024 * 1024)).rounded()))) MB"
    }

    // MARK: - list_notes

    private func list() throws -> String {
        let notes = try existingNoteURLs()
        guard !notes.isEmpty else {
            return "No notes have been written yet."
        }

        let named = notes.prefix(Self.maximumListedNotes)
            .map { NoteSlug.readableTitle(fromFilename: $0.lastPathComponent) }
        var answer = "\(notes.count) note(s): \(named.joined(separator: ", "))."
        if notes.count > named.count {
            answer += " \(notes.count - named.count) more not listed."
        }
        return answer
    }

    // MARK: - Directory

    /// Sorted so `list_notes` and the "did you mean" line in `read_note` do not
    /// reorder themselves between calls — a catalogue that shuffles is a prompt
    /// cache that misses, which is the bug that cost this appliance 17 seconds a
    /// turn until it was found.
    private func existingNoteURLs() throws -> [URL] {
        guard fileManager.fileExists(atPath: directory.path) else { return [] }
        let contents = try fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants]
        )
        return contents
            .filter { $0.pathExtension.lowercased() == "md" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }
}
