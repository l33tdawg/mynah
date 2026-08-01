import Foundation

// MARK: - What the owner asked for

/// The shapes a saved document can take.
///
/// Deliberately four. Every format here is one somebody names out loud — "make
/// me a PDF", "send it as a Word doc", "put together a deck" — and none is here
/// because Pandoc happens to support it. Pandoc writes about forty formats; a
/// list of forty in a tool schema is a routing problem, not a feature.
public enum DocumentFormat: String, Sendable, CaseIterable, Equatable {
    case markdown
    case pdf
    case docx
    case pptx

    public var fileExtension: String {
        switch self {
        case .markdown: return "md"
        case .pdf: return "pdf"
        case .docx: return "docx"
        case .pptx: return "pptx"
        }
    }

    /// What to call it in a sentence the owner hears.
    public var spokenName: String {
        switch self {
        case .markdown: return "a note"
        case .pdf: return "a PDF"
        case .docx: return "a Word document"
        case .pptx: return "a slide deck"
        }
    }

    /// Reads a format out of whatever the model wrote.
    ///
    /// Tolerant on purpose. The schema names four values and a 4B model will
    /// still write "word", "powerpoint" or "slides" — those are the owner's own
    /// words coming through, and refusing them would mean writing a markdown
    /// file for somebody who asked for a deck and never saying why.
    ///
    /// Anything genuinely unrecognised returns `nil` rather than guessing at
    /// `pdf`: a wrong format is a file the owner cannot open, and the caller can
    /// say what it did not understand.
    public static func named(_ raw: String) -> DocumentFormat? {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        switch text {
        case "", "md", "markdown", "text", "txt", "note":
            return .markdown
        case "pdf":
            return .pdf
        case "docx", "doc", "word", "msword":
            return .docx
        case "pptx", "ppt", "powerpoint", "slides", "deck", "presentation", "keynote":
            return .pptx
        default:
            return nil
        }
    }
}

// MARK: - Turning a note into one

/// Converts a markdown note into a real document, by asking Pandoc.
///
/// **Nothing here writes a file format.** DOCX, PPTX and ODT are each a zip of
/// XML with twenty years of quirks in them, and a hand-rolled writer produces
/// files that open with a repair dialog — which is worse than not offering the
/// feature at all. Pandoc has been doing this since 2006 and is the tool every
/// other product in this space shells out to.
///
/// PDFs go through Typst rather than LaTeX. Pandoc's default engine is
/// pdflatex, and a usable TeX distribution is between 400 MB and 5 GB for one
/// output format; Typst is a single binary, Pandoc has supported it as a
/// `--pdf-engine` since 3.1.11, and nobody can tell the output apart.
///
/// Absent rather than broken when the binaries were never staged: `locate`
/// returns `nil`, `write_note` still writes the markdown, and the owner is told
/// plainly that this Mynah has no converter rather than being handed a `.pdf`
/// that is secretly text.
public struct DocumentExporter: Sendable {

    public enum Failure: Error, CustomStringConvertible, Equatable {
        case pdfEngineMissing
        case conversionFailed(String)
        case tookTooLong
        case producedNothing

        public var description: String {
            switch self {
            case .pdfEngineMissing:
                return "this Mynah has no PDF engine staged, so it could not make a PDF"
            case .conversionFailed(let reason):
                return "the document could not be converted: \(reason)"
            case .tookTooLong:
                return "the document took too long to convert and was abandoned"
            case .producedNothing:
                return "the converter finished but wrote no file"
            }
        }
    }

    /// Long enough for a fifty-page document on a busy appliance, short enough
    /// that a wedged converter does not hold a turn open until the owner gives
    /// up and asks again.
    static let timeout: TimeInterval = 45

    private let pandoc: URL
    private let pdfEngine: URL?
    private let log: @Sendable (String) -> Void

    public init(pandoc: URL, pdfEngine: URL?, log: @escaping @Sendable (String) -> Void = { _ in }) {
        self.pandoc = pandoc
        self.pdfEngine = pdfEngine
        self.log = log
    }

    /// The converter this Mac has, or `nil`.
    ///
    /// Same search as `EspeakPhonemizer`, and for the same reasons: an
    /// environment override first so a build machine can point at something
    /// else, then inside the app bundle where `package-app.sh` stages it, then
    /// a development checkout walked upwards so tests and `swift run` work from
    /// any directory in the tree.
    public static func locate(
        log: @escaping @Sendable (String) -> Void = { _ in }
    ) -> DocumentExporter? {
        guard let pandoc = find("pandoc", override: "SAGE_VOICE_PANDOC") else { return nil }
        return DocumentExporter(
            pandoc: pandoc,
            pdfEngine: find("typst", override: "SAGE_VOICE_TYPST"),
            log: log
        )
    }

