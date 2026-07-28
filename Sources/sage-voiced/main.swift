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
      sage-voiced search "<query>"
      sage-voiced key [--provider gemini] [--key <key>]   instructions, then verify
      sage-voiced google [--provision] [--sign-out]        sign in with Google
      sage-voiced daemon --allow <your-number> [--account N] [--sage PATH]
                         [--reply-prefix "🧠🧠🧠 "] [--acknowledge]

    `brain` and `daemon` take --no-web to run with SAGE tools only.
    Web search uses Brave when BRAVE_SEARCH_API_KEY is set, DuckDuckGo otherwise.

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

func makeBackend(
    provider: String,
    model: String?,
    ollamaBaseURL: String?,
    // Supplied when the owner has just pasted a key and it is not in the
    // environment yet — validating what they typed, rather than what happens
    // to be exported, is the whole point of checking at all.
    explicitKey: String? = nil
) throws -> BrainBackend {
    func environmentKey(_ name: String) throws -> String {
        if let explicitKey, !explicitKey.isEmpty { return explicitKey }
        // Environment, then the stored key. The daemon runs for weeks and must
        // not carry a credential in its argument vector, where every local
        // process can read it out of `ps`.
        if let stored = ProviderKeyStore().key(forProvider: provider), !stored.isEmpty {
            return stored
        }
        throw HarnessError("no key for '\(provider)' — run: sage-voiced key --provider \(provider) --key <key> --save")
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
        // v4-flash, not "deepseek-chat": the alias no longer resolves on this
        // account — /v1/models serves only deepseek-v4-flash and deepseek-v4-pro.
        // Flash is the owner's choice and the right one here, since the whole
        // reason to leave the local model is turn latency.
        return try openAICompat(.deepSeek, defaultModel: "deepseek-v4-flash", keyVariable: "DEEPSEEK_API_KEY")
    case "moonshot", "kimi":
        return try openAICompat(.moonshot, defaultModel: "kimi-k2-0905-preview", keyVariable: "MOONSHOT_API_KEY")
    case "groq":
        return try openAICompat(.groq, defaultModel: "llama-3.3-70b-versatile", keyVariable: "GROQ_API_KEY")
    case "gemini":
        // gemini-2.5-flash was two generations stale. 3.6 Flash went GA on
        // 2026-07-21 and keeps the free tier this product depends on.
        return try openAICompat(.gemini, defaultModel: "gemini-3.6-flash", keyVariable: "GEMINI_API_KEY")
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

/// Everything the loop can call: SAGE's governed memory, plus the open internet.
///
/// SAGE is required and web search is not, which is the whole reason these are
/// composed rather than merged. An appliance that cannot reach its own memory is
/// broken; one that cannot reach Google is just offline, and the owner should
/// still be able to ask it what is on their backlog.
///
/// `--no-web` exists for the case where that is a policy rather than a fault.
///
/// Returns the notes source alongside the catalogue because the daemon needs
/// that same instance: it is what knows which documents this turn produced, and
/// therefore what the reply should carry.
func makeToolSource(
    mcp: MCPClient,
    allowWeb: Bool
) -> (tools: ToolProviding, notes: NotesToolSource) {
    let notes = NotesToolSource(delivery: .attachedToReply, log: { print($0) })

    var sources: [CompositeToolSource.Source] = [
        .init(
            label: "SAGE MCP",
            provider: mcp,
            isRequired: true,
            expectedToolNames: BrainPrompts.voiceToolAllowlist
                .subtracting([WebSearchToolSource.toolName])
                .subtracting(NotesToolSource.toolNames)
        ),
        // Required. Unlike search, this has no network to be down and no
        // credential to expire — if it cannot list its three tools something is
        // wrong with the appliance itself, and degrading quietly would hide it.
        .init(
            label: "notes",
            provider: notes,
            isRequired: true,
            expectedToolNames: NotesToolSource.toolNames
        )
    ]
    if allowWeb {
        sources.append(
            .init(
                label: "web search",
                provider: WebSearchToolSource(
                    backends: WebSearchToolSource.defaultBackends(),
                    log: { print($0) }
                ),
                isRequired: false,
                expectedToolNames: [WebSearchToolSource.toolName]
            )
        )
    }
    return (CompositeToolSource(sources: sources, log: { print($0) }), notes)
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
    // Pinned. Without this the node derives the appliance's identity from the
    // launch working directory, so the `cd` in the launch script decides which
    // memories the owner has.
    let mcp = MCPClient(
        executableURL: URL(fileURLWithPath: sagePath),
        arguments: ["mcp"],
        environment: MynahIdentity.applianceEnvironment()
    )
    // `parseFlags` only reads `--key value` pairs, so a bare switch has to be
    // looked for in the raw arguments.
    let (tools, _) = makeToolSource(mcp: mcp, allowWeb: !arguments.contains("--no-web"))
    // The owner's choice, made in Mynah, read here. `--voice-notes` overrides
    // it for a one-off test without touching what they saved.
    let style: ReplyStyle = arguments.contains("--voice-notes")
        ? .spoken
        : ReplyPreferences().style()
    let loop = ToolLoop(
        backend: backend,
        mcp: tools,
        configuration: ToolLoop.Configuration(
            systemPrompt: BrainPrompts.voiceAgentManager(style: style),
            maxGeneratedTokens: style.maximumGeneratedTokens
        )
    )
    FileHandle.standardError.write(Data("[daemon] reply style: \(style.rawValue)\n".utf8))

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
/// Runs one search and prints exactly what the model would be handed.
///
/// Worth a subcommand because the keyless provider is a scraper: when it breaks
/// it will break as a bad spoken answer, three layers deep, and the first
/// question will be whether search or the model was at fault. This answers that
/// in one command, with no SAGE node and no model involved.
func runSearch(_ arguments: [String]) -> Never {
    guard let query = arguments.first, !query.hasPrefix("--") else { usage() }

    let backends = WebSearchToolSource.defaultBackends()
    let source = WebSearchToolSource(backends: backends, log: { print($0) })

    runAndExit {
        print("providers: \(backends.map(\.providerName).joined(separator: " → "))")
        do {
            let output = try await source.call(
                name: WebSearchToolSource.toolName,
                arguments: ["query": .string(query)]
            )
            print("---")
            print(output)
            return 0
        } catch {
            return fail("\(error)")
        }
    }
}

/// Prints the paste-a-key instructions, and proves a key actually works.
///
/// The shipping default for cloud brains. Google sign-in loses to it on policy
/// rather than engineering: `cloud-platform` is a sensitive scope, so an
/// unverified app's refresh tokens die after 7 days — an appliance that works
/// for a week and then stops, on a machine nobody is sitting at.
func runKey(_ arguments: [String]) -> Never {
    let flags = parseFlags(arguments)
    let providerID = flags["provider"] ?? "gemini"
    guard let instructions = APIKeyOnboarding.instructions(forProvider: providerID) else {
        exit(fail("no key instructions for provider '\(providerID)'"))
    }

    guard let raw = flags["key"] ?? ProcessInfo.processInfo.environment[
        providerID == "gemini" ? "GEMINI_API_KEY"
            : providerID == "openai" ? "OPENAI_API_KEY" : "ANTHROPIC_API_KEY"
    ] else {
        print("""

        Connect \(instructions.providerName)

        \(instructions.steps.enumerated().map { "  \($0.offset + 1). \($0.element)" }.joined(separator: "\n"))

          \(instructions.keyPageURL.absoluteString)

        \(instructions.looksLikeHint)
        \(instructions.costNote ?? "")

        Then: sage-voiced key --provider \(providerID) --key <your key>

        """)
        exit(0)
    }

    let key = APIKeyOnboarding.normalise(raw)
    if let problem = APIKeyOnboarding.shapeProblem(of: key, expecting: providerID) {
        exit(fail(problem.spokenDescription))
    }

    let backend: BrainBackend
    do {
        backend = try makeBackend(provider: providerID, model: flags["model"], ollamaBaseURL: nil, explicitKey: key)
    } catch {
        exit(fail("\(error)"))
    }

    runAndExit {
        print("checking the key against \(backend.displayDescription)…")
        let verdict = await BrainKeyValidator().validate(backend)
        print(verdict.spokenDescription)
        guard verdict.isUsable else { return 1 }

        if arguments.contains("--save") {
            do {
                try ProviderKeyStore().save(key, forProvider: providerID)
                print("saved — the daemon will use it on its next start")
            } catch {
                return fail("could not save the key: \(error)")
            }
        } else {
            print("rerun with --save to keep it")
        }
        return 0
    }
}

/// Signs in to Google and, on request, provisions a Gemini key from it.
///
/// A command rather than a buried step because this is the one part of setup
/// that involves a browser, another company's consent screen and four chained
/// Google APIs — when it fails it must be runnable in isolation, with the
/// failure visible, rather than only reachable through a wizard.
func runGoogle(_ arguments: [String]) -> Never {
    let flags = parseFlags(arguments)
    guard let client = GoogleOAuthClient.fromEnvironment() else {
        exit(fail("""
        set GOOGLE_OAUTH_CLIENT_ID first (and GOOGLE_OAUTH_CLIENT_SECRET if your
        client is a "Desktop app" — Google issues one and its token endpoint
        usually wants it back, PKCE notwithstanding).
        """))
    }

    let store = GoogleTokenStore(url: GoogleTokenStore.defaultURL())
    let logger: @Sendable (String) -> Void = { print($0) }

    runAndExit {
        let credential = GoogleOAuthCredential(client: client, store: store)

        if arguments.contains("--sign-out") {
            await credential.signOut()
            print("signed out")
            return 0
        }

        if await !credential.isSignedIn {
            let session = GoogleSignInSession(client: client, store: store, log: logger)
            do {
                _ = try await session.signIn { url in
                    // The appliance is headless and the owner is elsewhere, so
                    // print the URL as well as trying to open it.
                    print("\nopen this to sign in:\n\(url.absoluteString)\n")
                    let open = Process()
                    open.executableURL = URL(fileURLWithPath: "/usr/bin/open")
                    open.arguments = [url.absoluteString]
                    try? open.run()
                }
            } catch {
                return fail("\(error)")
            }
        } else {
            print("already signed in")
        }

        guard arguments.contains("--provision") else {
            // Proves the token works without changing anything.
            do {
                _ = try await credential.authorizationHeaders()
                print("token ok — rerun with --provision to mint a Gemini key")
                return 0
            } catch {
                return fail("\(error)")
            }
        }

        let provisioner = GeminiKeyProvisioner(
            transport: GoogleAuthorizedTransport(credential: credential),
            log: logger
        )
        do {
            let key = try await provisioner.provision(preferredProjectID: flags["project"])
            // Deliberately not printed in full: it is a live credential and this
            // output lands in scrollback and log files.
            print("provisioned Gemini key \(key.prefix(6))…\(key.suffix(4)) (\(key.count) chars)")
            print("export GEMINI_API_KEY=… to use it, or let setup store it for you")
            return 0
        } catch {
            return fail("\(error)")
        }
    }
}

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
    // `parseFlags` only reads `--key value` pairs, so a bare switch has to be
    // looked for in the raw arguments.
    let (tools, notes) = makeToolSource(mcp: mcp, allowWeb: !arguments.contains("--no-web"))
    let loop = ToolLoop(backend: backend, mcp: tools)
    // Both of these are pure taste, and taste is only discoverable by living
    // with it on a phone. Exposing them as flags means retuning is a daemon
    // restart rather than a rebuild, a repackage, a resign and a redeploy.
    var daemonConfiguration = VoiceBridgeDaemon.Configuration()
    if let prefix = flags["reply-prefix"] {
        daemonConfiguration.replyPrefix = prefix
    }
    if arguments.contains("--acknowledge") {
        daemonConfiguration.sendsThinkingAcknowledgement = true
    }
    // Driven against the raw MCP client, not the composed catalogue: these are
    // SAGE's own boot tools, deliberately outside the model's allowlist.
    let daemon = VoiceBridgeDaemon(
        signal: signal,
        transcriber: transcriber,
        loop: loop,
        configuration: daemonConfiguration,
        ritual: arguments.contains("--no-sage-ritual")
            ? nil
            : SageRitual(
                tools: mcp,
                displayName: SageRitual.applianceDisplayName,
                log: { FileHandle.standardError.write(Data(($0 + "\n").utf8)) }
            ),
        notes: notes,
        conversations: ConversationStore(),
    )

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
case "search":      runSearch(Array(arguments.dropFirst()))
case "google":      runGoogle(Array(arguments.dropFirst()))
case "key":         runKey(Array(arguments.dropFirst()))
case "daemon":      runDaemon(Array(arguments.dropFirst()))
default:            usage()
}
