import Foundation

/// One tool catalogue assembled from several sources.
///
/// `ToolLoop` takes a single `ToolProviding`, which was right while SAGE's MCP
/// server was the only place tools came from. Web search is not an MCP server
/// and should not have to pretend to be one, so the loop's single seam becomes
/// a fan-in here rather than growing a second one.
///
/// Sources are consulted in order and the first to publish a name owns it.
/// SAGE goes first: if it ever ships its own `web_search`, the governed,
/// consensus-validated one wins over the bolted-on one, without a code change.
public final class CompositeToolSource: ToolProviding, @unchecked Sendable {

    public enum Failure: Error, CustomStringConvertible, Equatable {
        case unknownTool(String)
        case sourceContributedNothing(label: String, expected: [String], published: [String])

        public var description: String {
            switch self {
            case .unknownTool(let name):
                return "no tool source publishes \(name)"
            case .sourceContributedNothing(let label, let expected, let published):
                return """
                \(label) published \(published.count) tool(s), none of them recognised. \
                Refusing to run on a partial catalogue: the loop would look healthy while \
                silently missing everything this source was supposed to provide. \
                Expected any of: \(expected.sorted().joined(separator: ", ")). \
                Got: \(published.sorted().joined(separator: ", ")).
                """
            }
        }
    }

    public struct Source: Sendable {
        /// Used only in log lines, so a degraded source is nameable.
        public let label: String
        public let provider: ToolProviding
        /// Whether this source failing should fail the whole catalogue.
        ///
        /// SAGE is required — without memory there is no appliance. Web search
        /// is not: the owner's phone is a long way from their Mac mini, and
        /// "the internet lookup is down" must not read as "the agent is down".
        public let isRequired: Bool
        /// Names this source is expected to contribute at least one of.
        ///
        /// Guards a hole that opened the moment the catalogue stopped coming
        /// from one place. `ToolLoop`'s allowlist check fails closed only when
        /// *nothing* matches — and web search always matches, so a SAGE that
        /// renamed or re-prefixed every tool would sail past it and leave the
        /// model holding one tool and no memory, looking healthy. Empty means
        /// no expectation.
        public let expectedToolNames: Set<String>

        public init(
            label: String,
            provider: ToolProviding,
            isRequired: Bool,
            expectedToolNames: Set<String> = []
        ) {
            self.label = label
            self.provider = provider
            self.isRequired = isRequired
            self.expectedToolNames = expectedToolNames
        }
    }

    private let sources: [Source]
    private let log: @Sendable (String) -> Void
    private let lock = NSLock()
    private var routes: [String: ToolProviding] = [:]

    public init(sources: [Source], log: @escaping @Sendable (String) -> Void = { _ in }) {
        self.sources = sources
        self.log = log
    }

    public func listTools() async throws -> [MCPTool] {
        var merged: [MCPTool] = []
        var table: [String: ToolProviding] = [:]

        for source in sources {
            let tools: [MCPTool]
            do {
                tools = try await source.provider.listTools()
            } catch {
                guard !source.isRequired else { throw error }
                // Degrade, don't collapse. Losing search should cost the
                // appliance the internet, not its brain.
                log("[tools] \(source.label) unavailable, continuing without it: \(error)")
                continue
            }

            if !source.expectedToolNames.isEmpty,
               !tools.isEmpty,
               !tools.contains(where: { source.expectedToolNames.contains($0.name) }) {
                let failure = Failure.sourceContributedNothing(
                    label: source.label,
                    expected: Array(source.expectedToolNames),
                    published: tools.map(\.name)
                )
                guard !source.isRequired else { throw failure }
                log("[tools] \(failure)")
                continue
            }

            for tool in tools {
                guard table[tool.name] == nil else {
                    // Not silent: a shadowed tool means the model will never
                    // reach one of two implementations, and finding that out
                    // from behaviour alone is miserable.
                    log("[tools] \(source.label) publishes \(tool.name), already claimed by an earlier source — ignoring")
                    continue
                }
                table[tool.name] = source.provider
                merged.append(tool)
            }
        }

        withLock { routes = table }
        return merged
    }

    public func call(name: String, arguments: [String: JSONValue]) async throws -> String {
        if let provider = route(for: name) {
            return try await provider.call(name: name, arguments: arguments)
        }

        // Either nothing has listed yet, or a source grew a tool since we last
        // looked. One refresh, then give up — a model inventing tool names must
        // not be able to make us re-list on every turn.
        _ = try? await listTools()
        guard let provider = route(for: name) else {
            throw Failure.unknownTool(name)
        }
        return try await provider.call(name: name, arguments: arguments)
    }

    private func route(for name: String) -> ToolProviding? {
        withLock { routes[name] }
    }

    /// Scoped access to `routes`, for the reason spelled out on
    /// `MCPClient.withLock`: `NSLock` is `noasync`, and a non-async `body` makes
    /// it impossible to suspend while holding the lock.
    private func withLock<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }
}
