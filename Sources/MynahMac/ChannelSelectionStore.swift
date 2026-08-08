import Foundation
import SageVoiceCore

/// Which apps the owner wants to reach Mynah on, remembered between launches.
///
/// **The default is Signal, and it is a compatibility choice rather than a
/// preference.** Every Mac already running Mynah has a linked Signal number and
/// a LaunchAgent that answers it, and none of them has this key. An absent key
/// therefore has to mean exactly what those installs are already doing, or the
/// first launch of 2.0.0 would take the owner's phone bridge away and wait to be
/// told to put it back.
///
/// Stored as the comma-separated form `ChannelSelection(commaSeparated:)` parses,
/// not as an array or a bitfield, so the value in `defaults` is the same string
/// the daemon's `--channels` flag takes. One spelling, so a value written here
/// cannot mean something else to the process that has to act on it.
enum ChannelSelectionStore {

    static let key = "MynahEnabledChannels"
    static let whatsAppNumbersKey = "MynahWhatsAppNumbers"

    static func current(_ defaults: UserDefaults = .standard) -> ChannelSelection {
        guard let raw = defaults.string(forKey: key) else { return .signalOnly }
        // A stored value that will not parse is a corrupted or hand-edited
        // preference. Falling back to Signal keeps the appliance answering
        // rather than leaving it unreachable over a typo in a plist nobody
        // remembers editing.
        return (try? ChannelSelection(commaSeparated: raw)) ?? .signalOnly
    }

    static func save(_ selection: ChannelSelection, to defaults: UserDefaults = .standard) {
        defaults.set(
            ChannelKind.allCases.filter(selection.includes).map(\.rawValue).joined(separator: ","),
            forKey: key
        )
    }

    /// The WhatsApp numbers the appliance answers, in WhatsApp's own form.
    ///
    /// Derived from the linked Signal number by default: it is the same phone in
    /// the overwhelming majority of cases, and asking the owner to type a number
    /// the app already knows is a setup step that exists only to be got wrong.
    /// Stored separately the moment they say otherwise — the two accounts do come
    /// apart, and a derivation with no override is a wrong answer with no way to
    /// correct it.
    ///
    /// Returns `[]` when there is nothing to derive from, which
    /// `WhatsAppServiceConfiguration.inside` reads as "do not install the
    /// bridge": `bridge.js` with no allowlist refuses every message, so starting
    /// it would produce a helper that runs, looks healthy, and answers nothing.
    static func whatsAppNumbers(
        _ defaults: UserDefaults = .standard,
        signalAccount: String?,
        pairedSession: URL = WhatsAppPairing.defaultSessionDirectory()
    ) -> [String] {
        if let stored = defaults.string(forKey: whatsAppNumbersKey) {
            let numbers = normalise(stored.split(separator: ",").map(String.init))
            if !numbers.isEmpty { return numbers }
        }
        // **The account this Mac is actually logged into, ahead of the Signal
        // guess.** Pairing records the number, and on builds up to
        // 2.0.0-beta.4 it frequently did not — it read a field carrying the
        // owner's display name whenever they had set one. The session on disk
        // has held the JID the whole time, so reading it repairs those installs
        // on the next launch rather than sending the owner to unlink and scan
        // again.
        //
        // Ahead of `signalAccount` rather than behind it because it is not a
        // guess: it is the WhatsApp account this Mac is signed in as. The Signal
        // number is an assumption that the two are the same phone, which is
        // usually true and is why it stays as the last resort.
        if let paired = WhatsAppPairing.linkedNumber(sessionDirectory: pairedSession) {
            return normalise([paired])
        }
        guard let signalAccount else { return [] }
        return normalise([signalAccount])
    }

    static func saveWhatsAppNumbers(_ numbers: [String], to defaults: UserDefaults = .standard) {
        defaults.set(normalise(numbers).joined(separator: ","), forKey: whatsAppNumbersKey)
    }

    /// Digits only, country code first.
    ///
    /// A `+` here does not fail loudly — it fails as an allowlist entry that
    /// never matches, which is a bridge that quietly answers nobody. Stripping
    /// everything that is not a digit means a number typed the way a person
    /// writes one, `+60 12-382 1767`, is the same entry as `60123821767`.
    static func normalise(_ numbers: [String]) -> [String] {
        var seen: Set<String> = []
        var out: [String] = []
        for number in numbers {
            let digits = number.filter(\.isNumber)
            guard !digits.isEmpty, seen.insert(digits).inserted else { continue }
            out.append(digits)
        }
        return out
    }
}
