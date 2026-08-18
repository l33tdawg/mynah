import Foundation

/// One tool catalogue assembled from several sources.
///
/// `ToolLoop` takes a single `ToolProviding`, which was right while SAGE's MCP
/// server was the only place tools came from. Web search is not an MCP server
/// and should not have to pretend to be one, so the loop's single seam becomes
/// a fan-in here rather than growing a second one.
///
/// Sources are consulted in order and the first to publish a name owns it.
/// SAGE goes first, so a memory tool can never be shadowed by something bolted
/// on later.
///
/// # Where curation lives, and why it moved here
///
/// **This used to be a health check and the real filtering happened in
/// `ToolLoop`.** `BrainPrompts.voiceToolAllowlist` was a single set applied to
/// the *composed* catalogue — which meant a tool this repository wrote itself
/// needed permission from a constant in `BrainPrompts` before the model could
/// see it. That set had to `.union(NotesToolSource.toolNames)` and hand-add
/// `WebSearchToolSource.toolName`, with a comment recording that leaving the
/// latter out "was a silent no-op for web search". Those unions were the list
/// admitting it was the wrong shape: it was never a permission list over the
/// appliance's own tools, it was a **curation of SAGE's 27 published tools**, a
/// catalogue this repository does not own and cannot shrink at the source.
///
/// So the rule, stated once and then made unrepresentable in the type:
///
/// > A source may self-declare its tools if and only if this repository
/// > implements it. Anything spawned as a child process must be curated, and
/// > the curation names live with that source.
///
/// `Source.inProcess` has no parameter to type a name list into, so a fourth
/// hand-maintained allowlist cannot be written by accident. `Source.external`
/// makes the curation mandatory, so a child process cannot smuggle a
/// twenty-eighth tool into the prompt by growing its own catalogue.
///
/// **One consequence, stated because it reverses a documented behaviour.** This
/// file used to promise that if SAGE ever shipped its own `web_search`, "the
/// governed, consensus-validated one wins over the bolted-on one, without a
/// code change". It no longer does automatically: a SAGE tool that is not in
/// its curation is not admitted, so it cannot claim the name. Getting the old
/// behaviour is one line — put `web_search` in `BrainPrompts.sageToolCuration`
/// — and that line is in the place where SAGE's catalogue is curated, which is
/// where somebody weighing the two implementations would look.
public final class CompositeToolSource: ToolProviding, @unchecked Sendable {

    public enum Failure: Error, CustomStringConvertible, Equatable {
        case unknownTool(String)
        /// A curated external source published nothing the curation names.
        ///
        /// **Fatal for a required source, and the reasoning below moved here
        /// verbatim from `ToolLoopError.toolAllowlistMatchedNothing`** when
        /// curation moved out of the loop. It is about SAGE's catalogue, so it
        /// now sits beside the SAGE source rather than two types away.
        ///
        /// Fail CLOSED. Silently widening to the whole catalogue is the worst
        /// possible response: routing accuracy roughly halves at 27 tools
        /// (measured 5-6/12 vs 12/12 on the curated set), so the model would be
        /// at its least reliable exactly when its blast radius is widest — and
        /// the widened set includes irreversible verbs like `sage_forget`,
        /// `sage_register` and the governance tools, driven by an ASR
        /// transcript that may contain mishearings.
        ///
        /// It also guards a hole that opened the moment the catalogue stopped
        /// coming from one place: the old loop-level check failed closed only
        /// when *nothing anywhere* matched, and web search always matched, so a
        /// SAGE that renamed or re-prefixed every tool would sail past it and
        /// leave the model holding one tool and no memory, looking healthy.
        case curationMatchedNothing(label: String, curated: [String], published: [String])
        /// A required in-process source published an empty catalogue.
        ///
        /// In-process sources have no curation to match against — they publish
        /// what they implement — so the only expectation left is that a
        /// required one publishes *something*. Notes and the after-the-call
        /// queue are required for the reason web search is not: they have no
        /// network to be down and no credential to expire, so an empty
        /// catalogue means the appliance itself is broken, and degrading
        /// quietly would hide it.
        case requiredSourcePublishedNothing(label: String)

