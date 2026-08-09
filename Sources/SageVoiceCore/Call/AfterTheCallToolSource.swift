import Foundation

/// **The one tool a call gets instead of the four it used to have.**
///
/// Until now the call surface published `write_note`, `read_note`, `list_notes`
/// and `send_file` — the whole notes source — because `BrainPrompts
/// .voiceToolAllowlist` unions `NotesToolSource.toolNames` in and the call
/// builds its loop from that default. The design ruling this replaces assumed
/// the call already subtracted them. It never did: the only subtraction in the
/// tree is an `expectedToolNames` health check on the SAGE source, which
/// declares what that source should publish and has nothing to do with what the
/// model may call. So a call could send the owner a file mid-sentence, and the
/// ruling was a rule nothing enforced.
///
/// This publishes exactly one name. It records what was asked for and performs
/// nothing at all, which is what makes the promise honest: there is no code
/// path from here to a send.
public struct AfterTheCallToolSource: ToolProviding {

    public static let toolName = "after_the_call"

    /// Deliberately not a `sage_` name. It is not a SAGE tool, and a `sage_`
    /// prefix would be caught by `PromptNamesOnlyRealToolsTests`' regex and
    /// forced into the global `voiceToolAllowlist` — the one set that must not
    /// grow, because catalogue size is the dominant term in routing accuracy.
    private let queue: CallActionQueue
    private let log: @Sendable (String) -> Void

    public init(queue: CallActionQueue, log: @escaping @Sendable (String) -> Void = { _ in }) {
        self.queue = queue
        self.log = log
    }

    // MARK: - What the model is told

    public func listTools() async throws -> [MCPTool] {
        [
            MCPTool(
                name: Self.toolName,
                description: """
                Queue something to happen after the call ends. You are on a phone call and \
                nothing can be sent or produced while the line is open. Use this when the owner \
                asks you to send them a file, message another agent, or do a piece of work — \
                then tell them in one line that you will do it after you hang up. The results \
                arrive in the same chat that requested the call once it is over.
                """,
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        // One tool with an enum rather than three tools: the call
                        // catalogue grows by exactly one name. A call is always on
                        // a hosted brain — `BrainCapabilities.onDevice
                        // .holdsARealtimeCall` is false — so an enum is safe here
                        // in a way it would not be on a 4B model.
                        "kind": .object([
                            "type": .string("string"),
                            "enum": .array([
                                .string("send_file"),
                                .string("message_agent"),
                                .string("do"),
                                .string("forget")
                            ]),
                            "description": .string(
                                "send_file to send the owner a saved file. message_agent to send "
                                    + "another agent a message. do for a piece of work to carry out "
                                    + "afterwards. forget to cancel everything queued on this call "
                                    + "so far, when the owner changes their mind."
                            )
                        ]),
                        "what": .object([
                            "type": .string("string"),
                            "description": .string(
                                "For send_file, the file's title in the owner's own words. For "
                                    + "message_agent, the message to send. For do, what to carry "
                                    + "out, in one clear sentence. Leave out for forget."
                            )
                        ]),
                        "who": .object([
                            "type": .string("string"),
                            "description": .string(
                                "message_agent only: the agent's name as the owner said it."
                            )
                        ])
                    ]),
                    "required": .array([.string("kind")])
                ])
            )
        ]
    }

    // MARK: - Recording it

    public func call(name: String, arguments: [String: JSONValue]) async throws -> String {
        guard name == Self.toolName else { throw Trouble.unknownTool(name) }

        // Read the generation before anything else. A turn abandoned by
        // `withDeadline` still runs and still dispatches its tool calls, so the
        // question "which call was this asked on" has to be answered from the
        // turn's own task-local rather than from whatever call is open now.
        guard let generation = CallActionQueue.current else {
            log("[call] after_the_call was called outside a call turn; nothing queued")
            return Self.notOnACall
        }

        let kind = arguments["kind"]?.stringValue ?? ""
        let what = (arguments["what"]?.stringValue ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let who = arguments["who"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines)

        if kind == "forget" {
            let dropped = queue.forget(generation: generation)
            log("[call] the owner took back \(dropped) queued action(s)")
            return dropped == 0
                ? "NOTHING WAS QUEUED YET, so there is nothing to take back. Just answer them."
                : "TAKEN BACK. \(dropped) queued action(s) cancelled and none of them will happen. "
                    + "Tell them in one line that you have dropped it."
        }

        guard !what.isEmpty else {
            return "NOTHING WAS QUEUED — you did not say what to do. Ask them, then call "
                + "\(Self.toolName) again with it filled in."
        }

        let entryKind: CallActionQueue.Kind
        switch kind {
        case "send_file": entryKind = .file
        case "message_agent":
            guard let who, !who.isEmpty else {
                return "NOTHING WAS QUEUED — say who the message is for and call "
                    + "\(Self.toolName) again."
            }
            entryKind = .agent
        case "do": entryKind = .instruction
        default:
            return "NOTHING WAS QUEUED — \"\(kind)\" is not one of the kinds. Use send_file, "
                + "message_agent, do or forget."
        }

        guard queue.enqueue(
            generation: generation,
            kind: entryKind,
            what: what,
            who: who,
            asked: what
        ) != nil else {
            // The call this turn belonged to has already ended and its queue has
            // been claimed. This is the late orphan arriving, and the one thing
            // it must not do is tell the owner something was scheduled.
            log("[call] a turn from an ended call tried to queue something; refused")
            return Self.notOnACall
        }

        log("[call] queued for after the call: \(entryKind.rawValue) — \(what)")
        return Self.queued
    }

    // MARK: - The prose

    /// Written in `NotesToolSource.handBack`'s house style: say what did **not**
    /// happen first, then what to do. The failure this guards against is the
    /// model reporting the thing as done — which is the exact lie issue #21
    /// exists to end, and a model that has just called a tool successfully is
    /// strongly inclined to tell.
    static let queued = """
        QUEUED FOR AFTER THE CALL. Nothing has been sent and nothing has run — this happens once \
        the line drops, and the result lands in the chat that requested the call. Tell them in one line \
        that you will do it after you hang up, then stop. Do not say it is sent, attached, done, \
        or on its way.
        """

    static let notOnACall = """
        NOTHING WAS QUEUED — the call has already ended. Do not tell the owner anything was \
        scheduled, sent or done.
        """

    public enum Trouble: Error, Equatable {
        case unknownTool(String)
    }
}
