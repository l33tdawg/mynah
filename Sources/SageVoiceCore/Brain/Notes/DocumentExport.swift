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
    private let packages: URL?
    private let log: @Sendable (String) -> Void

    public init(
        pandoc: URL,
        pdfEngine: URL?,
        packages: URL? = nil,
        log: @escaping @Sendable (String) -> Void = { _ in }
    ) {
        self.pandoc = pandoc
        self.pdfEngine = pdfEngine
        self.packages = packages
        self.log = log
    }

    /// Whether a `dot` fence in a note will become a drawn graph.
    ///
    /// False is a usable state, not a broken one: the fence renders as a code
    /// block and everything else about the document is unchanged.
    public var drawsDiagrams: Bool { packages != nil }

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
            packages: findPackages(),
            log: log
        )
    }

    /// The vendored Typst packages, or `nil` on a Mac where they were never
    /// staged.
    ///
    /// Checked for the package itself rather than the directory: an empty
    /// `typst-packages` left behind by a half-finished provisioning run would
    /// otherwise make every PDF fail to compile, which is the one outcome the
    /// whole absent-rather-than-broken arrangement exists to avoid.
    static func findPackages() -> URL? {
        let manager = FileManager.default
        let inside = "\(DocumentTemplate.packageNamespace)/\(DocumentTemplate.packageName)"
            + "/\(DocumentTemplate.packageVersion)/typst.toml"

        func staged(_ root: URL) -> URL? {
            manager.fileExists(atPath: root.appendingPathComponent(inside).path)
                ? root.standardizedFileURL
                : nil
        }

        if let path = ProcessInfo.processInfo.environment["SAGE_VOICE_TYPST_PACKAGES"] {
            return staged(URL(fileURLWithPath: path))
        }
        // Inside Mynah.app, beside the Typst binary that will be asked to read it.
        let executable = URL(fileURLWithPath: CommandLine.arguments.first ?? "")
            .resolvingSymlinksInPath()
            .deletingLastPathComponent()
        if let found = staged(
            executable.appendingPathComponent("../Resources/typst/packages").standardizedFileURL
        ) { return found }
        // A development checkout, from anywhere inside it.
        var directory = URL(fileURLWithPath: manager.currentDirectoryPath)
        for _ in 0..<6 {
            if let found = staged(directory.appendingPathComponent("vendor/typst-packages")) {
                return found
            }
            directory = directory.deletingLastPathComponent()
        }
        return nil
    }

    /// The date a document says it was written, as a person would write it.
    ///
    /// The day it was made is a fact this appliance actually knows, unlike most
    /// of what a title block usually carries. No author line: see
    /// `DocumentTemplate`.
    public static func writtenDate(_ when: Date = Date(), calendar: Calendar = .current) -> String {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.locale = Locale(identifier: "en_GB")
        formatter.dateFormat = "d MMMM yyyy"
        return formatter.string(from: when)
    }

    static func find(_ tool: String, override: String) -> URL? {
        if let path = ProcessInfo.processInfo.environment[override] {
            let url = URL(fileURLWithPath: path)
            return runnableHere(url) ? url : nil
        }
        for root in searchRoots(tool) {
            let binary = root.appendingPathComponent("bin/\(tool)")
            if runnableHere(binary) { return binary }
        }
        return nil
    }

    /// Whether a file the search turned up is one *this* machine can actually
    /// start.
    ///
    /// **The x-bit is a fact about permissions, not about the file.**
    /// `isExecutableFile(atPath:)` reads that bit and stops, so a
    /// `vendor/pandoc/bin/pandoc` staged on a Mac — mode 0755, Mach-O — answers
    /// yes on a Linux box that cannot run a byte of it. `locate` then returns an
    /// exporter, `canProduce(.docx)` promises a Word document, and every `exec`
    /// fails with ENOEXEC: the binary never starts, so it writes nothing to
    /// stdout and nothing to stderr, and the owner is told *"Making a Word
    /// document failed — no reason given"*. A promise this appliance cannot keep
    /// is the exact outcome the absent-rather-than-broken arrangement exists to
    /// avoid, and a silent one is the worst shape it can take.
    ///
    /// So the first bytes are read as well, and they have to be the host
    /// kernel's own: Mach-O on Darwin — thin or universal, either byte order —
    /// and ELF everywhere else. A `#!` script passes on both, because wrapping
    /// the real tool in two lines of shell is an ordinary way to stage one.
    ///
    /// Nothing about a Mac changes. `posix_spawn` on Darwin accepts Mach-O and
    /// shebangs and refuses everything else, so every file that used to run
    /// still runs; what stops being found is the file that was never going to
    /// start. When nothing here is runnable the tool reads as *not staged*,
    /// which is a state the caller already handles by saying so plainly.
    static func runnableHere(_ url: URL) -> Bool {
        let manager = FileManager.default
        guard manager.isExecutableFile(atPath: url.path) else { return false }

        // Regular files only. A directory carries the x-bit as a matter of
        // course, and opening a FIFO for reading blocks until somebody writes to
        // it — a probe that hangs would be worse than the bug it is closing.
        // Symlinks are resolved first, because a staged tool is often a link to
        // the real one and the type of the link says nothing about the target.
        let resolved = url.resolvingSymlinksInPath()
        let type = (try? manager.attributesOfItem(atPath: resolved.path))?[.type]
        guard type as? FileAttributeType == .typeRegular else { return false }

        guard let handle = try? FileHandle(forReadingFrom: resolved) else { return false }
        defer { try? handle.close() }
        let magic = Array((try? handle.read(upToCount: 4)) ?? Data())

        // "#!", a wrapper script: both kernels run one.
        if magic.count >= 2, magic[0] == 0x23, magic[1] == 0x21 { return true }
        guard magic.count == 4 else { return false }
        #if canImport(Darwin)
        let word = magic.reduce(UInt32(0)) { $0 << 8 | UInt32($1) }
        // Mach-O thin (0xfeedface, 0xfeedfacf) and universal (0xcafebabe), plus
        // the byte-swapped spelling of each, which is how a binary built for the
        // other byte order looks from here.
        return [0xfeed_face, 0xfeed_facf, 0xcafe_babe,
                0xcefa_edfe, 0xcffa_edfe, 0xbeba_feca].contains(word)
        #else
        return magic == [0x7f, 0x45, 0x4c, 0x46]  // "\u{7f}ELF"
        #endif
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

    /// What a conversion had to give up to succeed.
    public struct Conversion: Equatable, Sendable {
        /// A diagram in the note would not draw, so the document was made
        /// without it. Never silent: the caller says so, and the model tells the
        /// owner.
        public let droppedDiagram: Bool

        public static let clean = Conversion(droppedDiagram: false)
    }

    /// Converts a markdown file that is already on disk.
    ///
    /// - Parameter source: the note as written. It stays exactly as it is — the
    ///   markdown is the thing `read_note` reads back and the thing the owner
    ///   can still open when Pandoc is not around.
    @discardableResult
    public func convert(
        source: URL,
        to format: DocumentFormat,
        at destination: URL,
        title: String,
        date: String? = nil
    ) async throws -> Conversion {
        let markdown = (try? String(contentsOf: source, encoding: .utf8)) ?? ""
        do {
            try await attempt(markdown, to: format, at: destination, title: title, date: date)
            return .clean
        } catch {
            // **A broken diagram must not cost the owner the document.**
            //
            // Graphviz is a language and the model writing it is a 4B: the first
            // diagram it produced here used `edge` as a node name and an
            // unquoted `#FF6347`, and either one stops Typst dead. Without this
            // the whole conversion failed and a syntax error in a decoration
            // turned a report into "here is the note instead".
            //
            // Only worth trying when there is a diagram to drop, and only once.
            guard format == .pdf, packages != nil, DocumentTemplate.hasDiagram(markdown) else {
                throw error
            }
            log("[notes] a diagram would not draw (\(error)); making the document without it")
            try await attempt(
                DocumentTemplate.withoutDiagrams(markdown),
                to: format,
                at: destination,
                title: title,
                date: date
            )
            return Conversion(droppedDiagram: true)
        }
    }

    private func attempt(
        _ markdown: String,
        to format: DocumentFormat,
        at destination: URL,
        title: String,
        date: String?
    ) async throws {
        guard format != .markdown else { return }

        // The note as written stays on disk untouched; what Pandoc reads is a
        // copy with the duplicated heading taken off. Doing it the other way —
        // editing the note — would mean `read_note` handing back a document
        // whose first line depends on whether anybody ever asked for a PDF.
        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("mynah-doc-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }

        let prepared = DocumentTemplate.prepared(markdown, title: title)
        let trimmed = scratch.appendingPathComponent("source.md")
        try Data(prepared.markdown.utf8).write(to: trimmed, options: [.atomic])

        var arguments = [
            // **`autolink_bare_uris`, or a Sources list is dead text.**
            //
            // Pandoc turns `[name](url)` into a link on its own, and the
            // template has styled links blue since the day it was written — but
            // a model writing a references section writes the address by itself,
            // on its own line, because that is what a citation looks like. With
            // the plain `markdown` reader those are characters, so the owner got
            // a page of blue-less URLs he had to retype: *"can we make the URLs
            // in the pdf clickable?"*
            //
            // The extension is on the reader rather than a fix-up on the text,
            // because Pandoc already knows where a URI ends and a sentence
            // resumes, and a regular expression written here would not.
            "--from=markdown+autolink_bare_uris",
            "--output=\(destination.path)",
            // Without this the document has no title inside it — DOCX and PPTX
            // both carry one in their metadata, and a deck whose properties say
            // "untitled" is the sort of detail that makes a generated file look
            // generated.
            "--metadata=title:\(title)",
            "--standalone"
        ]
        if let subtitle = prepared.subtitle {
            arguments.append("--metadata=subtitle:\(subtitle)")
        }
        if let date { arguments.append("--metadata=date:\(date)") }
        if format == .pdf {
            guard let pdfEngine else { throw Failure.pdfEngineMissing }
            arguments.append("--pdf-engine=\(pdfEngine.path)")

            let template = scratch.appendingPathComponent("mynah.typst")
            try Data(DocumentTemplate.typst(withDiagrams: packages != nil).utf8)
                .write(to: template, options: [.atomic])
            arguments.append("--template=\(template.path)")

            // Typst is the process that resolves the import, and Pandoc is what
            // launches it, so the only way through is Pandoc's passthrough.
            if let packages {
                arguments.append("--pdf-engine-opt=--package-path=\(packages.path)")
            }
        }
        if format == .pptx {
            // Pandoc makes one slide per top-level heading. Without this a note
            // written as prose becomes a single slide with everything on it,
            // which is not a deck.
            arguments.append("--slide-level=2")
        }
        arguments.append(trimmed.path)

        try await run(arguments: arguments, workingDirectory: scratch)

        guard FileManager.default.fileExists(atPath: destination.path) else {
            throw Failure.producedNothing
        }
        try OwnerOnlyFileSecurity.protectFile(destination)
        log("[notes] converted a note to \(destination.lastPathComponent)")
    }

    private func run(arguments: [String], workingDirectory: URL) async throws {
        let process = Process()
        process.executableURL = pandoc
        process.arguments = arguments
        // **Somewhere writable to work in, named rather than inherited.**
        //
        // A process started by this app inherits the app's working directory,
        // and for an app launched from the Finder that is `/`. Pandoc's PDF
        // route puts intermediate files somewhere before handing them to the
        // engine, and somewhere it cannot write is a conversion that fails on a
        // temporary file.
        //
        // Which is what the owner saw, and the evidence narrows to exactly this
        // difference: every PDF the appliance has ever made successfully was
        // made by the *daemon*, a launchd job with its own environment. The same
        // note, the same staged pandoc and typst, and the same vendored packages
        // convert on the first attempt outside the app.
        //
        // `scratch` is made by the caller, owned by us, and deleted with the
        // rest of the run — so this costs nothing and removes a whole class of
        // failure that depends on where the app happened to be started from.
        process.currentDirectoryURL = workingDirectory

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
            // **All of it to the log, one line of it to the owner.**
            //
            // Only the last line used to survive this method, and it is chosen
            // to be the readable half — Pandoc puts the path on one line and the
            // reason on the next. That is right for a sentence somebody reads on
            // their phone and wrong for the only record of what went wrong: a
            // failure reported as "a temporary-file error" could not be traced
            // afterwards, because the four lines above the one kept were the
            // ones naming the file and the operation.
            //
            // Cheap, and only on the failing path — a conversion that works logs
            // one line as it always did.
            log("[document] \(pandoc.lastPathComponent) exited \(process.terminationStatus)"
                + (output.isEmpty ? " with no output" : ":\n\(output)"))
            // The last line with anything in it. Pandoc puts the path and the
            // reason on separate lines and the reason is the half worth
            // repeating to somebody.
            //
            // **Silence is not a reason and is not reported as one.** A
            // converter that exits without writing a word leaves nothing to pass
            // on, and "no reason given" is a dead end with no door in it: it
            // names no cause and no next thing to try. The exit code and the
            // binary that produced it are the two facts there are, so they go in
            // the sentence along with the one command that restages a converter
            // that cannot run here.
            let reason = output
                .split(separator: "\n")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .last { !$0.isEmpty }
                ?? "\(pandoc.lastPathComponent) exited \(process.terminationStatus) without "
                    + "saying why — restage it with scripts/provision-pandoc.sh"
            throw Failure.conversionFailed(reason)
        }
    }
}
