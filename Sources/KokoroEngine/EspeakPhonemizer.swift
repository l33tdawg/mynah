import Foundation

/// Turns written text into the phonemes Kokoro was trained on, by driving the
/// bundled espeak-ng as a subprocess.
///
/// ## Why a subprocess and not a library
///
/// espeak-ng is GPLv3. Linking it would put Mynah under GPLv3; running it as a
/// separate executable and reading its stdout does not. This is the same
/// boundary signal-cli already sits behind, and `provision-espeak-ng.sh`
/// deliberately builds a static binary so there is no dylib for anything of ours
/// to link even by accident.
///
/// ## Why not write the G2P in Swift
///
/// Because it is not a phoneme table. `"Cost: $5.50"` has to become
/// `kˈɔst: dˈɑːlɚ fˈaɪv.fˈɪfti` — *"dollar five fifty"* — and the currency,
/// number, date and abbreviation expansion that produces that happens inside
/// espeak, ahead of any letter-to-sound rule. A hand-rolled table would get
/// `hello` right and every real sentence wrong.
///
/// ## What this file actually reimplements
///
/// espeak's CLI **discards punctuation**, and Kokoro needs it: the comma in
/// `"hello world, the quick brown fox."` is what makes the model pause there.
/// Python reached the same binary through `phonemizer`, whose
/// `preserve_punctuation=True` hides the punctuation from espeak and puts it
/// back afterwards. That hiding and restoring is the algorithm below — ported
/// deliberately rather than approximated, because the pauses in the owner's
/// voice depend on it.
///
/// Verified against 78 captured cases in `Tests/Fixtures/espeak-phonemes.json`,
/// produced by the exact Python call this replaces.
public struct EspeakPhonemizer: Sendable {

    public enum Failure: Error, Equatable {
        case binaryNotFound(String)
        case dataNotFound(String)
        case launchFailed(String)
        /// espeak exited non-zero. Payload is its status and whatever it wrote
        /// to stderr.
        case espeakFailed(Int32, String)
        /// The punctuation pattern did not compile. A programming error rather
        /// than anything the owner did — but it is raised rather than ignored,
        /// because the alternative is speech that quietly loses every pause.
        case punctuationPatternInvalid
    }

    /// The espeak voice `phonemizer` resolves `en-us` to. Captured from the
    /// running Python rather than assumed: `en-us` is an alias, and the
    /// identifier it lands on is `gmw/en-US`.
    public static let voice = "gmw/en-US"

    /// Bare `--ipa`, and the number matters.
    ///
    /// `--ipa=1` separates every phoneme with `_`, `--ipa=2` ties diphthongs
    /// with U+0361, `--ipa=3` ties them with U+200D. Only bare `--ipa` produces
    /// `həlˈoʊ` — the form the captured reference contains. The tied forms
    /// survive tokenization only because the tie is not in Kokoro's vocabulary
    /// and gets filtered out, which is luck rather than a contract.
    static let ipaArguments = ["-q", "--ipa"]

    /// Exactly `phonemizer.punctuation._DEFAULT_MARKS`.
    ///
    /// Order is irrelevant — it becomes a character class — but membership is
    /// not: a mark missing here is a mark espeak silently eats, which is a pause
    /// the owner does not hear.
    static let marks = ";:,.!?¡¿—…\"«»“”(){}[]"

    private let binary: URL
    private let dataPath: URL

    // MARK: - Locating the binary

    public init(binary: URL, dataPath: URL) throws {
        guard FileManager.default.isExecutableFile(atPath: binary.path) else {
            throw Failure.binaryNotFound(binary.path)
        }
        // espeak reports a cheerful "Failed to read data" and produces nothing
        // when the data directory is wrong, so check it here where the message
        // can name the path.
        guard FileManager.default.fileExists(atPath: dataPath.appendingPathComponent("phontab").path) else {
            throw Failure.dataNotFound(dataPath.path)
        }
        self.binary = binary
        self.dataPath = dataPath
    }

    /// Finds the staged espeak, in the bundle first and the checkout second.
    ///
    /// The bundle case is the shipped one; the `vendor/` case is what makes
    /// `swift test` work on a development machine without a build of the app.
    public init() throws {
        for root in Self.searchRoots() {
            let binary = root.appendingPathComponent("bin/espeak-ng")
            let data = root.appendingPathComponent("share/espeak-ng-data")
            if FileManager.default.isExecutableFile(atPath: binary.path) {
                try self.init(binary: binary, dataPath: data)
                return
            }
        }
        throw Failure.binaryNotFound(
            Self.searchRoots().map(\.path).joined(separator: ", ")
        )
    }

    static func searchRoots() -> [URL] {
        var roots: [URL] = []
        if let override = ProcessInfo.processInfo.environment["SAGE_VOICE_ESPEAK_ROOT"] {
            roots.append(URL(fileURLWithPath: override))
        }
        // Inside Mynah.app. `package-app.sh` stages it here.
        let executable = URL(fileURLWithPath: CommandLine.arguments.first ?? "")
            .resolvingSymlinksInPath()
            .deletingLastPathComponent()
        roots.append(executable.appendingPathComponent("../Resources/espeak-ng").standardizedFileURL)
        // A development checkout, from anywhere inside it.
        var directory = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        for _ in 0..<6 {
            roots.append(directory.appendingPathComponent("vendor/espeak-ng"))
            directory = directory.deletingLastPathComponent()
        }
        return roots
    }

