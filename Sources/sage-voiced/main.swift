import Foundation
import SageVoiceCore

// Smoke harness for the subsystems, one subcommand each. Not the daemon —
// the daemon (Signal transport wired to ASR -> brain -> TTS) lands on top of
// these once the setup flow can tell it which backend to build.
//
//   sage-voiced transcribe <file.wav> [--endpoint URL] [--model NAME]
//   sage-voiced brain "<transcript>" [--provider NAME] [--model NAME] [--sage PATH]
//   sage-voiced setup
//   sage-voiced verify-sage <path/to/SAGE.app>

func usage() -> Never {
    FileHandle.standardError.write(Data("""
    usage:
      sage-voiced transcribe <file.wav> [--endpoint URL] [--model NAME]
      sage-voiced brain "<transcript>" [--provider NAME] [--model NAME] [--sage PATH]
      sage-voiced setup
      sage-voiced verify-sage <path/to/SAGE.app>
      sage-voiced daemon --allow <your-number> [--account N] [--sage PATH]

    brain providers:
      ollama (default, local)   openai     deepseek   moonshot
      anthropic                 gemini     groq       lmstudio (local)

    Cloud providers read their key from the environment: ANTHROPIC_API_KEY,
    OPENAI_API_KEY, DEEPSEEK_API_KEY, GEMINI_API_KEY, GROQ_API_KEY,
    MOONSHOT_API_KEY.

    """.utf8))
    exit(2)
}

/// Trailing `--flag value` pairs, whatever the subcommand.
func parseFlags(_ arguments: [String]) -> [String: String] {
    var flags: [String: String] = [:]
    var index = 0
    while index + 1 < arguments.count {
        if arguments[index].hasPrefix("--") {
            flags[String(arguments[index].dropFirst(2))] = arguments[index + 1]
            index += 2
        } else {
            index += 1
        }
    }
    return flags
}

/// Runs an async body from the top level and exits with its status.
func runAndExit(_ body: @escaping () async -> Int32) -> Never {
    let semaphore = DispatchSemaphore(value: 0)
    var status: Int32 = 0
    Task {
        status = await body()
        semaphore.signal()
    }
    semaphore.wait()
    exit(status)
}

func fail(_ message: String) -> Int32 {
    FileHandle.standardError.write(Data("\(message)\n".utf8))
    return 1
}

// MARK: - transcribe

func runTranscribe(_ arguments: [String]) -> Never {
    guard let path = arguments.first else { usage() }
    let flags = parseFlags(Array(arguments.dropFirst()))

    let endpoint = flags["endpoint"].flatMap { URL(string: $0) }
        ?? URL(string: "http://127.0.0.1:50060/v1/audio/transcriptions")!
    let fileURL = URL(fileURLWithPath: path)

    guard FileManager.default.fileExists(atPath: fileURL.path) else {
        exit(fail("no such file: \(path)"))
    }

    let transcriber = WhisperKitServerTranscriber(
        endpoint: endpoint,
        model: flags["model"] ?? "large-v3",
        language: "en",
        timeoutSeconds: WhisperKitServerTranscriber.minimumFullAudioTimeoutSeconds
    )

    runAndExit {
        let started = Date()
        do {
            let text = try await transcriber.transcribe(
                audioFile: fileURL,
                options: AudioTranscriptionOptions()
            )
            print(String(format: "[%.2fs] %@", Date().timeIntervalSince(started), text))
            return 0
        } catch {
            return fail("transcribe failed: \(error)")
        }
    }
}

// MARK: - brain

/// Builds a backend from a provider name, reading any key from the environment.
///
/// Deliberately explicit rather than auto-detecting: this is a test harness,
/// and a harness that silently picks a different provider than the one you
/// named is worse than useless when you are trying to compare them.
struct HarnessError: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

