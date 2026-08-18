import Foundation

/// What speech recognition this machine can actually do — and, when it cannot,
/// which half is missing and what to do about it.
///
/// ## Why a type rather than an optional
///
/// `commandBackend()` returns `nil` for two entirely different situations: no
/// whisper.cpp program anywhere, or a program with no model beside it. On macOS
/// conflating them was defensible, because both are packaging mistakes in a
/// bundle the release script assembles and the owner can do nothing about
/// either except reinstall.
///
/// **Off Darwin neither is a packaging mistake.** Linux users install
/// whisper.cpp themselves — Mynah bundles nothing and downloads nothing there —
/// so "not bundled" is not a diagnosis, it is a shrug, and the owner is left
/// with a voice note that produced nothing and no idea which half is absent.
/// Voice-notes-to-text is the one speech feature the port has to keep, so the
/// failure to find it has to say where it looked and name the next action.
public enum LocalASRAvailability: Equatable, Sendable {
    /// Both halves are present; `commandBackend()` will hand back a backend.
    case ready(executable: URL, model: URL)
    /// No whisper.cpp command-line program in any of the places searched.
    case noExecutable(searched: [String])
    /// A program, but no weights for it to run.
    case noModel(executable: URL, searched: [String])

    public var isReady: Bool {
        if case .ready = self { return true }
        return false
    }

    /// The sentence the owner sees. It ends in something to do, because a
    /// failure that names no next action leaves them exactly where they were.
    public var explanation: String {
        switch self {
        case let .ready(executable, model):
            return "Speech recognition is ready: \(executable.path) with \(model.lastPathComponent)."

        case let .noExecutable(searched):
            #if os(macOS)
            return "The whisper.cpp helper is not in this build, so voice notes cannot be "
                + "transcribed by the fallback engine. It is a release asset staged by "
                + "scripts/provision-asr-assets.sh before the app is signed — reinstall Mynah "
                + "from a release build. Looked in: \(Self.list(searched))."
            #elseif os(Windows)
            return "No whisper.cpp program was found, so voice notes cannot be turned into "
                + "text. Install whisper.cpp — the program is whisper-cli.exe — and add the "
                + "folder holding it to Path under System Properties → Environment "
                + "Variables, or set SAGE_VOICE_WHISPER_CLI to the .exe itself. "
                + "Looked in: \(Self.list(searched))."
            #else
            return "No whisper.cpp program was found, so voice notes cannot be turned into "
                + "text. Install whisper.cpp — its program is called whisper-cli, or "
                + "whisper-cpp on Debian and Fedora — and put it on $PATH, or point "
                + "SAGE_VOICE_WHISPER_CLI at it. Looked in: \(Self.list(searched))."
            #endif

        case let .noModel(executable, searched):
            #if os(macOS)
            return "Found the whisper.cpp helper at \(executable.path) but no model for it to "
                + "run, so voice notes cannot be transcribed by the fallback engine. The model "
                + "is a release asset staged by scripts/provision-asr-assets.sh — reinstall "
                + "Mynah from a release build. Looked in: \(Self.list(searched))."
            #else
            return "Found whisper.cpp at \(executable.path) but no model for it to run, so "
                + "voice notes cannot be turned into text. Download a ggml model — "
                + "ggml-small.en.bin from huggingface.co/ggerganov/whisper.cpp is a good "
                + "default — and put it in one of these directories, or point "
                + "SAGE_VOICE_WHISPER_MODEL at the file: \(Self.list(searched))."
            #endif
        }
    }

    /// Capped, because a model search crosses six directories and nobody reads
    /// the twenty-fourth path in a log line.
    private static func list(_ paths: [String], limit: Int = 8) -> String {
        guard paths.count > limit else { return paths.joined(separator: ", ") }
        return paths.prefix(limit).joined(separator: ", ") + " (and \(paths.count - limit) more)"
    }
}

/// `@unchecked` because of `FileManager`, which is not `Sendable` and which
/// this type only ever asks read-only questions — `fileExists`,
/// `isExecutableFile`, `contentsOfDirectory` — all of which Apple documents as
/// safe to call from multiple threads. The alternative was to keep the search
/// unreachable from `LocalASRRuntime.prepare`, an actor method, and therefore
/// untestable.
public struct LocalASRDiscovery: @unchecked Sendable {
    private let fileManager: FileManager
    private let rootDirectory: URL
    private let homeDirectory: URL

