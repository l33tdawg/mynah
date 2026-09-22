import Foundation

/// `schedule_work`: the owner asking for something to happen on a clock, in
/// conversation.
///
/// **The owner, 22 September 2026: "it needs to be set up in the app itself then
/// its just available to the user in conversation bro."** He is right, and this
/// is the second half of it. `//schedule` shipped as a command because the
/// catalogue was at its measured ceiling and because a cadence a *model* invents
/// is a phone buzzing at the wrong hour for as long as the request stands. What
/// that decision got wrong is the part he is naming: the owner does not want to
/// learn a command to get something he asked for out loud.
///
/// So the tool exists now, and **it is a door into the same reader rather than a
/// second implementation.** `when` arrives in the owner's own words — "every day
/// at 8am" — and `ScheduledWorkCommand.cadence` reads it, refusing a bare hour
/// and returning the sentence that says what is missing. The model therefore
/// cannot invent a time, cannot normalise "at 8" to eight in the morning, and
/// cannot schedule anything the owner could not have typed himself: on an
/// unreadable phrase it gets the refusal back, and its job is to ask him for the
/// missing part. That is the property that made the command worth having in the
/// first place, kept while dropping the part the owner rejected.
///
/// ## What it is not
///
/// It does not run the work now. A request that means "do it once, in a minute"
/// is what the ordinary turn is for, and a tool that performed the work as well
/// as scheduling it would run it twice — once in this turn, once at the time.
/// It does not cancel or hold either: **the Mac's Scheduled screen is where work
/// is turned off or killed**, which is the other half of what he asked for, and
/// a 4B reaching for the right row of a numbered list it read a turn ago is a
/// worse interface than a switch he can see.
public struct ScheduledWorkToolSource: ToolProviding {

    /// Deliberately not a `sage_` name.
    ///
    /// Not a SAGE tool, and — the same reason `AfterTheCallToolSource` gives —
    /// a `sage_` prefix would be swept into `PromptNamesOnlyRealToolsTests`'
    /// regex as a claim about the node. It is published by this appliance and
    /// lives in the allowlist beside `web_search` and the note tools.
    public static let toolName = "schedule_work"

    private let fileURL: URL
    private let now: @Sendable () -> Date
    private let isPaused: @Sendable () -> Bool
    private let log: @Sendable (String) -> Void

    public init(
        fileURL: URL = ScheduledWork.defaultFileURL(),
        now: @escaping @Sendable () -> Date = { Date() },
        isPaused: @escaping @Sendable () -> Bool = { PauseState().isPaused() },
        log: @escaping @Sendable (String) -> Void = { _ in }
    ) {
        self.fileURL = fileURL
        self.now = now
        self.isPaused = isPaused
        self.log = log
    }

    // MARK: What the model is told

    public func listTools() async throws -> [MCPTool] {
        [
            MCPTool(
                name: Self.toolName,
                description: """
                Put something on a clock for the owner: from now on, Mynah does it \
                itself at that time and messages him the answer, whether or not he is \
                talking to you. Use it when he asks for something to happen every day, \
                on a day of the week, or every so often — "check my inbox every \
                morning", "send me the week ahead on Monday", "look every half hour". \
                Nothing happens now: this sets the time and the work, and the first one \
                the owner hears about is the first time it comes round. Stopping one is \
                not done here — he turns them off or kills them in Mynah's Scheduled \
                screen on the Mac, and you can tell him so.
                """,
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "when": .object([
                            "type": .string("string"),
                            "description": .string(
                                "When it should happen, in the owner's own words — \"every day at "
                                    + "8am\", \"every Monday at 9:30am\", \"every 30 minutes\", "
                                    + "\"hourly\". A time of day needs am/pm or a 24-hour clock: "
                                    + "\"at 8\" is refused, so ask him rather than guessing, and "
                                    + "the refusal tells you what to ask for."
                            )
                        ]),
                        "what": .object([
                            "type": .string("string"),
                            "description": .string(
                                "What to do when it comes round, in his words and as an "
                                    + "instruction to you — \"check my inbox and tell me what's "
                                    + "waiting\", \"send me the week ahead\"."
                            )
                        ])
                    ]),
                    "required": .array([.string("when"), .string("what")])
                ])
            )
        ]
    }

    // MARK: Doing it

    /// Never throws for anything the owner did.
    ///
    /// A tool that throws turns into a failed turn, and every refusal here has a
    /// sentence a person would rather hear — so they come back as results, in
    /// the shape `AfterTheCallToolSource` uses: upper case for what happened, a
    /// sentence for the owner, and an instruction for the model.
    public func call(name: String, arguments: [String: JSONValue]) async throws -> String {
        guard name == Self.toolName else { throw CompositeToolSource.Failure.unknownTool(name) }

        let when = (arguments["when"]?.stringValue ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let what = (arguments["what"]?.stringValue ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard !what.isEmpty else {
            log("[schedule] the model asked for standing work with no work in it")
            return "NOT SCHEDULED — you did not say what to do. Ask him what should happen when "
                + "it comes round, then call \(Self.toolName) again with it filled in."
        }
        guard !when.isEmpty else {
            log("[schedule] the model asked for standing work with no time in it")
            return "NOT SCHEDULED — you did not say when. \(ScheduledWorkCommand.needAWhen)"
        }

        switch ScheduledWorkCommand.cadence(in: when) {
        case .refused(let sentence):
            log("[schedule] the model asked for an unreadable cadence: \(when.prefix(60))")
            return "NOT SCHEDULED — \(sentence) Ask him for the part that is missing, then call "
                + "\(Self.toolName) again."
        case .read(let cadence):
            // The same call the command makes, so the two doors cannot drift:
            // the cap, the paused refusal and the file write are one code path.
            let answer = ScheduledWorkCommand.perform(
                .request(.create(instruction: what, cadence: cadence)),
                at: fileURL,
                now: now(),
                isPaused: isPaused()
            )
            guard answer.hasPrefix("Scheduled.") else {
                log("[schedule] standing work refused on the model's request: \(answer.prefix(80))")
                return "NOT SCHEDULED — \(answer)"
            }
            log("[schedule] the model set up standing work: \(cadence.spoken)")
            return """
                SCHEDULED. \(cadence.spoken.capitalisedFirst), from now on: “\(what)”.
                Tell him in one line that it is set up and that it will message him on its own \
                from then on. Do not do the work now.
                """
        }
    }
}
