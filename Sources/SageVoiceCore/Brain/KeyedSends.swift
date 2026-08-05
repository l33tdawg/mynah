import Foundation

/// Supplies the `idempotency_key` the model leaves out.
///
/// ## The defect
///
/// `sage_message_send` **requires** `idempotency_key`. Nothing in this codebase
/// supplied one on the path the model actually uses.
///
/// `SageAgentMessaging.send` does it properly — a fresh key per logical send,
/// journalled before the request — and has **no production call sites**. Only
/// `.inbox` is reached, through `SageProactiveSource.waitingMessages`. So
/// `AgentSendJournal` and its whole careful argument were unreachable, and every
/// real send came from the model calling the tool directly out of its
/// catalogue, where the key was its problem.
///
/// Which leaves a 4B inventing a uniqueness token. The two ways that goes wrong
/// are not symmetric and both are bad: omit it and the send hard-errors in front
/// of the owner, or reuse one — a model that has settled on `"1"` or on the
/// recipient's name will reuse it — and the second message *silently becomes the
/// first*. SAGE's own description is explicit that a repeated key "makes a retry
/// return the original message_id instead of creating a duplicate", so the node
/// answers success and nothing new arrives.
///
/// ## Why a decorator and not a prompt line
///
/// The same reasoning as `ScopedRecall`, which supplies the `domain` the model
/// omits: this is a property of the wire protocol rather than of the
/// conversation, and teaching a small model to generate a UUID per call is
/// asking it to be a random number generator between two sentences of the
/// owner's. The prompt is finite and every line in it costs routing accuracy.
///
/// **A key the model did supply is obeyed.** If it has said "this is a retry of
/// that", that is a real statement about intent and overriding it would turn a
/// deliberate retry into a duplicate — the exact failure this exists to avoid,
/// committed from the other side.
public struct KeyedSends: ToolProviding {

    public static let send = "sage_message_send"

    private let wrapped: ToolProviding
    private let journal: AgentSendJournal

    public init(wrapping wrapped: ToolProviding, journal: AgentSendJournal = AgentSendJournal()) {
        self.wrapped = wrapped
        self.journal = journal
    }

    public func listTools() async throws -> [MCPTool] {
        try await wrapped.listTools()
    }

    public func call(name: String, arguments: [String: JSONValue]) async throws -> String {
        guard name == Self.send, arguments["idempotency_key"] == nil else {
            return try await wrapped.call(name: name, arguments: arguments)
        }

        // Fresh per call, never derived from the message text. A content-derived
        // key would make two deliberate sends of the same sentence collide, and
        // the second would report success while nothing arrived — see
        // `AgentSendJournal` for the full argument.
        let key = AgentSendJournal.newKey()
        journal.starting(
            key: key,
            to: arguments["to"]?.stringValue ?? "unknown",
            message: arguments["payload"]?.stringValue ?? ""
        )

        var keyed = arguments
        keyed["idempotency_key"] = .string(key)
        let reply = try await wrapped.call(name: name, arguments: keyed)

        // Cleared only on an answer. A throw leaves the entry behind, which is
        // the whole diagnostic: an entry that outlives the process means a send
        // whose outcome this appliance never learned. Nothing resends it — see
        // `AgentSendJournal` on why replaying a queue after a crash is the wrong
        // recovery for a message the owner cannot see or stop.
        journal.finished(key: key)
        return reply
    }
}