    public init(
        fileManager: FileManager = .default,
        rootDirectory: URL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath),
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) {
        self.fileManager = fileManager
        self.rootDirectory = rootDirectory
        self.homeDirectory = homeDirectory
    }

    public func commandBackend(language: String = "en") -> WhisperCommandASRBackend? {
        guard let executable = firstExecutable(), let model = firstModel() else {
            return nil
        }

        return WhisperCommandASRBackend(
            executablePath: executable.path,
            modelPath: model.path,
            language: language,
            extraArguments: commandArgumentsForLowLatencyFallback()
        )
    }

    /// The same search `commandBackend()` runs, with the answer to *why not*
    /// kept instead of thrown away.
    ///
    /// Deliberately a second pass over the same helpers rather than a rewrite of
    /// `commandBackend()` in terms of this: the ordering above is what macOS
    /// ships and it is not being touched.
    public func availability() -> LocalASRAvailability {
        guard let executable = firstExecutable() else {
            return .noExecutable(searched: searchedExecutablePaths())
        }
        guard let model = firstModel() else {
            return .noModel(executable: executable, searched: searchedModelDirectories())
        }
        return .ready(executable: executable, model: model)
    }

    public func firstExecutable() -> URL? {
        #if !os(macOS)
        // The escape hatch, first, because somebody who has said exactly where
        // their build lives should not be overruled by a distro package.
        if let override = overrideExecutable() {
            return override
        }
        #endif

        let names = executableNamesOnPath
        #if os(macOS)
        // An auxiliary executable is something only an `.app` bundle has, and
        // the Mac's whisper-cli is exactly that: staged into `Contents/MacOS`
        // by `package-app.sh` so it falls inside the notarized signature. Off
        // Darwin there is no bundle for it to be inside, so this is a question
        // about a directory layout that does not exist there.
        if let bundled = Bundle.main.url(forAuxiliaryExecutable: "whisper-cli"), isExecutable(bundled) {
            return bundled
        }
        #endif

        if let candidate = executableCandidates().first(where: isExecutable) {
            return candidate
        }

        for name in names {
            if let path = pathFromEnvironment(name), isExecutable(URL(fileURLWithPath: path)) {
                return URL(fileURLWithPath: path)
            }
        }

        return nil
    }

    public func firstModel() -> URL? {
        #if !os(macOS)
        if let override = overrideModel() {
            return override
        }
        #endif

        if let named = modelCandidates().first(where: { fileManager.fileExists(atPath: $0.path) }) {
            return named
        }

        #if !os(macOS)
        // Nothing off Darwin puts the model where we expect, because nothing
        // off Darwin puts it anywhere — the owner downloaded it. A named-file
        // list would find `ggml-small.en.bin` and miss the `ggml-medium.bin`
        // sitting in the same directory, and "no model" would be a lie told
        // about a machine that has one.
        return firstGGMLModelInSearchedDirectories()
        #else
        return nil
        #endif
    }

    /// The names worth looking for on `$PATH`.
    ///
    /// Split by platform for one reason: `main` is what whisper.cpp's own build
    /// directory calls the program, and it is not a name anybody installs onto
    /// `$PATH`. Matching it there would hand a voice note to whatever unrelated
    /// `main` a developer happens to have in `~/bin`, which off Darwin is a
    /// realistic accident rather than a theoretical one. `whisper-cpp` is what
    /// the Debian and Fedora packages install it as.
    ///
    /// The macOS list is unchanged, so the Mac still resolves exactly what it
    /// resolved before.
    ///
    /// These are the names the *owner* knows the program by. What a file has to
    /// be called for the platform to run it — the `.exe` on Windows — is added
    /// by `PlatformExecutable.executableNameCandidates` at each point of use,
    /// so this list stays a statement about whisper.cpp rather than about
    /// filesystems.
    private var executableNamesOnPath: [String] {
        #if os(macOS)
        return ["whisper-cli", "main", "whisper"]
        #else
        return ["whisper-cli", "whisper-cpp", "whisper"]
        #endif
    }

    private func pathFromEnvironment(_ name: String) -> String? {
        let environment = ProcessInfo.processInfo.environment
        // Hoisted: the spelling of a name does not change between directories,
        // and on Windows working it out means parsing `PATHEXT`.
        let names = PlatformExecutable.executableNameCandidates(for: name, in: environment)
        for path in PlatformExecutable.searchPathDirectories(in: environment) {
            let directory = URL(fileURLWithPath: path)
            for candidateName in names {
                let candidate = directory.appendingPathComponent(candidateName)
                if isExecutable(candidate) {
                    return candidate.path
                }
            }
        }
        return nil
    }

    /// Executable *and a file*.
    ///
    /// `isExecutableFile` answers yes for a directory with its execute bit set,
    /// which every directory has. That never mattered while the candidates were
    /// fixed paths inside a bundle, but `SAGE_VOICE_WHISPER_CLI` is documented
    /// to accept the build directory as well as the program — so without this
    /// the directory itself is selected as whisper.cpp and the owner's voice
    /// note fails with a permissions error about a path that is not a program.
    ///
    /// The directory rejection is the part that has to stay here: what "runnable"
    /// means is a platform question and lives in `PlatformExecutable`, but
    /// "and not the folder it came in" is a question only this search asks.
    private func isExecutable(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory),
              !isDirectory.boolValue else {
            return false
        }
        return PlatformExecutable.isRunnableFile(atPath: url.path, fileManager: fileManager)
    }

    /// Joins path components without ever spelling a separator.
    ///
    /// `appendingPathComponent("whisper.cpp/build/bin")` hands `URL` a single
    /// component with two separators of the author's choosing inside it. The
    /// whole reason for going through `URL` is so that choice is not written
    /// down in the source, and a literal `/` in the argument puts it straight
    /// back.
    private func joined(_ base: URL, _ components: String...) -> URL {
        components.reduce(base) { $0.appendingPathComponent($1) }
    }

    /// The same, for a path that names a directory.
    private func joinedDirectory(_ base: URL, _ components: String...) -> URL {
        components.reduce(base) { $0.appendingPathComponent($1, isDirectory: true) }
    }

    /// Speed knobs, not correctness ones — which is what makes the off-Darwin
    /// list shorter rather than different.
    ///
    /// `--suppress-nst` and `--no-speech-thold` are recent whisper.cpp
    /// additions. The Mac runs a revision-pinned build staged by
    /// `provision-asr-assets.sh`, so it is known to have them. On Linux the
    /// program came from the distro, and Debian's has been three releases
    /// behind before now: an unknown flag makes whisper.cpp exit non-zero
    /// before it transcribes a thing, which would turn "slightly noisier
    /// transcripts" into "no transcripts at all". The four flags kept have been
    /// in whisper.cpp since long before any packaged version.
    ///
    /// `WhisperCommandASRBackend` also retries without these if the program
    /// rejects them, so an unusually old build costs one wasted launch rather
    /// than the feature.
    private func commandArgumentsForLowLatencyFallback() -> [String] {
        let threads = min(8, max(4, ProcessInfo.processInfo.processorCount - 2))
        #if os(macOS)
        return [
            "--no-timestamps",
            "--suppress-nst",
            "--no-speech-thold",
            "0.25",
            "--threads",
            "\(threads)",
            "--beam-size",
            "1",
            "--best-of",
            "2"
        ]
        #else
        return [
            "--no-timestamps",
            "--threads",
            "\(threads)",
            "--beam-size",
            "1",
            "--best-of",
            "2"
        ]
        #endif
    }

    private func executableCandidates() -> [URL] {
        var paths: [String] = []

        #if !os(Windows)
        // Homebrew and `/usr/local` are UNIX conventions. On Windows they
        // resolve against the current drive as `C:\opt\homebrew\bin\...`, which
        // has never existed on any machine — and reading them back to the owner
        // in "Looked in:" is noise dressed up as diligence.
        paths += [
            "/opt/homebrew/bin/whisper-cli",
            "/opt/homebrew/bin/whisper",
            "/usr/local/bin/whisper-cli",
            "/usr/local/bin/whisper"
        ]
        #endif

        paths += [
            joined(homeDirectory, "whisper.cpp", "build", "bin", "whisper-cli").path,
            joined(homeDirectory, "whisper.cpp", "main").path,
            joined(rootDirectory, "vendor", "whisper.cpp", "build", "bin", "whisper-cli").path,
            joined(rootDirectory, "third_party", "whisper.cpp", "build", "bin", "whisper-cli").path,
            joined(rootDirectory, "build", "bin", "whisper-cli").path
        ]

        #if !os(macOS)
        paths += portableExecutableCandidatePaths()
        #endif

        #if os(Windows)
        // Windows will not run an extension-less file, so a fixed candidate
        // path means nothing without its suffix on.
        //
        // `.exe` alone rather than the whole of `PATHEXT`: whisper.cpp builds a
        // program, and multiplying every fixed candidate by four would
        // quadruple the "Looked in:" list the owner has to read for a spelling
        // that has never existed. The `PATH` search is the one that honours
        // `PATHEXT` in full, because a `.cmd` shim is a thing that turns up
        // there and nowhere else.
        paths = paths.map { $0 + ".exe" }
        #endif

        return paths.map(URL.init(fileURLWithPath:))
    }

    private func modelCandidates() -> [URL] {
        var filenames = [
            "ggml-large-v3-turbo.bin",
            "ggml-small.en.bin",
            "ggml-base.en.bin",
            "ggml-tiny.en.bin"
        ]
        #if !os(macOS)
        // The multilingual siblings of the four above, and the two larger
        // models somebody with a GPU would reasonably have downloaded. Appended
        // rather than interleaved so the English-only models — which is what a
        // dictation appliance wants — still win when both are present.
        filenames += [
            "ggml-large-v3.bin",
            "ggml-medium.en.bin",
            "ggml-medium.bin",
            "ggml-small.bin",
            "ggml-base.bin",
            "ggml-tiny.bin"
        ]
        #endif

        var directories = [
            (Bundle.main.resourceURL ?? Bundle.main.bundleURL)
                .appendingPathComponent("Models", isDirectory: true),
            rootDirectory.appendingPathComponent("models"),
            joined(rootDirectory, "resources", "Models"),
            joined(homeDirectory, "Library", "Application Support", "QuietType", "Models"),
            joined(homeDirectory, ".cache", "whisper.cpp"),
            joined(homeDirectory, "whisper.cpp", "models")
        ]
        #if !os(macOS)
        directories += portableModelDirectories()
        #endif

        return directories.flatMap { directory in
            filenames.map { directory.appendingPathComponent($0) }
        }
    }

    // MARK: - Off Darwin

    // Everything below is compiled only where there is no bundled ASR to fall
    // back on, and is what makes voice-notes-to-text a Linux feature rather than
    // a Mac one. None of it runs on macOS, so the Mac resolves the same helper
    // and the same model it resolved before.

    #if !os(macOS)

    /// `SAGE_VOICE_WHISPER_CLI`, named to match `SAGE_VOICE_ESPEAK_ROOT`.
    ///
    /// Pointed at a directory as well as at the program itself, because half
    /// the people who set it will point it at the build directory.
    private func overrideExecutable() -> URL? {
        let environment = ProcessInfo.processInfo.environment
        guard let raw = PlatformExecutable.environmentValue("SAGE_VOICE_WHISPER_CLI", in: environment),
              !raw.isEmpty else {
            return nil
        }
        let url = URL(fileURLWithPath: (raw as NSString).expandingTildeInPath)
        if isExecutable(url) {
            return url
        }
        for name in executableNamesOnPath {
            // The suffix matters here for the same reason it matters on `PATH`:
            // somebody who points this at their build directory has named a
            // folder holding `whisper-cli.exe`, not `whisper-cli`.
            for candidateName in PlatformExecutable.executableNameCandidates(for: name, in: environment) {
                let inside = url.appendingPathComponent(candidateName)
                if isExecutable(inside) {
                    return inside
                }
            }
        }
        return nil
    }

    /// `SAGE_VOICE_WHISPER_MODEL`, a file or the directory holding one.
    private func overrideModel() -> URL? {
        guard let raw = PlatformExecutable.environmentValue(
            "SAGE_VOICE_WHISPER_MODEL",
            in: ProcessInfo.processInfo.environment
        ), !raw.isEmpty else {
            return nil
        }
        let url = URL(fileURLWithPath: (raw as NSString).expandingTildeInPath)
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
            return nil
        }
        return isDirectory.boolValue ? firstGGMLModel(in: url) : url
    }

    private func portableExecutableCandidatePaths() -> [String] {
        var paths: [String] = []

        // The repo's own staged copy first. `provision-asr-assets.sh` writes
        // `vendor/asr/bin/whisper-cli`, and nothing in the search list above
        // has ever looked there — on macOS it does not matter, because the
        // release script copies it into the bundle as an auxiliary executable,
        // but off Darwin there is no bundle and this is the vendor directory.
        paths.append(joined(rootDirectory, "vendor", "asr", "bin", "whisper-cli").path)
        paths.append(joined(rootDirectory, "vendor", "asr", "bin", "whisper-cpp").path)

        // Anything Mynah itself staged, under `$XDG_DATA_HOME` — the same
        // directory `MemoryStore` keeps its key in off Darwin. On Windows the
        // same corelibs mapping lands it under the user's AppData, which is why
        // this arm carries the platform without being told about it.
        if let support = applicationSupportDirectory() {
            let bin = support.appendingPathComponent("bin", isDirectory: true)
            paths += ["whisper-cli", "whisper-cpp", "whisper"].map {
                bin.appendingPathComponent($0).path
            }
        }

        #if os(Windows)
        // A source build in the owner's home directory is the one entry below
        // that means anything on Windows. Everything around it is XDG or FHS:
        // conventions of a filesystem Windows does not have, absent here rather
        // than dressed up as somewhere anybody would have looked.
        paths.append(joined(homeDirectory, "whisper.cpp", "build", "bin", "whisper-cpp").path)
        #else
        // Order is preference, and this is the order Linux has shipped: the
        // packaged copies the owner installed before the source build they
        // forgot about.
        paths += [
            joined(homeDirectory, ".local", "bin", "whisper-cli").path,
            joined(homeDirectory, ".local", "bin", "whisper-cpp").path,
            joined(homeDirectory, "whisper.cpp", "build", "bin", "whisper-cpp").path,
            "/usr/local/bin/whisper-cpp",
            "/usr/bin/whisper-cli",
            "/usr/bin/whisper-cpp",
            "/usr/bin/whisper",
            "/opt/whisper.cpp/build/bin/whisper-cli",
            "/opt/whisper.cpp/whisper-cli"
        ]
        #endif
        return paths
    }

    private func portableModelDirectories() -> [URL] {
        var directories: [URL] = [
            joinedDirectory(rootDirectory, "vendor", "asr", "models")
        ]
        if let support = applicationSupportDirectory() {
            directories.append(support.appendingPathComponent("Models", isDirectory: true))
        }
        #if os(Windows)
        // A model is a file the owner downloaded, so the two places worth
        // looking are the one Mynah stages into (above) and the source tree
        // beside a build. `/usr/share` and friends are not empty on Windows —
        // they are meaningless, and listing them in "Looked in:" would send
        // somebody hunting for a directory their machine cannot have.
        directories.append(joinedDirectory(homeDirectory, "whisper.cpp", "models"))
        #else
        directories += [
            joinedDirectory(homeDirectory, ".local", "share", "whisper.cpp", "models"),
            joinedDirectory(homeDirectory, ".local", "share", "whisper.cpp"),
            URL(fileURLWithPath: "/usr/local/share/whisper.cpp/models", isDirectory: true),
            URL(fileURLWithPath: "/usr/share/whisper.cpp/models", isDirectory: true),
            URL(fileURLWithPath: "/usr/share/whisper.cpp", isDirectory: true),
            URL(fileURLWithPath: "/opt/whisper.cpp/models", isDirectory: true)
        ]
        #endif
        return directories
    }

    /// `$XDG_DATA_HOME/SAGE Voice Bridge`, via the same corelibs-Foundation
    /// mapping `MemoryStore` relies on. Optional because `urls(for:in:)` can
    /// come back empty on a machine with no writable home.
    private func applicationSupportDirectory() -> URL? {
        fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("SAGE Voice Bridge", isDirectory: true)
    }

    /// The last resort when none of the expected filenames matched: whatever
    /// `ggml-*.bin` is actually sitting in one of the searched directories.
    ///
    /// Sorted by name rather than by size so the choice is reproducible; a
    /// machine with two models gets the same one every boot, and the owner can
    /// override it if it is the wrong one.
    private func firstGGMLModelInSearchedDirectories() -> URL? {
        for directory in portableModelDirectories() {
            if let found = firstGGMLModel(in: directory) {
                return found
            }
        }
        return nil
    }

    private func firstGGMLModel(in directory: URL) -> URL? {
        guard let entries = try? fileManager.contentsOfDirectory(atPath: directory.path) else {
            return nil
        }
        let models = entries
            .filter { $0.hasPrefix("ggml-") && $0.hasSuffix(".bin") }
            .sorted()
        guard let name = models.first else { return nil }
        return directory.appendingPathComponent(name)
    }

    #endif

    // MARK: - What was looked at

    private func searchedExecutablePaths() -> [String] {
        var searched = executableCandidates().map(\.path)
        // Spelled the way the owner's own shell spells it, because this string
        // is read by somebody about to go and check.
        #if os(Windows)
        searched += executableNamesOnPath.map { "\($0).exe on %PATH%" }
        #else
        searched += executableNamesOnPath.map { "\($0) on $PATH" }
        #endif
        return searched
    }

    private func searchedModelDirectories() -> [String] {
        var seen = Set<String>()
        var directories: [String] = []
        for candidate in modelCandidates() {
            let directory = candidate.deletingLastPathComponent().path
            if seen.insert(directory).inserted {
                directories.append(directory)
            }
        }
        return directories
    }
}