        public var description: String {
            switch self {
            case .unknownTool(let name):
                return "no tool source publishes \(name)"
            case .curationMatchedNothing(let label, let curated, let published):
                return """
                None of the \(curated.count) curated tools are published by \(label). \
                Refusing to fall back to that source's full catalogue, because routing accuracy \
                roughly halves on the full set and it contains irreversible operations. \
                Expected any of: \(curated.sorted().joined(separator: ", ")). \
                Published: \(published.sorted().joined(separator: ", ")).
                """
            case .requiredSourcePublishedNothing(let label):
                return """
                \(label) is required and published no tools at all. Refusing to run on a partial \
                catalogue: the loop would look healthy while silently missing everything this \
                source was supposed to provide.
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
        /// The names admitted from this source, or `nil` for a source that
        /// self-declares.
        ///
        /// `nil` and "empty set" are deliberately different things and the
        /// factory methods are what keep them apart: `inProcess` cannot be
        /// given a set at all, and `external` cannot be built without one. An
        /// external source curated to the empty set would admit nothing, which
        /// is a registration nobody means to write; there is no way to express
        /// it because there is no way to reach this initialiser.
        public let curation: Set<String>?

        /// A source this repository implements, offered whole.
        ///
        /// Notes, web search, the after-the-call queue — and, when it lands, the
        /// skills loader. Their tools are admitted **because they publish
        /// them**: this repository wrote them deliberately and does not need
        /// permission from a list in `BrainPrompts` to offer what it built.
        ///
        /// There is no name parameter here on purpose. See the type's note on
        /// making the fourth allowlist unrepresentable rather than merely
        /// discouraged.
        public static func inProcess(
            label: String,
            provider: ToolProviding,
            isRequired: Bool
        ) -> Source {
            Source(label: label, provider: provider, isRequired: isRequired, curation: nil)
        }

        /// A source that is somebody else's program, admitted by name only.
        ///
        /// SAGE's MCP server publishes 27 tools and grows more between
        /// releases; an appliance that offered all of them would be handing a
        /// 4B model governance verbs and two known routing attractors. So the
        /// names are enumerated here, `curated` is not optional, and a tool the
        /// node adds tomorrow is not in the prompt tomorrow.
        ///
        /// The same shape serves an owner-added MCP server when that lands: the
        /// curation is whatever the owner ticked in preferences, passed in
        /// here, not a literal in `BrainPrompts`.
        public static func external(
            label: String,
            provider: ToolProviding,
            isRequired: Bool,
            curated: Set<String>
        ) -> Source {
            Source(label: label, provider: provider, isRequired: isRequired, curation: curated)
        }

        /// Private, so every registration goes through one of the two factories
        /// above and the in-process/external distinction cannot be sidestepped
        /// by writing the memberwise form.
        private init(
            label: String,
            provider: ToolProviding,
            isRequired: Bool,
            curation: Set<String>?
        ) {
            self.label = label
            self.provider = provider
            self.isRequired = isRequired
            self.curation = curation
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
            let published: [MCPTool]
            do {
                published = try await source.provider.listTools()
            } catch {
                guard !source.isRequired else { throw error }
                // Degrade, don't collapse. Losing search should cost the
                // appliance the internet, not its brain.
                log("[tools] \(source.label) unavailable, continuing without it: \(error)")
                continue
            }

            let admitted: [MCPTool]
            if let curation = source.curation {
                admitted = published.filter { curation.contains($0.name) }
                if admitted.isEmpty {
                    let failure = Failure.curationMatchedNothing(
                        label: source.label,
                        curated: Array(curation),
                        published: published.map(\.name)
                    )
                    guard !source.isRequired else { throw failure }
                    log("[tools] \(failure)")
                    continue
                }
            } else {
                admitted = published
                if admitted.isEmpty {
                    let failure = Failure.requiredSourcePublishedNothing(label: source.label)
                    guard !source.isRequired else { throw failure }
                    log("[tools] \(source.label) published nothing, continuing without it")
                    continue
                }
            }

            for tool in admitted {
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
        //
        // A curated name that did not survive the filter comes back as
        // `unknownTool` here, which is the point: curation is not cosmetic, it
        // is the routing table. A tool the model was never offered is a tool it
        // cannot reach by guessing the name.
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