    // MARK: - Phonemizing

    /// Phonemes for `text`, punctuation included.
    ///
    /// Returns the string before Kokoro's vocabulary filter — `KokoroTokenizer`
    /// applies that, and applying it here would hide a phoneme espeak emitted
    /// that we do not yet handle.
    public func phonemes(for text: String) throws -> String {
        // Refuse rather than quietly hand back unpunctuated speech.
        guard Self.markExpression != nil else { throw Failure.punctuationPatternInvalid }

        let (chunks, marks) = Self.preserve(text)
        guard !chunks.isEmpty else {
            // Punctuation only. Nothing to phonemize, and the marks are the
            // whole answer.
            return Self.restore(chunks: [], marks: marks).trimmingCharacters(in: .whitespaces)
        }
        let spoken = try chunks.map { try Self.postprocess(run(chunk: $0)) }
        return Self.restore(chunks: spoken, marks: marks)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// One espeak invocation.
    ///
    /// Per chunk rather than per sentence, because espeak inserts its own
    /// newlines on long input and there is then no reliable mapping from output
    /// line back to input chunk. A spawn is about four milliseconds against
    /// roughly three hundred for the model, so the tidier contract is worth more
    /// than the saved process.
    ///
    /// **The text goes in over stdin, and it has to.** Passing it as an argument
    /// looks obvious and is wrong: `Process` converts arguments through the
    /// file-system representation, which on Darwin means NFD. Swift holds `café`
    /// as `63 61 66 c3 a9`; the child receives `63 61 66 65 cc 81`, and calling
    /// `precomposedStringWithCanonicalMapping` first does not help because the
    /// conversion happens after. espeak reads the decomposed form as a word
    /// followed by a stray combining accent and says `kˈeɪf` — so `café`,
    /// `Beyoncé` and every other accented word in the owner's text would be
    /// mispronounced, while ASCII stayed perfect and hid it.
    private func run(chunk: String) throws -> String {
        let process = Process()
        process.executableURL = binary
        process.arguments = Self.ipaArguments + ["--stdin", "-v", Self.voice]
        // The compiled-in data path points at whichever machine ran the
        // provisioning script, so it has to be supplied at every launch.
        var environment = ProcessInfo.processInfo.environment
        environment["ESPEAK_DATA_PATH"] = dataPath.path
        process.environment = environment

        let input = Pipe()
        let output = Pipe()
        let errors = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = errors

        do {
            try process.run()
        } catch {
            throw Failure.launchFailed(String(describing: error))
        }

        // **The trailing newline is load-bearing.** Without it espeak drops the
        // last character of the input — `fox` becomes `fˈoʊ` and `café` comes out
        // as "cafe tilde" — so the terminator is what makes stdin equivalent to
        // an argument rather than a subtly truncating version of it.
        input.fileHandleForWriting.write(Data((chunk + "\n").utf8))
        try? input.fileHandleForWriting.close()
        // Read before waiting. A chunk whose phonemes exceed the pipe buffer
        // would otherwise deadlock — espeak blocked on write, us blocked on
        // exit — and it would only happen on long input.
        let stdoutData = output.fileHandleForReading.readDataToEndOfFile()
        let stderrData = errors.fileHandleForReading.readDataToEndOfFile()
        process.waitForExitWithoutBlockingTheRunLoop()

        guard process.terminationStatus == 0 else {
            throw Failure.espeakFailed(
                process.terminationStatus,
                String(decoding: stderrData, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            )
        }
        return String(decoding: stdoutData, as: UTF8.self)
    }

    // MARK: - Hiding punctuation from espeak

    /// Where a mark sat in the original text, which decides how it goes back.
    enum Position: Equatable {
        case beginning
        case end
        case middle
        /// The line was nothing but punctuation.
        case alone
    }

    struct Mark: Equatable {
        let text: String
        let position: Position
    }

    /// Splits `line` into the parts espeak should see and the marks it must not.
    ///
    /// `"hello, my world!"` becomes `["hello", "my world"]` and `[",", "!"]`.
    /// A mark carries its own surrounding whitespace, which is why the comma
    /// above is `", "` and not `","` — that space is a word separator on the way
    /// back and losing it runs two words together.
    static func preserve(_ line: String) -> (chunks: [String], marks: [Mark]) {
        guard let expression = markExpression else { return ([line], []) }

        let range = NSRange(line.startIndex..<line.endIndex, in: line)
        let matches = expression.matches(in: line, options: [], range: range)
        guard !matches.isEmpty else { return ([line], []) }

        let matchedTexts: [String] = matches.compactMap {
            Range($0.range, in: line).map { range in String(line[range]) }
        }

        // Nothing but punctuation.
        if matchedTexts.count == 1, matchedTexts[0] == line {
            return ([], [Mark(text: line, position: .alone)])
        }

        var marks: [Mark] = []
        for (index, text) in matchedTexts.enumerated() {
            let position: Position
            if index == 0, line.hasPrefix(text) {
                position = .beginning
            } else if index == matchedTexts.count - 1, line.hasSuffix(text) {
                position = .end
            } else {
                position = .middle
            }
            marks.append(Mark(text: text, position: position))
        }

        // Split at the first occurrence of each mark in turn, exactly as
        // `line.split(mark)[0]` / `mark.join(rest)` does.
        var remaining = line
        var chunks: [String] = []
        for mark in marks {
            guard let found = remaining.range(of: mark.text) else {
                chunks.append(remaining)
                remaining = ""
                continue
            }
            chunks.append(String(remaining[remaining.startIndex..<found.lowerBound]))
            remaining = String(remaining[found.upperBound...])
        }
        chunks.append(remaining)

        return (chunks.filter { !$0.isEmpty }, marks)
    }

    /// `(\s*[marks]+\s*)+` — any run of marks, plus the whitespace hugging it.
    ///
    /// **`[` must be escaped, and forgetting it does not fail loudly.** ICU
    /// supports nested sets, so a bare `[` inside a character class opens one;
    /// the pattern then does not compile, and a `try?` here turned that into
    /// every punctuation mark being silently ignored. The corpus test caught it,
    /// but the symptom was a voice that had simply stopped pausing — which is
    /// exactly the kind of defect that ships. `&` is escaped for the same
    /// reason: ICU reads `&&` as set intersection, and this string is one edit
    /// away from containing an ampersand.
    static let markExpression: NSRegularExpression? = {
        var characterClass = ""
        for character in marks {
            if "[]\\^-&".contains(character) {
                characterClass.append("\\")
            }
            characterClass.append(character)
        }
        return try? NSRegularExpression(pattern: "(\\s*[\(characterClass)]+\\s*)+")
    }()

    // MARK: - Normalising what espeak said

    /// Cleans one chunk of espeak output.
    ///
    /// espeak breaks long utterances across lines and, on some inputs, doubles
    /// its own phoneme separators — the same two quirks `phonemizer` works
    /// around. The trailing space is not an accident: it is the word separator,
    /// and `restore` relies on being able to take it off again.
    static func postprocess(_ raw: String) throws -> String {
        var line = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "  ", with: " ")

        // espeak-ng#694: extra separators can appear at the end of a word.
        while line.contains("__") {
            line = line.replacingOccurrences(of: "__", with: "_")
        }
        line = line.replacingOccurrences(of: "_ ", with: " ")

        guard !line.isEmpty else { return "" }

        // Every word loses its separators and gains a trailing space. With no
        // tie and an empty phone separator this is what Python's loop reduces
        // to — including the final space, which it keeps because `strip` is
        // false.
        return line.split(separator: " ", omittingEmptySubsequences: false)
            .map { $0.replacingOccurrences(of: "_", with: "") + " " }
            .joined()
    }

    // MARK: - Putting punctuation back

    /// The reverse of `preserve`.
    ///
    /// A direct port of `Punctuation.restore` for the one configuration this
    /// package uses: a single line, a space word separator, and `strip` false.
    /// The generality Python carries for multi-line input is deliberately not
    /// reproduced — `SpeechTextSegmenter` has already reduced the reply to one
    /// segment before anything reaches here.
    static func restore(chunks: [String], marks: [Mark]) -> String {
        var text = chunks
        var marks = marks
        var output: [String] = []
        // Every mark from a single line shares index 0, so the first mark is
        // placed against the first chunk and `placed` only ever advances past
        // it. Keeping the counter makes the port readable against the original.
        var placed = 0
        let separator = " "

        while !text.isEmpty || !marks.isEmpty {
            if marks.isEmpty {
                for line in text {
                    output.append(line.hasSuffix(separator) ? line : line + separator)
                }
                text = []
                continue
            }
            if text.isEmpty {
                output.append(marks.map(\.text).joined())
                marks = []
                continue
            }

            guard placed == 0 else {
                output.append(text.removeFirst())
                placed += 1
                continue
            }

            let mark = marks.removeFirst()
            if text[0].hasSuffix(separator) {
                text[0] = String(text[0].dropLast(separator.count))
            }

            switch mark.position {
                case .beginning:
                    text[0] = mark.text + text[0]
                case .end:
                    let tail = mark.text.hasSuffix(separator) ? "" : separator
                    output.append(text.removeFirst() + mark.text + tail)
                    placed += 1
                case .alone:
                    let tail = mark.text.hasSuffix(separator) ? "" : separator
                    output.append(mark.text + tail)
                    placed += 1
                case .middle:
                    if text.count == 1 {
                        text[0] += mark.text
                    } else {
                        let first = text.removeFirst()
                        text[0] = first + mark.text + text[0]
                    }
            }
        }
        return output.joined()
    }
}