/// Starts the best packaged speech engine and keeps the whisper.cpp fallback
/// ready behind it.
///
/// The helpers and models are release assets, not runtime downloads. That keeps
/// every executable inside the app's notarized signature and means first speech
/// never asks the owner to install Python, Homebrew, or a command-line tool.
///
/// ## Off Darwin there is no first engine
///
/// WhisperKit is CoreML: an `.mlmodelc` encoder and decoder run through the
/// Neural Engine, on Apple silicon, from a helper built with Apple's own
/// toolchain. There is no port of it and there is not going to be one, so on
/// Linux and Windows the cascade has exactly one rung — **whisper.cpp, which
/// was already here as the fallback and is portable by construction.**
///
/// That is a selection, not an accident, and the difference matters. The code
/// used to append the WhisperKit rung unconditionally and let it fail its way
/// out of the list, which off Darwin produced a startup failure reading
/// *"WhisperKit helper is not bundled"* — true, useless, and describing a
/// situation nobody can fix, sitting alongside the message about the engine the
/// owner actually needs to install. Voice-notes-to-text is the speech feature
/// the port keeps, so its diagnosis is not something to bury under an
/// irrelevant one.
public actor LocalASRRuntime {
    public static let shared = LocalASRRuntime()

    #if os(macOS)
    private var nativeSupervisor: WhisperKitServerSupervisor?
    #endif

    public init() {}

    /// - Parameter discovery: where the whisper.cpp program and model are looked
    ///   for. Defaulted to the real search; a parameter at all so a test can
    ///   point it at a directory it controls, which is the only way to prove the
    ///   command backend is selected rather than merely constructible.
    /// - Parameter log: where the per-transcription timing goes. Defaulted to
    ///   nothing so the app and the CLI probes stay quiet; the daemon passes its
    ///   own, because the daemon is the process somebody complained about.
    public func prepare(
        language: String = "en",
        discovery: LocalASRDiscovery = LocalASRDiscovery(),
        log: @escaping @Sendable (String) -> Void = { _ in }
    ) async throws -> CascadingAudioFileTranscriber {
        var backends: [AudioFileTranscribing] = []
        var startupFailures: [String] = []

        #if os(macOS)
        if let executable = WhisperKitServerBundleLocator.bundledExecutable() {
            let supervisor: WhisperKitServerSupervisor
            if let nativeSupervisor {
                supervisor = nativeSupervisor
            } else {
                supervisor = WhisperKitServerSupervisor(executableURL: executable)
                nativeSupervisor = supervisor
            }
            do {
                // **Checked, not started.** This called `ensureRunning()` here,
                // at daemon boot, and the comment at the call site defended it:
                // "better to know now than when the first voice note arrives".
                //
                // That argument is about *diagnosis*, and it is right — a bundle
                // shipped with no ASR helper once crash-looped the daemon under
                // launchd. But what it was diagnosing is a missing file, and a
                // missing file can be seen without loading a 626 MB model.
                //
                // What the eager start actually bought was a whisper-large-v3
                // server resident for the life of the daemon on every Mac,
                // holding both encoder and decoder on `cpuAndGPU`, whether or
                // not anybody ever sent a voice note. That is the leading
                // candidate for "it's made my laptop very laggy", and it is
                // invisible on this owner's Mac because QuietType already owns
                // the port — see `isUsingSomebodyElsesServer`.
                //
                // So: the file check at boot, the process on first speech.
                try supervisor.verifyInstallation()
                backends.append(ManagedWhisperKitTranscriber(
                    supervisor: supervisor,
                    inner: WhisperKitServerTranscriber(
                        endpoint: supervisor.baseURL.appendingPathComponent("v1/audio/transcriptions"),
                        model: "large-v3-v20240930_626MB",
                        language: language,
                        timeoutSeconds: WhisperKitServerTranscriber.minimumFullAudioTimeoutSeconds
                    ),
                    log: log
                ))
            } catch {
                startupFailures.append("WhisperKit: \(error)")
            }
        } else {
            startupFailures.append("WhisperKit helper is not bundled")
        }
        #endif

        if let fallback = discovery.commandBackend(language: language) {
            backends.append(fallback)
            #if !os(macOS)
            // **Said at boot, not only when a note arrives.** whisper.cpp being
            // installed is only half of what off-Darwin transcription needs;
            // without ffmpeg the engine starts, reports itself ready, and then
            // refuses every note WhatsApp or Signal actually sends. Warning
            // rather than failing, because a WAV still transcribes fine and
            // removing a working engine over a missing converter would be worse
            // than the gap it is describing.
            if WhisperAudioConverter.discover() == nil {
                log("[asr] " + WhisperAudioConverter.missingConverterWarning)
            }
            #endif
        } else {
            #if os(macOS)
            startupFailures.append("whisper.cpp helper or model is not bundled")
            #else
            // Not a packaging mistake here — nothing is bundled off Darwin by
            // design — so "not bundled" would be a shrug where the owner needs
            // an instruction. `availability()` says which half is missing, where
            // it looked, and what to install.
            startupFailures.append(discovery.availability().explanation)
            #endif
        }

        guard !backends.isEmpty else {
            throw AudioTranscriberError.allBackendsFailed(startupFailures)
        }
        return CascadingAudioFileTranscriber(backends, log: log)
    }
}

