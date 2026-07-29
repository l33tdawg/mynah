import SageVoiceCore
import SwiftUI

// MARK: - Sending work to another agent
//
// The owner's framing: *"it's like an email system basically"*. This is the half
// that works today — `sage_find_agent` and `sage_pipe` need no grant, which is
// why messaging ships while the memory half is still waiting on an
// administrator.
//
// **The security shape is `voice`'s and it is designed to constrain this file.**
// Two rules fall out of it, and both are structural rather than remembered:
//
// 1. `AgentAddress` cannot be built from a `String` out here. The only way to
//    get one is `findAgent`, so the resolve is unskippable — a hand-built
//    address is the thing that silently reaches the wrong agent, or nobody.
// 2. `UntrustedAgentContent` is not a `String` and not `CustomStringConvertible`,
//    so `Text("\(content)")` renders a struct dump rather than a sentence that
//    looks like Mynah speaking. **This file never calls `read()`.** `forDisplay`
//    keeps attribution welded to the words, which is the whole point: a reply is
//    another agent's untrusted data, and the failure mode is not that it does
//    something — it is that it *looks like Mynah said it*.
//
// SAGE marks these payloads `authority:"request_only"` and results
// `authority:"data_only"`, and is explicit that they never gain system,
// developer or user authority. A view cannot enforce that. It can refuse to
// dress them up as Mynah, and that is what the drawing below is for.

@MainActor
@Observable
final class AgentMessagingModel {

    enum Sending: Equatable {
        case idle
        case resolving
        case sending
        /// Named rather than a bare success: the owner asked for a specific
        /// agent and the confirmation should say which one it reached, because
        /// resolving is the step that can quietly land elsewhere.
        case sent(to: String)
        case failed(String)
    }

    private(set) var sending: Sending = .idle
    private(set) var inbox: [AgentInboxItem] = []
    private(set) var inboxTrouble: String?
    /// Nil until the inbox has been asked once. A screen that has not looked
    /// must not draw "nothing waiting" — the same absence-as-answer mistake
    /// this codebase has spent a day removing.
    private(set) var hasCheckedInbox = false

    private let messaging: any AgentMessaging

    init(messaging: any AgentMessaging) {
        self.messaging = messaging
    }

    /// Resolve, then send. Two steps, reported separately, because they fail
    /// for different reasons and the owner can act on only one of them.
    func send(_ body: String, toAgentNamed name: String, intent: String?) async {
        let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        sending = .resolving
        let recipient: AgentAddress
        do {
            recipient = try await messaging.findAgent(named: name)
        } catch {
            sending = .failed(Self.sentence(for: error))
            return
        }

        sending = .sending
        do {
            _ = try await messaging.send(trimmed, to: recipient, intent: intent)
            sending = .sent(to: recipient.displayName)
        } catch {
            sending = .failed(Self.sentence(for: error))
        }
    }

    func resetSending() { sending = .idle }

    /// Asked when the owner looks, never on a timer — `AgentMessaging`'s own
    /// note, and the reason is that a background poll against a node that may
    /// refuse is a retry storm the owner generates by leaving a window open.
    func refreshInbox() async {
        do {
            inbox = try await messaging.inbox()
            inboxTrouble = nil
        } catch {
            // The previous contents stay on screen. A refresh that blanks the
            // list first makes a working inbox look like it emptied itself.
            inboxTrouble = Self.sentence(for: error)
        }
        hasCheckedInbox = true
    }

    /// `AgentMessagingTrouble` already writes owner-facing sentences with a
    /// next step in each. Anything else gets a plain one rather than a
    /// stringified error, which is somebody else's vocabulary.
    private static func sentence(for error: Error) -> String {
        (error as? AgentMessagingTrouble)?.errorDescription
            ?? "Mynah couldn't reach your SAGE node just then. Try again in a moment."
    }
}

// MARK: - Writing one

