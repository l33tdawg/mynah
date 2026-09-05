import Foundation

/// One explicit-recording session. No greeting, synthesis, or spoken-call timers.
/// Submitted recordings belong to the chat queue and outlive this display connection.
public actor ScreenConversation {
    private let submitAudio: @Sendable (Data) async throws -> String
    private let deadline: TimeInterval
    private var turn: Task<Void, Never>?
    private let status: @Sendable () async -> String

    public init(
        submitAudio: @escaping @Sendable (Data) async throws -> String,
        deadline: TimeInterval = 300,
        status: @escaping @Sendable () async -> String = { "{}" }
    ) {
        self.submitAudio = submitAudio
        self.deadline = deadline
        self.status = status
    }

    public func run(reader: CallFrameReader, writer: CallFrameWriter) async {
        let updates = Task {
            var last = ""
            while !Task.isCancelled {
                let current = await status()
                if turn == nil, current != last {
                    last = current
                    try? await withoutBlockingTheActor { try writer.send(.screenStatus(current)) }
                }
                try? await Task.sleep(for: .seconds(1))
            }
        }
        defer { updates.cancel() }
        while !Task.isCancelled {
            guard let frame = try? await withoutBlockingTheActor({ try reader.next() }) else { return }
            switch frame {
            case .utterance(let wav):
                // The transport also gates turns. Refuse a confused peer without
                // cancelling or replacing work that may already have used tools.
                guard turn == nil else { continue }
                turn = Task { await respond(wav, writer: writer) }
            case .endCall:
                return
            default:
                continue
            }
        }
    }

    private func respond(_ wav: Data, writer: CallFrameWriter) async {
        defer { turn = nil }
        do {
            let submitAudio = self.submitAudio
            let reply = try await withDeadline(deadline, label: "glasses reply") {
                try await submitAudio(wav)
            }
            try? await withoutBlockingTheActor { try writer.send(.replyText(reply)) }
        } catch {
            guard !Task.isCancelled else { return }
            let message = error is DeadlineExceeded
                ? "Still waiting. Check notes-to-self before repeating the request; submitted work continues there."
                : "I couldn't answer that. Tap to try again."
            try? await withoutBlockingTheActor { try writer.send(.turnFailed(message)) }
        }
        guard !Task.isCancelled else { return }
        try? await withoutBlockingTheActor { try writer.send(.replyEnd) }
    }
}