/// Starts the ASR server the first time somebody actually speaks, and checks it
/// is still there before every transcription after that.
///
/// ## Two failures, one wrapper
///
/// **The server was started once, at daemon boot, and never checked again.** The
/// endpoint was baked into a `WhisperKitServerTranscriber` at that moment, so
/// nothing downstream could tell a healthy server from a departed one — every
/// voice note simply failed until somebody restarted the daemon. That is not
/// hypothetical on the owner's Mac: the process answering on port 50060 belongs
/// to **QuietType**, not to Mynah, and Mynah adopted it without noticing. When
/// QuietType quits, so does Mynah's ability to hear.
///
/// **And starting at boot is what made the appliance heavy.** A 626 MB
/// whisper-large-v3 model, encoder and decoder both on `cpuAndGPU`, resident for
/// the life of the daemon on every Mac — including the ones where nobody ever
/// sends a voice note. Asking here instead means a Mac that is never spoken to
/// never loads it.
///
/// ## The timing line
///
/// #34 asked for per-request ASR timing and there was none, which is why "ASR
/// exceeded the model on three of twelve turns" could be observed and not
/// explained. Emitted per transcription rather than aggregated, because the
/// interesting cases are individual: 5.8 s to transcribe half a second of speech
/// is not visible in a mean.
struct ManagedWhisperKitTranscriber: AudioFileTranscribing {
    let supervisor: WhisperKitServerSupervisor
    let inner: WhisperKitServerTranscriber
    let log: @Sendable (String) -> Void

