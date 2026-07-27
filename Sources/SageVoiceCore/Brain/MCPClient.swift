import Foundation

// MARK: - Errors

public enum MCPClientError: Error, CustomStringConvertible, Equatable {
    case missingExecutable(String)
    case launchFailed(String)
    case notStarted
    case serverExited(Int32, String)
    case timedOut(String, TimeInterval)
    case rpcError(Int, String)
    case malformedResponse(String)
    case toolFailed(String, String)

    public var description: String {
        switch self {
        case .missingExecutable(let path):
            return "MCP server executable is missing or not executable: \(path)"
        case .launchFailed(let detail):
            return "Could not launch MCP server: \(detail)"
        case .notStarted:
            return "MCP client is not started. Call start() first."
        case .serverExited(let status, let log):
            return "MCP server exited with status \(status). \(log)"
        case .timedOut(let method, let seconds):
            return "MCP request '\(method)' timed out after \(Int(seconds.rounded()))s."
        case .rpcError(let code, let message):
            return "MCP server returned JSON-RPC error \(code): \(message)"
        case .malformedResponse(let detail):
            return "MCP response could not be understood: \(detail)"
        case .toolFailed(let name, let detail):
            return "MCP tool '\(name)' failed: \(detail)"
        }
    }
}

// MARK: - Models

/// One entry from the server's `tools/list`.
public struct MCPTool: Sendable, Equatable {
    public var name: String
    public var description: String
    /// The server's raw JSON Schema for this tool's arguments.
    public var inputSchema: JSONValue

    public init(name: String, description: String, inputSchema: JSONValue) {
        self.name = name
        self.description = description
        self.inputSchema = inputSchema
    }

    /// The same tool, shaped for Ollama's `tools` array.
    ///
    /// The schema is passed through as the server published it — the whole
    /// point is that nothing about SAGE's 27 tools is hardcoded here.
    public var ollamaTool: OllamaTool {
        var parameters = inputSchema
        if parameters.objectValue == nil {
            parameters = .object(["type": .string("object"), "properties": .object([:])])
        }
        return OllamaTool(name: name, description: description, parameters: parameters)
    }
}

/// Identity the server sees during `initialize`.
public struct MCPClientInfo: Sendable, Equatable {
    public var name: String
    public var version: String
    /// MCP protocol revision to negotiate. SAGE's server speaks `2024-11-05`.
    public var protocolVersion: String

    public init(
        name: String = "sage-voice-bridge",
        version: String = "0.1.0",
        protocolVersion: String = "2024-11-05"
    ) {
        self.name = name
        self.version = version
        self.protocolVersion = protocolVersion
    }
}

/// What the server told us about itself during `initialize`.
public struct MCPServerInfo: Sendable, Equatable {
    public var name: String
    public var version: String
    public var protocolVersion: String
    /// Free-text operating instructions; SAGE returns a long brain primer here.
    public var instructions: String?

    public init(name: String, version: String, protocolVersion: String, instructions: String?) {
        self.name = name
        self.version = version
        self.protocolVersion = protocolVersion
        self.instructions = instructions
    }
}

// MARK: - Client

/// Minimal JSON-RPC 2.0 client for an MCP server spoken over stdio.
///
/// The server is a child process. Requests go out as newline-delimited JSON on
/// its stdin; responses come back the same way on stdout. Servers routinely
/// write banners and log lines to stderr — SAGE's prints
/// `INFO: Identity resolved via env var: ...` before it answers anything — so
/// stderr is drained into a bounded diagnostic buffer and never parsed. A line
/// on *stdout* that fails to parse as JSON is skipped rather than treated as a
/// protocol error, so a chatty server cannot poison the session.
public final class MCPClient: @unchecked Sendable {
    public static let defaultRequestTimeoutSeconds: TimeInterval = 90

