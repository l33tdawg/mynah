import Foundation

/// Where the owner is, so a place name means the place they mean.
///
/// **The problem, in the owner's words:** *"if you're in malaysia and say show
/// me restaurants near PJ - we are refering to PJ Malaysia - not some other
/// country"*. He is right, and it is not only PJ — Bangsar, TTDI, Subang and
/// half the places he says every day are ambiguous or meaningless to a model
/// that does not know which country it is standing in.
///
/// ## Two tiers, and the free one does most of the work
///
/// He asked for a public-IP lookup. That is tier two here rather than tier one,
/// and the reason is worth stating: **the operating system already knows the
/// country.** `TimeZone.current` is `Asia/Kuala_Lumpur`, which is not a guess,
/// costs nothing, needs no network, reveals nothing to anybody, and is correct
/// the instant the Mac boots — including on a plane, in a hotel, and behind a
/// VPN that would tell an IP service he is in Frankfurt.
///
/// Timezone gives the country and the region. That alone disambiguates "PJ",
/// which is the case he raised. What it cannot give is the city, and that is
/// what tier two is for: `city` is filled in by a lookup when one has
/// succeeded, and is simply absent when it has not.
///
/// So the country is always right and never costs anything, and the city is a
/// refinement that is allowed to fail. Nothing downstream may require the city.
public struct WhereWeAre: Codable, Equatable, Sendable {

    /// From the timezone. Always present.
    public var country: String
    /// The timezone's own name for the area — "Kuala Lumpur" for
    /// `Asia/Kuala_Lumpur`. Coarse, and right often enough to be worth saying.
    public var region: String?
    /// From a public-IP lookup, when one has worked. Absent otherwise, and
    /// nothing may depend on it.
    public var city: String?
    /// The zone this was derived from, so a move is detectable without asking
    /// anybody anything.
    public var timeZone: String
    public var checkedAt: Date?

    /// A day. Somebody who flies gets a corrected city within a day and a
    /// corrected country the moment macOS notices the zone change.
    public static let freshFor: TimeInterval = 24 * 60 * 60

    public func isFresh(now: Date = Date(), zone: TimeZone = .current) -> Bool {
        guard let checkedAt, timeZone == zone.identifier else { return false }
        return now.timeIntervalSince(checkedAt) < Self.freshFor
    }

    /// What the country and region are, from the zone alone.
    ///
    /// `Asia/Kuala_Lumpur` → country "Malaysia", region "Kuala Lumpur".
    /// Total: a zone this cannot read still yields the identifier itself rather
    /// than nothing, because "somewhere in Asia/Kuala_Lumpur" beats silence.
    public static func fromTimeZone(_ zone: TimeZone = .current, locale: Locale = .current) -> WhereWeAre {
        let identifier = zone.identifier
        let area = identifier.split(separator: "/").last.map {
            $0.replacingOccurrences(of: "_", with: " ")
        }
        // From the system region rather than a timezone-to-country table of our
        // own. A table here would be a copy that goes stale every time a border
        // or a daylight rule moves, and Foundation exposes no lookup in the
        // direction we want.
        //
        // The two can disagree — a US-region Mac carried to Malaysia reports
        // "United States" and `Asia/Kuala_Lumpur` — which is why the zone's own
        // area is kept alongside it rather than discarded. "Kuala Lumpur,
        // United States" reads oddly and is still enough for a model to place
        // "PJ" correctly, where either alone might not be.
        let country = locale.region.flatMap { locale.localizedString(forRegionCode: $0.identifier) }
        return WhereWeAre(
            country: country ?? area ?? identifier,
            region: area,
            city: nil,
            timeZone: identifier,
            checkedAt: nil
        )
    }

    /// One line for the model, or nil when there is nothing worth saying.
    ///
    /// Deliberately short. This rides alongside the boot context rather than
    /// inside `BrainPrompts.voiceAgentManager`, which has 73 characters of its
    /// measured 8,000 left — but prefill is paid either way, so it earns its
    /// length by naming the two things that change an answer: where an
    /// unqualified place name is, and what "near me" means.
    ///
    /// **The date is deliberately not in here**, though it was once. See
    /// `rightNow(_:zone:)`: this string goes in the system prompt, which is the
    /// prompt cache's prefix, and a fact that changes at midnight must not live
    /// in something a process holds for a week.
    public func spokenForPrompt() -> String? {
        let place = [city, region == city ? nil : region, country]
            .compactMap { $0 }
            .reduce(into: [String]()) { kept, part in
                if !kept.contains(part) { kept.append(part) }
            }
        guard !place.isEmpty else { return nil }

        return """
            WHERE YOU ARE
            \(place.joined(separator: ", ")). Unqualified place names are here \
            unless the owner says otherwise, and "near me" means here. Each turn \
            is stamped with the current date and time — work any day the owner \
            names out from that, never from a date you find in the conversation, \
            and write the full date down when you record something.
            """
    }