    func transcribe(audioFile: URL, options: AudioTranscriptionOptions) async throws -> String {
        let waitingForServer = Date()
        try await supervisor.ensureRunning()
        let startupSeconds = Date().timeIntervalSince(waitingForServer)

        let started = Date()
        let text = try await inner.transcribe(audioFile: audioFile, options: options)
        let seconds = Date().timeIntervalSince(started)

        let bytes = (try? FileManager.default.attributesOfItem(atPath: audioFile.path)[.size] as? Int) ?? nil
        // Whose server did the work is on every line, not just the first. It is
        // the difference between a Mac carrying its own copy of the model and
        // one borrowing somebody else's, and that difference is the whole of why
        // the lag report could not be reproduced here.
        log(String(
            format: "[asr] transcribed %@ in %.1fs%@ — %@ server%@",
            bytes.map { "\($0 / 1024)kB" } ?? "audio",
            seconds,
            startupSeconds > 0.5 ? String(format: ", after %.1fs starting it", startupSeconds) : "",
            supervisor.isUsingSomebodyElsesServer ? "somebody else's" : "our own",
            text.isEmpty ? " — and it heard nothing" : ""
        ))
        return text
    }
}

public struct CascadingAudioFileTranscriber: AudioFileTranscribing {
    private let transcribers: [AudioFileTranscribing]
    private let log: @Sendable (String) -> Void