func makeBackend(provider: String, model: String?, ollamaBaseURL: String?) throws -> BrainBackend {
    func environmentKey(_ name: String) throws -> String {
        guard let value = ProcessInfo.processInfo.environment[name], !value.isEmpty else {
            throw HarnessError("\(name) is not set in the environment")
        }
        return value
    }

    func openAICompat(
        _ compatProvider: OpenAICompatProvider,
        defaultModel: String,
        keyVariable: String?
    ) throws -> BrainBackend {
        let credential: BrainCredential
        if let keyVariable {
            credential = StaticAPIKeyCredential.bearer(
                try environmentKey(keyVariable),
                providerLabel: compatProvider.displayName
            )
        } else {
            // A local server that wants no auth still needs a credential object.
            credential = StaticAPIKeyCredential.bearer("local", providerLabel: compatProvider.displayName)
        }
        return OpenAICompatBackend(
            provider: compatProvider,
            modelName: model ?? defaultModel,
            credential: credential
        )
    }

    switch provider {
    case "ollama":
        // `--ollama` points at a daemon over an SSH tunnel, so the appliance's
        // model can be driven from a dev machine that has not pulled it.
        let client = ollamaBaseURL.flatMap { URL(string: $0) }.map { OllamaClient(baseURL: $0) }
            ?? OllamaClient()
        return OllamaBackend(client: client, model: model ?? "qwen3.5:4b")
    case "anthropic":
        return AnthropicBackend(
            modelName: model ?? "claude-opus-5",
            apiKey: try environmentKey("ANTHROPIC_API_KEY")
        )
    case "openai":
        return try openAICompat(.openAI, defaultModel: "gpt-5", keyVariable: "OPENAI_API_KEY")
    case "deepseek":
        return try openAICompat(.deepSeek, defaultModel: "deepseek-chat", keyVariable: "DEEPSEEK_API_KEY")
    case "moonshot", "kimi":
        return try openAICompat(.moonshot, defaultModel: "kimi-k2-0905-preview", keyVariable: "MOONSHOT_API_KEY")
    case "groq":
        return try openAICompat(.groq, defaultModel: "llama-3.3-70b-versatile", keyVariable: "GROQ_API_KEY")
    case "gemini":
        return try openAICompat(.gemini, defaultModel: "gemini-2.5-flash", keyVariable: "GEMINI_API_KEY")
    case "lmstudio":
        return try openAICompat(.lmStudio(), defaultModel: "local-model", keyVariable: nil)

    case "openai-compat":
        // Any `/v1/chat/completions` server, named by `--base-url`.
        //
        // Worth having beyond genericity: Ollama serves this shape too, so
        // pointing it at a local daemon exercises the adapter's encoding
        // against a real server — tool schemas, JSON-string arguments, null
        // content on a tool-call turn, id matching — without a cloud key.
        guard let raw = ollamaBaseURL, let url = URL(string: raw) else {
            throw HarnessError("--provider openai-compat requires --base-url")
        }
        return try openAICompat(
            OpenAICompatProvider(
                identifier: "openai-compat",
                displayName: url.host ?? "custom",
                baseURL: url,
                isLocal: LoopbackSecurity.isLoopback(url)
            ),
            defaultModel: "qwen3.5:4b",
            keyVariable: nil
        )

    default:
        throw HarnessError("unknown provider '\(provider)'")
    }
}

func runBrain(_ arguments: [String]) -> Never {
    guard let transcript = arguments.first, !transcript.hasPrefix("--") else { usage() }
    let flags = parseFlags(Array(arguments.dropFirst()))

    let backend: BrainBackend
    do {
        backend = try makeBackend(
            provider: flags["provider"] ?? "ollama",
            model: flags["model"],
            ollamaBaseURL: flags["ollama"] ?? flags["base-url"]
        )
    } catch {
        exit(fail("\(error)"))
    }

    let sagePath = flags["sage"] ?? "/Applications/SAGE.app/Contents/MacOS/sage-gui"
    let mcp = MCPClient(executableURL: URL(fileURLWithPath: sagePath), arguments: ["mcp"])
    let loop = ToolLoop(backend: backend, mcp: mcp)

    runAndExit {
        defer { mcp.stop() }
        do {
            print("backend: \(backend.displayDescription)")
            let info = try await mcp.start()
            print("mcp:     \(info.name) \(info.version)")

            let tools = try await loop.availableTools()
            print("tools:   \(tools.count) offered — \(tools.map(\.name).sorted().joined(separator: ", "))")
            print("---")

            let result = try await loop.run(transcript: transcript, tools: tools)
            print(result.reply)
            print("---")
            print(result.trace.summary)
            for call in result.trace.toolCalls {
                print("  \(call.summary)")
            }
            return 0
        } catch {
            let stderr = mcp.stderrLog
            return fail("brain failed: \(error)" + (stderr.isEmpty ? "" : "\n--- mcp stderr ---\n\(stderr)"))
        }
    }
}

// MARK: - setup