    /// The clock, stamped onto the turn being answered.
    ///
    /// ## Why this is not in the system prompt
    ///
    /// It was, and it never ran: `spokenForPrompt` was written to carry the date
    /// and nothing ever called it, so on 4 August 2026 the owner asked over
    /// Signal *"whats on our todo list today?"* and was answered for Monday the
    /// 3rd. Nothing in the prompt said otherwise, so the model took "today" from
    /// the only date in its context — a message the proactive watch had sent
    /// minutes earlier, naming the Monday task that had just come off the list.
    /// The window answered the same question correctly at the same minute, for
    /// the equally poor reason that the owner had typed "its already tuesday"
    /// into it an hour before. Neither surface knew; one was lucky.
    ///
    /// So it goes on the turn rather than in the prompt, and that placement is
    /// load-bearing twice over:
    ///
    /// 1. **It cannot go stale.** The daemon builds its prompt once and runs for
    ///    days. Any date baked in at boot is wrong by the following morning, and
    ///    wrong in the direction that is hardest to notice — confidently, in
    ///    prose, about a day that has passed.
    /// 2. **It costs no cache.** `anchorPromptCache` plants a checkpoint on
    ///    `[system] + history`, which is every message *except* the one the owner
    ///    has just sent. A per-minute string anywhere in that prefix invalidates
    ///    the checkpoint on every turn — measured at 11.4s of recomputation for
    ///    ten new tokens. Riding the owner's own message, it lands past the
    ///    checkpoint, in tokens that were going to be new anyway.
    ///
    /// Parenthesised because it is not the owner speaking, and short for the
    /// same reason.
    public static func rightNow(_ now: Date = Date(), zone: TimeZone = .current) -> String {
        let stamp = DateFormatter()
        stamp.timeZone = zone
        stamp.locale = Locale(identifier: "en_GB")
        stamp.dateFormat = "HH:mm 'on' EEEE d MMMM yyyy"
        return "(Right now it is \(stamp.string(from: now)).)"
    }

    /// The owner's words with the clock in front of them.
    ///
    /// One function so that every surface stamps turns identically, and so the
    /// test that proves a turn is stamped has a single thing to point at.
    public static func stamp(
        _ transcript: String,
        now: Date = Date(),
        zone: TimeZone = .current
    ) -> String {
        "\(rightNow(now, zone: zone))\n\n\(transcript)"
    }

    // MARK: On disk

    public static func defaultFileURL(
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> URL {
        homeDirectory
            .appendingPathComponent("Library/Application Support/SAGE Voice Bridge", isDirectory: true)
            .appendingPathComponent("where-we-are.json", isDirectory: false)
    }

    /// The cached answer, or the free one derived from the zone.
    ///
    /// Never nil and never a network call: a cache written in another country,
    /// or none at all, still yields a correct country from the current zone.
    public static func load(
        from url: URL = WhereWeAre.defaultFileURL(),
        zone: TimeZone = .current,
        now: Date = Date()
    ) -> WhereWeAre {
        let fresh = fromTimeZone(zone)
        guard let data = try? Data(contentsOf: url),
              let stored = try? JSONDecoder().decode(WhereWeAre.self, from: data),
              stored.timeZone == zone.identifier else {
            return fresh
        }
        // The zone still rules on country. A stored city from the same zone is
        // the only thing carried forward, because it is the only thing the zone
        // could not have told us.
        var merged = fresh
        merged.city = stored.city
        merged.checkedAt = stored.checkedAt
        return merged
    }

    public func save(to url: URL = WhereWeAre.defaultFileURL()) {
        guard let data = try? JSONEncoder().encode(self) else { return }
        try? OwnerOnlyFileSecurity.write(data, to: url)
    }
}