    static func find(_ tool: String, override: String) -> URL? {
        let manager = FileManager.default
        if let path = ProcessInfo.processInfo.environment[override] {
            let url = URL(fileURLWithPath: path)
            return manager.isExecutableFile(atPath: url.path) ? url : nil
        }
        for root in searchRoots(tool) {
            let binary = root.appendingPathComponent("bin/\(tool)")
            if manager.isExecutableFile(atPath: binary.path) { return binary }
        }
        return nil
    }

    static func searchRoots(_ tool: String) -> [URL] {
        var roots: [URL] = []
        // Inside Mynah.app, beside the executable that is asking.
        let executable = URL(fileURLWithPath: CommandLine.arguments.first ?? "")
            .resolvingSymlinksInPath()
            .deletingLastPathComponent()
        roots.append(executable.appendingPathComponent("../Resources/\(tool)").standardizedFileURL)
        // A development checkout, from anywhere inside it.
        var directory = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        for _ in 0..<6 {
            roots.append(directory.appendingPathComponent("vendor/\(tool)"))
            directory = directory.deletingLastPathComponent()
        }
        return roots
    }

    /// Whether a format can actually be produced on this Mac.
    ///
    /// Asked before the model is told the format exists, so "make me a PDF"
    /// cannot be answered with a promise this Mynah cannot keep.
    public func canProduce(_ format: DocumentFormat) -> Bool {
        switch format {
        case .markdown: return true
        case .pdf: return pdfEngine != nil
        case .docx, .pptx: return true
        }
    }

    /// Converts a markdown file that is already on disk.
    ///
    /// - Parameter source: the note as written. It stays exactly as it is — the
    ///   markdown is the thing `read_note` reads back and the thing the owner
    ///   can still open when Pandoc is not around.
    public func convert(
        source: URL,
        to format: DocumentFormat,
        at destination: URL,
        title: String
    ) async throws {
        guard format != .markdown else { return }

        var arguments = [
            "--from=markdown",
            "--output=\(destination.path)",
            // Without this the document has no title inside it — DOCX and PPTX
            // both carry one in their metadata, and a deck whose properties say
            // "untitled" is the sort of detail that makes a generated file look
            // generated.
            "--metadata=title:\(title)",
            "--standalone"
        ]
        if format == .pdf {
            guard let pdfEngine else { throw Failure.pdfEngineMissing }
            arguments.append("--pdf-engine=\(pdfEngine.path)")
        }
        if format == .pptx {
            // Pandoc makes one slide per top-level heading. Without this a note
            // written as prose becomes a single slide with everything on it,
            // which is not a deck.
            arguments.append("--slide-level=2")
        }
        arguments.append(source.path)

        try await run(arguments: arguments)

        guard FileManager.default.fileExists(atPath: destination.path) else {
            throw Failure.producedNothing
        }
        try OwnerOnlyFileSecurity.protectFile(destination)
        log("[notes] converted \(source.lastPathComponent) to \(destination.lastPathComponent)")
    }

    private func run(arguments: [String]) async throws {
        let process = Process()
        process.executableURL = pandoc
        process.arguments = arguments

        // A file rather than a `Pipe`, because nothing drains a pipe while this
        // waits and a converter that fills the buffer would block forever
        // holding a turn open. Pandoc says little, but "little" is not a
        // guarantee — a document with a hundred broken image links is not.
        let errorFile = FileManager.default.temporaryDirectory
            .appendingPathComponent("pandoc-\(UUID().uuidString).log")
        FileManager.default.createFile(atPath: errorFile.path, contents: nil)
        defer { try? FileManager.default.removeItem(at: errorFile) }
        if let handle = try? FileHandle(forWritingTo: errorFile) {
            process.standardError = handle
            process.standardOutput = handle
        }

        do {
            try process.run()
        } catch {
            throw Failure.conversionFailed(error.localizedDescription)
        }

        let deadline = Date().addingTimeInterval(Self.timeout)
        while process.isRunning, Date() < deadline {
            try? await Task.sleep(for: .milliseconds(50))
        }
        if process.isRunning {
            process.terminate()
            throw Failure.tookTooLong
        }

        guard process.terminationStatus == 0 else {
            let output = (try? String(contentsOf: errorFile, encoding: .utf8)) ?? ""
            // The last line with anything in it. Pandoc puts the path and the
            // reason on separate lines and the reason is the half worth
            // repeating to somebody.
            let reason = output
                .split(separator: "\n")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .last { !$0.isEmpty } ?? "no reason given"
            throw Failure.conversionFailed(reason)
        }
    }
}
