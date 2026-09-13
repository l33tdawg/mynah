import SwiftUI
import SageVoiceCore

/// Authorization is local to the Mac, like linking a messaging account.
struct GlassesPairingView: View {
    let channels: ChannelSelection
    @State private var pairing: GlassesPairingStore.Pairing?
    @State private var showingLink = false
    @State private var selected: ChannelKind = .signal
    @State private var error: String?
    @State private var isConfirmingUnpair = false
    private let store = GlassesPairingStore()

    private var recipients: [ChannelRecipient] {
        var result: [ChannelRecipient] = []
        if channels.includes(.signal), let number = SignalTooling.linkedNumber() {
            result.append(ChannelRecipient(kind: .signal, address: number))
        }
        if channels.includes(.whatsapp), let number = WhatsAppPairing.linkedNumber() {
            result.append(ChannelRecipient(kind: .whatsapp, address: number + "@s.whatsapp.net"))
        }
        return result
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            SettingsRow("Even G2 glasses", detail: pairing.map {
                "Authorized · conversations appear in \($0.recipient.kind.displayName)."
            } ?? "Pair the Mynah G2 companion to ask questions from your glasses.") {
                if pairing != nil {
                    HStack {
                        MynahButton("Pairing link", kind: .secondary) { showingLink = true }
                        MynahButton("Unpair", kind: .secondary) { isConfirmingUnpair = true }
                    }
                } else {
                    MynahButton("Pair G2", kind: .secondary) { authorize() }
                        .disabled(recipients.isEmpty)
                }
            }
            if pairing == nil {
                if recipients.count > 1 {
                    Picker("Send G2 conversations to", selection: $selected) {
                        ForEach(recipients, id: \.kind) { recipient in
                            Text(recipient.kind.displayName).tag(recipient.kind)
                        }
                    }
                    .pickerStyle(.segmented)
                } else if recipients.isEmpty {
                    Text("Link Signal or WhatsApp above to pair your glasses.")
                        .font(.callout).foregroundStyle(.secondary)
                }
            }
            if let error {
                Text(error).font(.callout).foregroundStyle(.red)
                if pairing == nil { Button("Remove unreadable pairing") { unpair() } }
            }
        }
        .task {
            while !Task.isCancelled {
                refresh()
                do { try await Task.sleep(for: .seconds(1)) } catch { break }
            }
        }
        // Asked before doing it, and on the one control that cannot be undone
        // from this screen. Unpair used to be a single tap: the row went
        // straight from "Authorized" to "Pair G2", the glasses stopped being
        // answered, and the only way back was the phone and a new link. The
        // destructive verb stays on the button rather than on "OK", so the
        // choice is readable without reading the sentence above it.
        .confirmationDialog(
            "Unpair Even G2 glasses?",
            isPresented: $isConfirmingUnpair,
            titleVisibility: .visible
        ) {
            Button("Unpair", role: .destructive) { unpair() }
            Button("Keep them paired", role: .cancel) { isConfirmingUnpair = false }
        } message: {
            Text("Mynah will stop answering this pairing and the companion on your phone "
                 + "will lose access. Your glasses and the other apps on them are untouched. "
                 + "Pairing again means opening the phone, copying a new link and pasting it "
                 + "into Mynah G2.")
        }
        .sheet(isPresented: $showingLink) {
            VStack(alignment: .leading, spacing: 20) {
                Text("Pair G2").font(.title2.bold())
                if let pairing {
                    let link = "\(CallHost.defaultRelay)/\(pairing.token)"
                    Text("Open Mynah G2 in the Even app on your phone, then paste this private pairing link. The companion remembers it and reconnects automatically.")
                    Text(link).font(.system(.body, design: .monospaced)).textSelection(.enabled)
                    Text("Keep Mynah running with phone answering enabled. The connection may take a few seconds. Keep this link private: it grants access to your Mynah.")
                        .font(.callout).foregroundStyle(.secondary)
                    HStack {
                        MynahButton("Copy pairing link", kind: .secondary) {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(link, forType: .string)
                        }
                        Spacer()
                        MynahButton("Done", kind: .secondary) { showingLink = false }
                    }
                } else {
                    Text("This pairing has been revoked.")
                    Button("Done") { showingLink = false }
                }
            }
            .padding(28).frame(width: 520)
        }
    }

    private func refresh() {
        do { pairing = try store.load() }
        catch { self.error = "The saved G2 pairing could not be read. Unpair it and try again." }
    }

    private func authorize() {
        guard let recipient = recipients.first(where: { $0.kind == selected }) ?? recipients.first else { return }
        do {
            let created = GlassesPairingStore.Pairing(token: CallInvitation.token(), recipient: recipient)
            try store.save(created)
            pairing = created; error = nil; showingLink = true
        } catch { self.error = "Mynah couldn't save the G2 pairing. Please try again." }
    }

    private func unpair() {
        do { try store.remove(); pairing = nil; error = nil; showingLink = false }
        catch { self.error = "Mynah couldn't revoke G2 access. Please try again." }
    }
}