    private let executableURL: URL
    private let arguments: [String]
    private let environment: [String: String]?
    private let workingDirectory: URL?
    private let requestTimeoutSeconds: TimeInterval
    private let clientInfo: MCPClientInfo

    private let stateLock = NSLock()
    private let writeQueue = DispatchQueue(label: "sage.mcp.stdin")

    private var process: Process?
    private var stdinHandle: FileHandle?
    /// Retained so teardown can clear their readabilityHandlers before the
    /// Process (and therefore the Pipes that own them) is released. Without
    /// this, a dispatch source can be inside `handle.availableData` when the
    /// handle is deallocated, which raises an ObjC exception Swift cannot catch.
    private var stdoutHandle: FileHandle?
    private var stderrHandle: FileHandle?
    /// De-duplicates concurrent `start()` calls. Without it, two callers racing
    /// at daemon boot — e.g. the catalogue hoist and the auto-connect primer —
    /// both see `handshakeInfo == nil`, both spawn (the second is a no-op), and
    /// both send `initialize` down the same stdin.
    private var startTask: Task<MCPServerInfo, Error>?
    private var pending: [Int: CheckedContinuation<JSONValue, Error>] = [:]
    private var nextRequestID = 1
    private var stdoutBuffer = Data()
    private var stderrTail = Data()
    private var handshakeInfo: MCPServerInfo?
    private var cachedTools: [MCPTool]?

    /// Keep the last few KB of stderr so a crash produces a usable message.
    private static let maxStderrTailBytes = 8 * 1024
    /// Refuse to buffer an unbounded stdout line; a runaway server should fail
    /// loudly rather than exhaust memory.
    private static let maxStdoutBufferBytes = 32 * 1024 * 1024

    public init(
        executableURL: URL,
        arguments: [String] = ["mcp"],
        environment: [String: String]? = nil,
        workingDirectory: URL? = nil,
        requestTimeoutSeconds: TimeInterval = MCPClient.defaultRequestTimeoutSeconds,
        clientInfo: MCPClientInfo = MCPClientInfo()
    ) {
        self.executableURL = executableURL
        self.arguments = arguments
        self.environment = environment
        self.workingDirectory = workingDirectory
        self.requestTimeoutSeconds = requestTimeoutSeconds
        self.clientInfo = clientInfo
    }

    deinit {
        stop()
    }

