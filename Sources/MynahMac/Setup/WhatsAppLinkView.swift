import SwiftUI
import SageVoiceCore

/// The WhatsApp half of "signal or whatsapp or both".
///
/// Deliberately much smaller than `SignalLinkView`, and the difference is in the
/// protocol rather than in the effort. Signal's linking has a device name, a
/// code with a countdown the app has to run itself, an expiry the owner can hit,
/// and a helper that has to be told to finish. WhatsApp's has one moving part:
/// the bridge emits a code, replaces it when WhatsApp rotates it, and says
/// `connected` when the phone has scanned one. There is no state machine here
/// because there is no state machine there — inventing one would be a screen
/// modelling something the protocol does not have.
struct WhatsAppLinkSheet: View {

    let node: URL
    let bridge: URL
    /// Booted out before pairing and reconciled afterwards. Both come from the
    /// caller, so this view never reaches launchd itself.
    let stopBackgroundBridge: @Sendable () async -> Void
    let onLinked: () -> Void
    let onClose: () -> Void

    @State private var session: WhatsAppPairingSession?

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Link WhatsApp")
                    .mynahFont(.title2)
                Text("On your phone: WhatsApp → Settings → Linked Devices → Link a Device. "
                     + "Then point it at this square.")
                    .mynahFont(.body)
                    .foregroundStyle(Palette.ink.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                Spacer()
                square
                Spacer()
            }

            status

            HStack {
                Spacer()
                if case .linked(_, let jid) = session?.phase {
                    MynahButton("Done", kind: .primary) {
                        // **The account that was actually linked, recorded
                        // here.**
                        //
                        // `ChannelSelectionStore.saveWhatsAppNumbers` existed
                        // with no caller anywhere in the app, so the WhatsApp
                        // allowlist could only ever be the Signal number with
                        // its `+` stripped. An owner whose WhatsApp is on a
                        // different SIM — which this sheet never asks about —
                        // pairs successfully, sees "Linked", and is then refused
                        // by the bridge's own allowlist on every message he
                        // sends. Nothing on any screen says why.
                        //
                        // **`jid`, not the label.** This read the same string
                        // the line above shows, which is the push name whenever
                        // the owner has set one — so `number(inLinkedAccount:)`
                        // correctly refused to read a number out of "Dhillon"
                        // and stored nothing. Whether the appliance could answer
                        // WhatsApp then came down to whether they had ever set a
                        // display name.
                        //
                        // Invisible on a Mac with Signal linked, because the
                        // allowlist falls back to that number. On a WhatsApp-only
                        // Mac there is no fallback, so it is the difference
                        // between an appliance that starts and one that does not.
                        if let digits = Self.number(inLinkedAccount: jid) {
                            ChannelSelectionStore.saveWhatsAppNumbers([digits])
                        }
                        onLinked()
                        onClose()
                    }
                } else {
                    MynahButton("Cancel", kind: .secondary) {
                        session?.cancel()
                        onClose()
                    }
                }
            }
        }
        .padding(28)
        .frame(width: 420)
        .task {
            // Built here rather than in `init` so a sheet that is constructed
            // and never shown does not stop the owner's WhatsApp bridge.
            let started = WhatsAppPairingSession(node: node, bridge: bridge)
            session = started
            await started.start(stopBackgroundBridge: stopBackgroundBridge)
        }
        .onDisappear {
            // **The sheet closing has to stop the process.** Left running, it
            // keeps the session directory open, and the LaunchAgent this screen
            // booted out is about to be started again on top of it — two Baileys
            // writers on one auth state, which is the collision that silently
            // stops both ends decrypting.
            session?.cancel()
        }
    }

    /// The phone number out of what the bridge called the linked account.
    ///
    /// One parser, shared with the session-file fallback that repairs installs
    /// where this was never written — see `WhatsAppPairing.linkedNumber`. Two
    /// copies of "which digits in a JID are the account" is how one of them ends
    /// up including the device id.
    static func number(inLinkedAccount account: String?) -> String? {
        WhatsAppPairing.number(inJID: account)
    }

    @ViewBuilder
    private var square: some View {
        switch session?.phase {
        case .showing(let code):
            LinkCodeSquare(uri: code, appName: "WhatsApp")
        case .linked:
            LinkCodePlaceholder {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 44))
                    .foregroundStyle(Palette.state.good)
            }
        default:
            LinkCodePlaceholder {
                ProgressView().controlSize(.small)
            }
        }
    }

    @ViewBuilder
    private var status: some View {
        switch session?.phase {
        case .linked(let user, _):
            StatusLine(
                user.map { "Linked to \($0). Mynah answers the thread you send yourself." }
                    ?? "Linked. Mynah answers the thread you send yourself.",
                tone: .good
            )
        case .failed(let detail):
            // The detail is the bridge's own sentence where it had one. Every
            // failure this can show names something the owner can do next —
            // that rule is `Every dead end needs a door`, and a bare "pairing
            // failed" is the wall it exists to stop.
            InlineBanner(
                tone: .critical,
                headline: "WhatsApp was not linked",
                explanation: detail
            )
        case .showing:
            Text("The code changes every few seconds. Any of them works.")
                .mynahFont(.callout)
                .foregroundStyle(Palette.ink.tertiary)
        default:
            Text("Starting the WhatsApp helper…")
                .mynahFont(.callout)
                .foregroundStyle(Palette.ink.tertiary)
        }
    }
}