    /// What to say when the cascade is empty.
    ///
    /// Platform-split because the two situations are genuinely different and
    /// the Mac sentence is wrong everywhere else. On a Mac an empty cascade is
    /// usually *temporary* — the Apple silicon engine is still warming — and
    /// waiting is the right advice. Off Darwin there is nothing warming up:
    /// whisper.cpp is either installed or it is not, and telling a Linux owner
    /// to wait for an Apple silicon engine is an instruction they cannot
    /// follow, on a Mac they do not have.
    static var nothingIsReady: String {
        #if os(macOS)
        return "No local ASR backend is ready. Wait for the Apple Silicon speech engine to finish startup."
        #else
        let availability = LocalASRDiscovery().availability()
        // Both halves of the truth, because an empty cascade has two causes and
        // blaming the installation for the other one sends the owner to install
        // something they already have. A first draft of this said "no local
        // speech recognition is installed" and then appended "speech
        // recognition is ready: /usr/local/bin/whisper-cli" to it.
        if case let .ready(executable, model) = availability {
            return "No speech recognition backend was started, even though whisper.cpp is "
                + "installed at \(executable.path) with \(model.lastPathComponent). That is a "
                + "fault in Mynah rather than in the installation — restart the daemon, and if "
                + "it persists the daemon log names the backend that refused to start."
        }
        return "Voice notes cannot be turned into text. " + availability.explanation
        #endif
    }