/// Runs the first-run environment probe and prints the menu the install screen
/// would show. Read-only: this is the same code path the settings panel will
/// re-run later to offer "move me to fully local".
func runSetup(_ arguments: [String]) -> Never {
    runAndExit {
        let probe = await EnvironmentProbe().run()
        let choices = BrainSetupPlanner().plan(for: probe)

        print("== probe ==")
        print("ollama:   \(probe.localRuntime)")
        print("hardware: \(probe.hardware)")
        print("sage:     \(probe.sage)")
        print("keys:     \(probe.ambientAPIKeys.variableNames.isEmpty ? "none set" : probe.ambientAPIKeys.variableNames.joined(separator: ", "))")
        for cli in probe.agentCLIs {
            print("cli:      \(cli)")
        }
        print()
        print("== options ==")
        for option in choices.options {
            let mark = option.availability.isAvailable ? "[ok]  " : "[--]  "
            let privacy = option.keepsWordsOnDevice ? "on-device" : "leaves machine"
            print("\(mark)\(option.label)  (\(option.requirement.rawValue), \(privacy))")
            print("        \(option.summary)")
            if let reason = option.availability.reason {
                print("        unavailable: \(reason)")
            }
        }
        if let recommendation = choices.recommendation {
            print()
            print("recommended: \(recommendation.optionID) — \(recommendation.rationale)")
            print("(a recommendation, not a selection: the owner still has to pick)")
        }
        return 0
    }
}

/// Verifies a SAGE.app bundle the way the appliance will before running it.
func runVerifySage(_ arguments: [String]) -> Never {
    guard let path = arguments.first else {
        exit(fail("usage: sage-voiced verify-sage <path/to/SAGE.app>"))
    }
    let app = URL(fileURLWithPath: path)
    switch SageNodeLocator.verifyBundle(at: app) {
    case .success(let executable):
        print("ok: \(executable.path)")
        print("version: \(SageNodeLocator.bundleVersion(at: app) ?? "unknown")")
        exit(0)
    case .failure(let error):
        exit(fail("refused: \(error)"))
    }
}

// MARK: - daemon

/// The real thing: listen on Signal, act, reply.
func runDaemon(_ arguments: [String]) -> Never {
    let flags = parseFlags(arguments)

    guard let allowRaw = flags["allow"] ?? ProcessInfo.processInfo.environment["SAGE_VOICE_ALLOW"] else {
        exit(fail("""
        --allow is required: the daemon refuses to serve anyone not named.

          sage-voiced daemon --allow +6591234567 [--account +6591234567]

        Pass your OWN Signal number. By default only Note-to-Self is served, so
        you message yourself and the appliance answers in that thread.
        """))
    }

    let allowlist: SignalSenderAllowlist
    do {
        allowlist = try SignalSenderAllowlist(commaSeparated: allowRaw)
    } catch {
        exit(fail("bad --allow: \(error)"))
    }

    let backend: BrainBackend
    do {
        backend = try makeBackend(
            provider: flags["provider"] ?? "ollama",
            model: flags["model"],
            ollamaBaseURL: flags["ollama"]
        )
    } catch {
        exit(fail("\(error)"))
    }

    let signal = SignalClient(configuration: .init(
        allowlist: allowlist,
        endpoint: flags["socket"].map { SignalEndpoint.unixSocket(path: $0) } ?? .defaultUnixSocket(),
        account: flags["account"]
    ))

    let transcriber = WhisperKitServerTranscriber(
        endpoint: flags["endpoint"].flatMap { URL(string: $0) }
            ?? URL(string: "http://127.0.0.1:50060/v1/audio/transcriptions")!,
        model: flags["asr-model"] ?? "large-v3",
        language: "en",
        timeoutSeconds: WhisperKitServerTranscriber.minimumFullAudioTimeoutSeconds
    )

    let sagePath = flags["sage"] ?? "/Applications/SAGE.app/Contents/MacOS/sage-gui"
    let mcp = MCPClient(executableURL: URL(fileURLWithPath: sagePath), arguments: ["mcp"])
    let loop = ToolLoop(backend: backend, mcp: mcp)
    let daemon = VoiceBridgeDaemon(signal: signal, transcriber: transcriber, loop: loop)

    runAndExit {
        do {
            let info = try await mcp.start()
            let tools = try await loop.availableTools()
            print("backend: \(backend.displayDescription)")
            print("mcp:     \(info.name) \(info.version), \(tools.count) tools")
            print("allow:   \(allowlist.identities.count) identity(ies), Note-to-Self only")
            print("ready — send yourself a Signal message.")
        } catch {
            return fail("startup failed: \(error)\n\(mcp.stderrLog)")
        }
        await daemon.run()
        mcp.stop()
        return 0
    }
}

// MARK: - Dispatch

let arguments = Array(CommandLine.arguments.dropFirst())
switch arguments.first {
case "transcribe":  runTranscribe(Array(arguments.dropFirst()))
case "brain":       runBrain(Array(arguments.dropFirst()))
case "setup":       runSetup(Array(arguments.dropFirst()))
case "verify-sage": runVerifySage(Array(arguments.dropFirst()))
case "daemon":      runDaemon(Array(arguments.dropFirst()))
default:            usage()
}
