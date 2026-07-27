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

    /// For `CompositeToolSource.Source.expectedToolNames` and the prompt allowlist.
    public static let toolNames: Set<String> = [writeToolName, readToolName, listToolName]

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
    }

    private let directory: URL
    private let delivery: Delivery
    private let fileManager: FileManager
    private let log: @Sendable (String) -> Void

    private let lock = NSLock()
    /// Notes written since the last drain, so the daemon can attach them to the
    /// reply that mentions them.
    private var written: [URL] = []

    /// - Parameter delivery: defaults to the honest-anywhere answer. A host that
    ///   actually ships the file has to say so explicitly.
    public init(
        directory: URL = NotesToolSource.defaultDirectory(),
        delivery: Delivery = .savedOnDisk,
        fileManager: FileManager = .default,
        log: @escaping @Sendable (String) -> Void = { _ in }
    ) {
        self.directory = directory
        self.delivery = delivery
        self.fileManager = fileManager
        self.log = log
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

    // MARK: - Written-note handoff

    /// The notes written since this was last called, and clears the list.
    ///
    /// Draining rather than reading is deliberate: the daemon attaches these to
    /// one reply, and a note that rode along with a second reply because nobody
    /// cleared the list would be a confusing bug to chase from the phone.
    public func drainWrittenNotes() -> [URL] {
        lock.lock()
        defer { lock.unlock() }
        let drained = written
        written = []
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
                Save a markdown document and send it to the owner as a file. Use this when they \
                ask for notes, a written summary, a document or a list they want to keep. Not \
                for ordinary answers, which you just speak.
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
                            "description": .string("The document itself. Markdown is fine here.")
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
            )
        ]
    }

    public func call(name: String, arguments: [String: JSONValue]) async throws -> String {
        switch name {
        case Self.writeToolName:
            return try write(arguments: arguments)
        case Self.readToolName:
            return try read(arguments: arguments)
        case Self.listToolName:
            return try list()
        default:
            throw CompositeToolSource.Failure.unknownTool(name)
        }
    }

    // MARK: - write_note

    private func write(arguments: [String: JSONValue]) throws -> String {
        let content = arguments["content"]?.stringValue ?? ""
        guard !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return "No content was given, so no note was written."
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

        lock.lock()
        written.append(destination)
        lock.unlock()

        log("[notes] wrote \(filename) (\(document.count) characters)\(isReplacement ? ", replacing an earlier note" : "")")

        var sentences = [
            isReplacement
                ? "Replaced the earlier note titled \"\(title)\". The new file is \(filename)."
                : "Wrote \"\(title)\" as \(filename)."
        ]
        if body.count < content.count {
            sentences.append("It was too long and was cut at \(Self.maximumContentCharacters) characters — tell the owner that.")
        }
        // Says what already happened to the file, so the model does not go on to
        // offer a delivery it cannot perform. Which host is speaking matters:
        // see `Delivery`.
        sentences.append(delivery.sentence)
        return sentences.joined(separator: " ")
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