    public var isRunning: Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return process?.isRunning == true
    }

    /// Server identity, available after `start()`.
    public var serverInfo: MCPServerInfo? {
        stateLock.lock()
        defer { stateLock.unlock() }
        return handshakeInfo
    }

    /// Most recent stderr output from the child, for diagnostics.
    public var stderrLog: String {
        stateLock.lock()
        let data = stderrTail
        stateLock.unlock()
        return String(decoding: data, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: Lifecycle

    /// Spawns the server and performs the `initialize` /
    /// `notifications/initialized` handshake. Safe to call twice; the second
    /// call is a no-op while the child is still alive.
    @discardableResult
    public func start() async throws -> MCPServerInfo {
        if let existing = serverInfo, isRunning {
            return existing
        }

        // Single-flight: concurrent callers await the same handshake rather than
        // each sending their own `initialize` on the shared stdin.
        stateLock.lock()
        if let inFlight = startTask {
            stateLock.unlock()
            return try await inFlight.value
        }
        let task = Task<MCPServerInfo, Error> { [weak self] in
            guard let self else { throw MCPClientError.serverExited(-1, "client deallocated") }
            return try await self.performHandshake()
        }
        startTask = task
        stateLock.unlock()

        defer {
            stateLock.lock()
            if startTask == task { startTask = nil }
            stateLock.unlock()
        }
        return try await task.value
    }

    private func performHandshake() async throws -> MCPServerInfo {
        try spawn()

        let result = try await send(
            method: "initialize",
            params: .object([
                "protocolVersion": .string(clientInfo.protocolVersion),
                "capabilities": .object([:]),
                "clientInfo": .object([
                    "name": .string(clientInfo.name),
                    "version": .string(clientInfo.version)
                ])
            ])
        )

        let info = MCPServerInfo(
            name: result["serverInfo"]?["name"]?.stringValue ?? "unknown",
            version: result["serverInfo"]?["version"]?.stringValue ?? "unknown",
            protocolVersion: result["protocolVersion"]?.stringValue ?? clientInfo.protocolVersion,
            instructions: result["instructions"]?.stringValue
        )

        // Notification: no id, so the server sends nothing back.
        try notify(method: "notifications/initialized", params: .object([:]))

        stateLock.lock()
        handshakeInfo = info
        stateLock.unlock()
        return info
    }

    /// Terminates the child process and fails any in-flight requests.
    public func stop() {
        stateLock.lock()
        let runningProcess = process
        let stdin = stdinHandle
        let stdout = stdoutHandle
        let stderr = stderrHandle
        let inFlight = pending
        process = nil
        stdinHandle = nil
        stdoutHandle = nil
        stderrHandle = nil
        startTask = nil
        pending = [:]
        handshakeInfo = nil
        cachedTools = nil
        stateLock.unlock()

        // Detach the readability handlers BEFORE releasing the Process. The
        // Pipes (and their read FileHandles) are owned solely by the Process,
        // so dropping the last reference while a dispatch source is inside
        // `availableData` deallocates the handle mid-read — an ObjC exception
        // Swift cannot catch, which crashes the daemon on shutdown.
        stdout?.readabilityHandler = nil
        stderr?.readabilityHandler = nil

        try? stdin?.close()

        if runningProcess?.isRunning == true {
            runningProcess?.terminate()  // SIGTERM

            // sage-gui is a Go binary and may trap SIGTERM for graceful
            // shutdown. Without a bounded wait plus SIGKILL it can outlive the
            // daemon and hold the SAGE home directory open across a launchd
            // restart. Poll rather than waitUntilExit() so we cannot hang here.
            let deadline = Date().addingTimeInterval(Self.terminationGraceSeconds)
            while runningProcess?.isRunning == true, Date() < deadline {
                Thread.sleep(forTimeInterval: 0.05)
            }
            if runningProcess?.isRunning == true, let pid = runningProcess?.processIdentifier {
                kill(pid, SIGKILL)
            }
        }

        for continuation in inFlight.values {
            continuation.resume(throwing: MCPClientError.serverExited(-1, "client stopped"))
        }
    }

    /// How long to let the child exit on SIGTERM before escalating to SIGKILL.
    private static let terminationGraceSeconds: TimeInterval = 2.0

    // MARK: Public API

    /// The server's tool catalogue. Cached after the first call.
    public func listTools(useCache: Bool = true) async throws -> [MCPTool] {
        if useCache {
            stateLock.lock()
            let cached = cachedTools
            stateLock.unlock()
            if let cached {
                return cached
            }
        }

        try await ensureStarted()
        let result = try await send(method: "tools/list", params: .object([:]))
        guard let entries = result["tools"]?.arrayValue else {
            throw MCPClientError.malformedResponse("tools/list had no tools array")
        }
        let tools: [MCPTool] = entries.compactMap { entry in
            guard let name = entry["name"]?.stringValue, !name.isEmpty else {
                return nil
            }
            return MCPTool(
                name: name,
                description: entry["description"]?.stringValue ?? "",
                inputSchema: entry["inputSchema"] ?? .object(["type": .string("object")])
            )
        }

        stateLock.lock()
        cachedTools = tools
        stateLock.unlock()
        return tools
    }

    /// Invokes a tool and returns its text content, joined by newlines.
    ///
    /// Throws `MCPClientError.toolFailed` when the server sets `isError`, so a
    /// tool that refuses is distinguishable from a transport failure.
    public func call(name: String, arguments: [String: JSONValue]) async throws -> String {
        try await ensureStarted()
        let result = try await send(
            method: "tools/call",
            params: .object([
                "name": .string(name),
                "arguments": .object(arguments)
            ])
        )

        let text = Self.textContent(of: result)
        if result["isError"]?.boolValue == true {
            throw MCPClientError.toolFailed(name, text.isEmpty ? "no detail" : text)
        }
        return text
    }

    /// Convenience overload for callers holding a decoded JSON object.
    public func call(name: String, arguments: JSONValue) async throws -> String {
        try await call(name: name, arguments: arguments.objectValue ?? [:])
    }

    /// Flattens an MCP `content` array into plain text.
    /// Exposed for unit-testing content flattening without a live server.
    public static func textContent(of result: JSONValue) -> String {
        guard let content = result["content"]?.arrayValue else {
            // Some servers answer with a bare string or a structured result.
            if let text = result["content"]?.stringValue {
                return text
            }
            return result.isNull ? "" : result.jsonString()
        }
        let parts = content.compactMap { item -> String? in
            if let text = item["text"]?.stringValue {
                return text
            }
            if item["type"]?.stringValue == "resource",
               let text = item["resource"]?["text"]?.stringValue {
                return text
            }
            return nil
        }
        return parts.joined(separator: "\n")
    }

    // MARK: Transport

    private func ensureStarted() async throws {
        if serverInfo != nil, isRunning {
            return
        }
        try await start()
    }

    private func spawn() throws {
        stateLock.lock()
        defer { stateLock.unlock() }

        if let process, process.isRunning {
            return
        }
        guard FileManager.default.isExecutableFile(atPath: executableURL.path) else {
            throw MCPClientError.missingExecutable(executableURL.path)
        }

        let process = Process()
        process.executableURL = executableURL
        process.arguments = arguments
        if let environment {
            // Merge over the parent environment so PATH/HOME survive.
            process.environment = ProcessInfo.processInfo.environment.merging(environment) { _, new in new }
        }
        if let workingDirectory {
            process.currentDirectoryURL = workingDirectory
        }

        let stdinPipe = Pipe()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        stdoutPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let chunk = handle.availableData
            guard !chunk.isEmpty else {
                handle.readabilityHandler = nil
                return
            }
            self?.ingestStdout(chunk)
        }
        stderrPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let chunk = handle.availableData
            guard !chunk.isEmpty else {
                handle.readabilityHandler = nil
                return
            }
            self?.ingestStderr(chunk)
        }
        process.terminationHandler = { [weak self] finished in
            self?.handleTermination(status: finished.terminationStatus)
        }

        do {
            try process.run()
        } catch {
            throw MCPClientError.launchFailed(String(describing: error))
        }

        try? stdinHandle?.close()
        self.process = process
        stdinHandle = stdinPipe.fileHandleForWriting
        stdoutHandle = stdoutPipe.fileHandleForReading
        stderrHandle = stderrPipe.fileHandleForReading
        stdoutBuffer = Data()
    }

    /// Splits the stdout stream on newlines and routes each complete JSON frame.
    private func ingestStdout(_ chunk: Data) {
        var completed: [(CheckedContinuation<JSONValue, Error>, Result<JSONValue, Error>)] = []

        stateLock.lock()
        stdoutBuffer.append(chunk)
        if stdoutBuffer.count > Self.maxStdoutBufferBytes {
            stdoutBuffer.removeAll(keepingCapacity: false)
            stateLock.unlock()
            return
        }
        while let newlineIndex = stdoutBuffer.firstIndex(of: UInt8(ascii: "\n")) {
            let line = stdoutBuffer[stdoutBuffer.startIndex..<newlineIndex]
            let frameData = Data(line)
            stdoutBuffer.removeSubrange(stdoutBuffer.startIndex...newlineIndex)
            guard !frameData.isEmpty,
                  let frame = JSONValue.parse(frameData),
                  let object = frame.objectValue else {
                // Not JSON — a server that leaked a log line to stdout. Skip it
                // rather than tearing down the session.
                continue
            }
            guard let id = object["id"]?.intValue else {
                // Server-initiated notification; nothing to correlate.
                continue
            }
            guard let continuation = pending.removeValue(forKey: id) else {
                continue
            }
            if let rpcError = object["error"]?.objectValue {
                let code = rpcError["code"]?.intValue ?? -1
                let message = rpcError["message"]?.stringValue ?? JSONValue.object(rpcError).jsonString()
                completed.append((continuation, .failure(MCPClientError.rpcError(code, message))))
            } else {
                completed.append((continuation, .success(object["result"] ?? .null)))
            }
        }
        stateLock.unlock()

        for (continuation, outcome) in completed {
            continuation.resume(with: outcome)
        }
    }

    private func ingestStderr(_ chunk: Data) {
        stateLock.lock()
        stderrTail.append(chunk)
        if stderrTail.count > Self.maxStderrTailBytes {
            stderrTail.removeFirst(stderrTail.count - Self.maxStderrTailBytes)
        }
        stateLock.unlock()
    }

    private func handleTermination(status: Int32) {
        stateLock.lock()
        let inFlight = pending
        pending = [:]
        let tail = String(decoding: stderrTail, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        handshakeInfo = nil
        stateLock.unlock()

        guard !inFlight.isEmpty else {
            return
        }
        let detail = tail.isEmpty ? "No stderr output." : "Recent stderr: \(tail)"
        for continuation in inFlight.values {
            continuation.resume(throwing: MCPClientError.serverExited(status, detail))
        }
    }

    private func send(method: String, params: JSONValue) async throws -> JSONValue {
        let id = try withLock { () -> Int in
            guard process?.isRunning == true else {
                throw MCPClientError.notStarted
            }
            let id = nextRequestID
            nextRequestID += 1
            return id
        }

        let frame = JSONValue.object([
            "jsonrpc": .string("2.0"),
            "id": .int(id),
            "method": .string(method),
            "params": params
        ])

        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<JSONValue, Error>) in
            stateLock.lock()
            pending[id] = continuation
            let handle = stdinHandle
            stateLock.unlock()

            guard let handle else {
                failPending(id: id, with: MCPClientError.notStarted)
                return
            }

            scheduleTimeout(id: id, method: method)

            writeQueue.async { [weak self] in
                guard let self else { return }
                var data = Data(frame.jsonString().utf8)
                data.append(UInt8(ascii: "\n"))
                do {
                    try handle.write(contentsOf: data)
                } catch {
                    self.failPending(
                        id: id,
                        with: MCPClientError.launchFailed("write to server stdin failed: \(error)")
                    )
                }
            }
        }
    }

    private func notify(method: String, params: JSONValue) throws {
        let handle = try withLock { () -> FileHandle in
            guard process?.isRunning == true, let stdinHandle else {
                throw MCPClientError.notStarted
            }
            return stdinHandle
        }
        let frame = JSONValue.object([
            "jsonrpc": .string("2.0"),
            "method": .string(method),
            "params": params
        ])
        writeQueue.async {
            var data = Data(frame.jsonString().utf8)
            data.append(UInt8(ascii: "\n"))
            try? handle.write(contentsOf: data)
        }
    }

    private func scheduleTimeout(id: Int, method: String) {
        let seconds = requestTimeoutSeconds
        guard seconds > 0 else { return }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + seconds) { [weak self] in
            self?.failPending(id: id, with: MCPClientError.timedOut(method, seconds))
        }
    }

    private func failPending(id: Int, with error: Error) {
        stateLock.lock()
        let continuation = pending.removeValue(forKey: id)
        stateLock.unlock()
        continuation?.resume(throwing: error)
    }

    private func withLock<T>(_ body: () throws -> T) rethrows -> T {
        stateLock.lock()
        defer { stateLock.unlock() }
        return try body()
    }
}