/// Compose sheet, opened from an agent's row.
///
/// The recipient is a *name taken from the roster* rather than something typed,
/// so the ordinary path cannot misspell an agent into `noSuchAgent`. It still
/// goes through `findAgent`, because the roster's display name and the wire
/// address are not the same thing and only the node can map between them.
struct AgentMessageSheet: View {

    let agentName: String
    let onClose: () -> Void

    @State private var body_ = ""
    @State private var intent = ""
    @Environment(\.self) private var environment

    var model: AgentMessagingModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: s2) {
                Text("Send \(agentName) a message")
                    .mynahFont(.title2)
                    .foregroundStyle(Palette.ink.primary)
                Text("It arrives in that agent's SAGE inbox. Whether it answers, and when, "
                    + "is up to it — nothing here waits for a reply.")
                    .mynahFont(.callout)
                    .foregroundStyle(Palette.ink.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, s7)
            .padding(.top, s7)
            .padding(.bottom, s5)

            VStack(alignment: .leading, spacing: s5) {
                // A plain editor, not a chat composer. This is a thing you
                // write and send once, and dressing it as a conversation would
                // promise a back-and-forth that does not exist.
                TextEditor(text: $body_)
                    .mynahFont(.body)
                    .scrollContentBackground(.hidden)
                    .padding(s4)
                    .frame(minHeight: 132, alignment: .topLeading)
                    .background(Palette.surface.well, in: RoundedRectangle.mynah(r.control))
                    .mynahBorder(r.control)

                SettingsRow(
                    "What kind of work",
                    detail: "Optional. A word like research or review, which tells the other "
                        + "agent what you want doing rather than leaving it to guess."
                ) {
                    TextField("", text: $intent)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 160)
                }
            }
            .padding(.horizontal, s7)

            outcome
                .padding(.horizontal, s7)
                .padding(.top, s5)

            Spacer(minLength: s6)
            MynahDivider()
            HStack(spacing: s4) {
                Spacer(minLength: 0)
                MynahButton("Close", kind: .quiet) { onClose() }
                MynahButton("Send", kind: .primary) {
                    Task {
                        await model.send(
                            body_,
                            toAgentNamed: agentName,
                            intent: intent.trimmingCharacters(in: .whitespaces).isEmpty
                                ? nil : intent
                        )
                    }
                }
                .disabled(body_.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isBusy)
            }
            .padding(.horizontal, s7)
            .padding(.vertical, s5)
        }
        .frame(width: 520, height: 460)
        .background(Palette.surface.canvas)
        .onDisappear { model.resetSending() }
    }

    private var isBusy: Bool {
        model.sending == .resolving || model.sending == .sending
    }

    @ViewBuilder
    private var outcome: some View {
        switch model.sending {
        case .idle:
            EmptyView()
        case .resolving:
            // Two words rather than one, because resolving is the step that can
            // fail in a way the owner has to fix — a name that matches nothing,
            // or matches two things.
            progress("Finding \(agentName)…")
        case .sending:
            progress("Sending…")
        case .sent(let name):
            // `.info`, and there is no green here on purpose. `state.good` in
            // this product means "your words stayed on this Mac" — see
            // `Palette.state` — and a message to another agent is the one thing
            // on this page that is emphatically not that. Borrowing the privacy
            // colour for "it worked" is the same over-signalling the amber
            // audit removed, in the other direction.
            InlineBanner(
                tone: .info,
                headline: "Sent to \(name).",
                explanation: "It's in their inbox. Anything they send back turns up under "
                    + "Waiting for you, on this page."
            )
        case .failed(let sentence):
            // Caution rather than critical: nothing is broken and nothing was
            // lost — the message is still in the box above and the owner can
            // fix the reason and press Send again.
            InlineBanner(tone: .caution, headline: "That didn't send.", explanation: sentence)
        }
    }

    private func progress(_ label: String) -> some View {
        HStack(spacing: s3) {
            ProgressView().controlSize(.small)
            Text(label).mynahFont(.label).foregroundStyle(Palette.ink.secondary)
        }
    }
}

// MARK: - Reading what came back

/// The inbox, drawn so another agent's words can never pass for Mynah's.
struct AgentInboxSection: View {