    public init(
        _ transcribers: [AudioFileTranscribing],
        log: @escaping @Sendable (String) -> Void = { _ in }
    ) {
        self.transcribers = transcribers
        self.log = log
    }

    public func transcribe(audioFile: URL, options: AudioTranscriptionOptions) async throws -> String {
        guard !transcribers.isEmpty else {
            throw AudioTranscriberError.allBackendsFailed([Self.nothingIsReady])
        }

        var errors: [String] = []
        let started = Date()
        for (index, transcriber) in transcribers.enumerated() {
            do {
                let text = try await transcriber.transcribe(audioFile: audioFile, options: options)
                reportRescue(ifNeeded: errors, succeedingAt: index, started: started)
                return text
            } catch {
                errors.append(AudioTranscriberError.describe(error))
            }
        }
        throw AudioTranscriberError.allBackendsFailed(errors)
    }

    public func transcribeWithTiming(audioFile: URL, options: AudioTranscriptionOptions) async throws -> TimedTranscriptionResult {
        guard !transcribers.isEmpty else {
            throw AudioTranscriberError.allBackendsFailed([Self.nothingIsReady])
        }

        var errors: [String] = []
        let started = Date()
        for (index, transcriber) in transcribers.enumerated() {
            do {
                let result = try await transcriber.transcribeWithTiming(audioFile: audioFile, options: options)
                reportRescue(ifNeeded: errors, succeedingAt: index, started: started)
                return result
            } catch {
                errors.append(AudioTranscriberError.describe(error))
            }
        }
        throw AudioTranscriberError.allBackendsFailed(errors)
    }