    var model: AgentMessagingModel

    var body: some View {
        VStack(alignment: .leading, spacing: s4) {
            Text("Waiting for you")
                .mynahFont(.eyebrow)
                .foregroundStyle(Palette.ink.secondary)
                .accessibilityAddTraits(.isHeader)

            if let trouble = model.inboxTrouble {
                // Secondary ink, not caution: this is a property of the view —
                // the inbox could not be read just now — and not a fault in the
                // appliance. See `Palette.state`.
                Text(trouble)
                    .mynahFont(.callout)
                    .foregroundStyle(Palette.ink.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else if !model.hasCheckedInbox {
                // Nothing at all until it has been asked once. "Nothing
                // waiting" before looking is an absence rendered as an answer.
                EmptyView()
            } else if model.inbox.isEmpty {
                Text("Nothing has come back yet.")
                    .mynahFont(.callout)
                    .foregroundStyle(Palette.ink.secondary)
            } else {
                ForEach(model.inbox) { item in
                    AgentInboxCard(item: item)
                }
            }
        }
    }
}

/// One message from another agent.
///
/// **Everything about this view exists to keep attribution welded to the text.**
/// The body is drawn from `forDisplay`, which is `"From <sender>\n\n<their
/// words>"` — a single string, so no later refactor can style the two halves
/// apart and lose one. `read()` is never called here. If a future version wants
/// the sender in a different font, the right move is to change `forDisplay`,
/// not to take the body out from under its label.
///
/// The trust line is drawn every time rather than only for foreign senders:
/// SAGE's reference is explicit that agents on the owner's *own* node are
/// untrusted too, and a caution that appears only sometimes teaches the owner
/// that its absence means safe.
private struct AgentInboxCard: View {
    let item: AgentInboxItem

    var body: some View {
        VStack(alignment: .leading, spacing: s3) {
            if let intent = item.intent {
                Text(intent.uppercased())
                    .mynahFont(.eyebrow)
                    .foregroundStyle(Palette.ink.tertiary)
            }

            if item.content.isEmpty {
                // A federated diagnostic notice carries no payload by design.
                // Saying so beats an empty card the owner reads as a rendering
                // bug.
                Text("\(item.content.attribution) — a notice with nothing in it.")
                    .mynahFont(.callout)
                    .foregroundStyle(Palette.ink.secondary)
            } else {
                Text(item.content.forDisplay)
                    .mynahFont(.body)
                    .foregroundStyle(Palette.ink.primary)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }

            Text(item.content.trust.caution)
                .mynahFont(.label)
                .foregroundStyle(Palette.ink.secondary)
        }
        .padding(s5)
        .frame(maxWidth: .infinity, alignment: .leading)
        // A well rather than a raised card: this is somebody else's text, and
        // it should read as quoted material rather than as another surface of
        // Mynah's own.
        .background(Palette.surface.well, in: RoundedRectangle.mynah(r.card))
        .mynahBorder(r.card)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(item.content.forDisplay). \(item.content.trust.caution)")
    }
}

// MARK: - The one signed connection

/// A `ToolProviding` that reaches the node as the appliance, lazily and once.
///
/// **There is exactly one of these because an `MCPClient` spawns a node child
/// process.** Two would be two `sage-gui mcp` processes answering as the same
/// identity, which is the shape that produced the ghost key — and the node
/// answers a second identity *emptily* rather than refusing, so nothing would
/// look broken. `SageMemoryStore.shared` already holds the connection the
/// memories screen uses; this borrows it rather than opening another.
///
/// It is a separate type rather than a direct reference so the borrowing is
/// visible: somebody adding a third caller sees one place to go through.
struct ApplianceTools: ToolProviding {
    static let shared = ApplianceTools()

    func listTools() async throws -> [MCPTool] {
        try await SageMemoryStore.shared.toolProvider().listTools()
    }

    func call(name: String, arguments: [String: JSONValue]) async throws -> String {
        try await SageMemoryStore.shared.toolProvider().call(name: name, arguments: arguments)
    }
}