    /// A successful fallback used to erase the only evidence that another
    /// backend had failed first. On the owner's real call that made a rescued
    /// 4.5-second recognition indistinguishable from an ordinary 1.0-second
    /// turn, leaving the Mac-lag investigation with a hole in its instrument.
    private func reportRescue(ifNeeded errors: [String], succeedingAt index: Int, started: Date) {
        guard !errors.isEmpty else { return }
        let failures = errors.enumerated().map { offset, error in
            "backend \(offset + 1): \(error)"
        }.joined(separator: "; ")
        log(String(
            format: "[asr] rescued by backend %d after %.1fs (%@)",
            index + 1,
            Date().timeIntervalSince(started),
            failures
        ))
    }
}

public extension AudioTranscriberError {
    static func describe(_ error: Error) -> String {
        if case let AudioTranscriberError.requestFailed(message) = error {
            return message
        }
        return String(describing: error)
    }
}

/// The seam where a voice note stops being whatever the messenger sent and
/// starts being something whisper.cpp can read.
///
/// **This was a straight forward and it broke the one speech feature the port
/// keeps.** `transcribe(audioFile:)` handed the file through to
/// `transcribe(wavFile:)` unchanged, and the parameter name was the whole of
/// the contract: whisper.cpp reads 16 kHz PCM WAV and nothing else, while a
/// WhatsApp voice note is Ogg/Opus and a Signal one is MPEG-4 audio. So on a
/// Linux box with whisper.cpp and a model both installed perfectly, every voice
/// note produced a refusal from a program that had never looked at any audio.
///
/// **The Mac keeps the forward, deliberately.** There the first rung of the
/// cascade is the WhisperKit helper, which decodes the container itself through
/// Apple's audio stack — nothing in this repository has ever converted anything
/// for it, and the whisper.cpp rung behind it has been fed the raw file since
/// the day it was written. Changing that would be changing shipping macOS
/// behaviour to fix a Linux bug, so the conversion is compiled in off Darwin
/// only and the Mac's path through this function is byte-for-byte what it was.
extension WhisperCommandASRBackend: AudioFileTranscribing {
    public func transcribe(audioFile: URL, options: AudioTranscriptionOptions) async throws -> String {
        #if os(macOS)
        return try await transcribe(wavFile: audioFile, options: options)
        #else
        // Throws by name when the note needs converting and ffmpeg is absent.
        // It must throw: returning the Ogg anyway would put whisper.cpp's own
        // refusal in the log and an empty transcript in front of the owner,
        // which is the failure this is here to end.
        let prepared = try await PreparedWhisperAudio.prepare(audioFile: audioFile)
        defer { prepared.discard() }
        return try await transcribe(wavFile: prepared.url, options: options)
        #endif
    }
}
