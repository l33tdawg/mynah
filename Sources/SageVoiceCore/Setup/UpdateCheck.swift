import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

// MARK: - A version two builds can be compared by

/// A release version, as numbers that can be ordered.
///
/// Not a string. `"1.10.0" < "1.9.0"` is true to a string comparison and false
/// to anybody holding the app, and getting that backwards means telling an owner
/// on the newest build that they are behind — or, worse, saying nothing to one
/// who is.
public struct ReleaseVersion: Sendable, Equatable, Comparable, CustomStringConvertible {

    public let major: Int
    public let minor: Int
    public let patch: Int

    /// What followed a `-` in the tag, empty when there was nothing.
    ///
    /// Kept because it changes the ordering: `1.1.0-beta.2` is a build on the
    /// way to `1.1.0`, not a build past it.
    public let prerelease: String

    public init(major: Int, minor: Int, patch: Int, prerelease: String = "") {
        self.major = major
        self.minor = minor
        self.patch = patch
        self.prerelease = prerelease
    }

    /// Reads a version out of whatever the tag happens to say.
    ///
    /// This project's own artefacts are already named three ways — the DMG is
    /// `Mynah-1.0.0-macOS-arm64.dmg`, the plist says `1.0.0`, and `v1.0.0` is
    /// what most repositories tag — and no release has been published yet, so
    /// the convention is not settled and this cannot assume one. The digits are
    /// found rather than expected at a known offset, and anything that is not a
    /// version is refused rather than guessed at: a tag this cannot read is
    /// reported as "could not check", never as agreement.
    public init?(tag: String) {
        guard let start = tag.firstIndex(where: { $0.isNumber }) else { return nil }
        let rest = tag[start...]
        let core = rest.prefix { $0.isNumber || $0 == "." }
        let suffix = rest.dropFirst(core.count)

        // Every component has to be a number this machine can hold. A partial
        // parse would silently shift `1.<huge>.3` into `1.3`, which compares as
        // a real version and is not one.
        let numbers = core.split(separator: ".").map { Int($0) }
        guard !numbers.isEmpty, numbers.allSatisfy({ $0 != nil }) else { return nil }
        let parts = numbers.compactMap { $0 }

        self.major = parts[0]
        // A tag written `1.0` means `1.0.0`. Padding here rather than at every
        // comparison keeps "is this newer" one question instead of two.
        self.minor = parts.count > 1 ? parts[1] : 0
        self.patch = parts.count > 2 ? parts[2] : 0

        // `-beta.2` counts; `+build7` is semver build metadata and explicitly
        // does not affect precedence, so it is dropped rather than compared.
        if suffix.hasPrefix("-") {
            self.prerelease = String(suffix.dropFirst().prefix { $0 != "+" })
        } else {
            self.prerelease = ""
        }
    }

    public var description: String {
        let core = "\(major).\(minor).\(patch)"
        return prerelease.isEmpty ? core : "\(core)-\(prerelease)"
    }

    public static func < (lhs: ReleaseVersion, rhs: ReleaseVersion) -> Bool {
        let left = [lhs.major, lhs.minor, lhs.patch]
        let right = [rhs.major, rhs.minor, rhs.patch]
        // Number by number, so 10 beats 9 rather than losing to it on the first
        // character. This is the whole reason the type exists.
        if left != right { return left.lexicographicallyPrecedes(right) }

        if lhs.prerelease == rhs.prerelease { return false }
        // A release outranks any prerelease of the same numbers, so somebody who
        // installed 1.1.0 is never offered the 1.1.0-beta.2 they left behind.
        if lhs.prerelease.isEmpty { return false }
        if rhs.prerelease.isEmpty { return true }
        // Two prereleases of the same version: text order. It is not semver's
        // full identifier rule, and the only thing it decides is which of two
        // betas is called newer, which nobody is shipping to an owner.
        return lhs.prerelease < rhs.prerelease
    }
}

// MARK: - What the check can honestly say

/// Why the check has nothing to report.
///
/// Every case here means "could not tell", and none of them means "up to date".
/// That distinction is the point of this type: an outage, a rate limit and a
/// repository with no published release all produce silence, and silence read as
/// agreement is how an owner ends up running an old build believing it is
/// current.
public enum UpdateCheckProblem: Sendable, Equatable {
    /// The owner turned the check off.
    case turnedOff
    /// Nothing came back — no network, DNS, a timeout.
    case noAnswer
    /// GitHub answered 404 — no release it will show us. Was the ordinary answer
    /// while the repository was private; since 1.2.0 it means a release is
    /// genuinely missing, so it is worth reading as "could not tell" either way.
    case notVisible
    /// GitHub is refusing for now.
    case rateLimited
    /// GitHub answered, with something other than a release.
    case serverProblem
    /// The body, or the tag inside it, was not something this could read.
    case unreadable
    /// The bundle does not say what version it is, so there is nothing to
    /// compare a release against.
    case unknownRunningVersion
    /// Within the day's interval, and no earlier check ever came back.
    case notCheckedYet

    /// One sentence for the owner. Nothing here is their fault and none of it
    /// asks them to do anything, because none of it is actionable.
    public var spokenDescription: String {
        switch self {
        case .turnedOff:
            return "Mynah isn't checking for new versions. You turned that off."
        case .noAnswer:
            return "Mynah couldn't reach GitHub, so it doesn't know whether there is a newer version."
        case .notVisible:
            return "GitHub didn't show Mynah any releases for this app. It does not mean you are "
                + "up to date."
        case .rateLimited:
            return "GitHub asked Mynah to check again later, so it doesn't know whether there is "
                + "a newer version."
        case .serverProblem:
            return "GitHub couldn't answer just now, so Mynah doesn't know whether there is a "
                + "newer version."
        case .unreadable:
            return "GitHub answered with something Mynah couldn't read, so it doesn't know "
                + "whether there is a newer version."
        case .unknownRunningVersion:
            return "Mynah can't tell which version it is running, so it has nothing to compare a "
                + "release against."
        case .notCheckedYet:
            return "Mynah hasn't managed to check yet, so it doesn't know whether there is a "
                + "newer version."
        }
    }
}

/// The three things the check can be sure of, kept apart on purpose.
public enum UpdateAvailability: Sendable, Equatable {
    /// Nothing newer has been released. Only ever returned after GitHub named a
    /// version that this build is at or past.
    case upToDate
    /// A newer release exists, and where to get it. Mynah does not fetch it —
    /// see `UpdateCheck` for why.
    case newer(version: String, page: URL)
    case cannotTell(UpdateCheckProblem)
}

// MARK: - What the owner chose about checking

/// The update preference and the clock behind it, where both processes can see
/// them.
///
/// A file rather than `UserDefaults`, for the reason spelled out on
/// `CallPreferences`: the app and the daemon are separate processes with
/// separate defaults domains, so a preference the Settings screen writes to its
/// own domain is one the daemon never reads. The control moves, the value is
/// stored, and nothing changes — which is worse than having no control, because
/// the owner has been told otherwise. That shipped once already.
///
/// This one is a privacy switch, which makes it the worst candidate for that
/// mistake: a checkbox that says "Mynah never contacts GitHub" while something
/// else on the machine keeps contacting GitHub is not a bug, it is a lie.
public struct UpdatePreferences: Sendable, Equatable, Codable {

    /// Whether Mynah may ask GitHub whether a newer version exists.
    ///
    /// On unless turned off. The owner asked for this check, and a privacy
    /// control that defaults to silence would leave them believing it runs. The
    /// screen states plainly what the request tells GitHub and the switch is
    /// beside that sentence.
    public var checksForUpdates: Bool

    /// When GitHub was last asked, whatever the answer was.
    ///
    /// Set on every attempt rather than every success, because this bounds how
    /// often the appliance reaches the network — not how often it gets a useful
    /// reply. An owner whose Mac was offline at the moment of the check is not a
    /// reason to ask GitHub again in a minute.
    public var lastCheckedAt: Date?

    /// The newest version GitHub named, the last time it named one.
    ///
    /// Remembered so the screen can still say "1.2.0 is out" on a launch where
    /// nothing is asked. Left alone by a failed check: a version that was real
    /// yesterday is still real today.
    public var lastSeenVersion: String?

    /// Where that release was, so the remembered answer can still be acted on.
    public var lastSeenPage: String?

    public init(
        checksForUpdates: Bool = true,
        lastCheckedAt: Date? = nil,
        lastSeenVersion: String? = nil,
        lastSeenPage: String? = nil
    ) {
        self.checksForUpdates = checksForUpdates
        self.lastCheckedAt = lastCheckedAt
        self.lastSeenVersion = lastSeenVersion
        self.lastSeenPage = lastSeenPage
    }

    public static func defaultFileURL(
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> URL {
        homeDirectory
            .appendingPathComponent("Library/Application Support/SAGE Voice Bridge", isDirectory: true)
            .appendingPathComponent("update-preferences.json", isDirectory: false)
    }

    /// Reads the owner's choice, or the defaults.
    ///
    /// Never throws. A file that will not parse should cost the owner a
    /// timestamp, not their settings screen.
    public static func load(from url: URL = UpdatePreferences.defaultFileURL()) -> UpdatePreferences {
        guard let data = try? Data(contentsOf: url),
              let stored = try? JSONDecoder().decode(UpdatePreferences.self, from: data) else {
            return UpdatePreferences()
        }
        return stored
    }

    public func save(to url: URL = UpdatePreferences.defaultFileURL()) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        try OwnerOnlyFileSecurity.write(encoder.encode(self), to: url)
    }

    /// Read, change, write — the one path that touches this file.
    ///
    /// The failure is swallowed deliberately. Nothing here is worth interrupting
    /// an appliance that is holding a call: the worst outcome of a lost write is
    /// that Mynah asks GitHub again sooner than it meant to.
    public static func amend(
        at url: URL = UpdatePreferences.defaultFileURL(),
        _ change: (inout UpdatePreferences) -> Void
    ) {
        var preferences = load(from: url)
        change(&preferences)
        try? preferences.save(to: url)
    }
}

// MARK: - The check

/// Asks GitHub whether a newer Mynah has been released, and says so.
///
/// It notices, tells, and links. It does not download and it does not install.
/// This appliance holds a live Signal connection and, during a call, an open
/// microphone; software that replaces its own binary underneath either of those
/// is a fault nobody would be able to explain afterwards. The owner is told a
/// version exists and given the page; when they replace it is their decision.
///
/// A 404 is treated as "cannot tell" and never as "nothing newer". That rule was
/// written when the repository was private, where 404 was the ordinary answer;
/// it is kept now that it is public, because 404 still cannot be distinguished
/// from a repository that does not exist, a release that was pulled, or a
/// rename. None of those mean the owner is current.
public struct UpdateCheck: Sendable {

    /// Where an owner goes to get a build. The one link that is offered when
    /// GitHub does not name a specific release.
    public static let releasesPage = URL(string: "https://github.com/l33tdawg/mynah/releases")!

    static let latestReleaseAPI = URL(
        string: "https://api.github.com/repos/l33tdawg/mynah/releases/latest"
    )!

    /// Every fifteen minutes.
    ///
    /// **It was once a day, and the owner never once saw an update offered.**
    /// The reasoning for a day was that every check is a third party being told
    /// this Mac is here, and a version released this morning can wait until the
    /// evening. Both true, and both beside the point: the appliance runs for
    /// days at a time, so a daily check meant a release could sit unnoticed for
    /// most of a day on a Mac that was awake and idle the whole time.
    ///
    /// Four requests an hour is well inside GitHub's unauthenticated limit of
    /// sixty, and the privacy switch above still turns the whole thing off. The
    /// *cost* of checking is one request that says nothing but "which release is
    /// latest"; the cost of not checking is the owner running an old build
    /// without knowing there is a newer one.
    ///
    /// Still not once a launch — a Mac that restarts five times in ten minutes
    /// would make five requests, and the elapsed-time check makes that one.
    public static let interval: TimeInterval = 15 * 60

    /// Short. Nothing waits on this call, but a request left open for a minute
    /// on a network that is dropping packets is a socket held for a minute for
    /// an answer nobody is looking at.
    static let timeout: TimeInterval = 10

    /// Sends the request and returns what came back, status included.
    ///
    /// The status is part of the result rather than an error, because 404 and
    /// 403 are the two answers this has to tell apart from success and from each
    /// other, and both are ordinary here.
    public protocol Transport: Sendable {
        func fetch(_ request: URLRequest) async throws -> (status: Int, body: Data)
    }

    private let runningVersion: String?
    private let transport: any Transport
    private let preferencesFile: URL
    private let now: @Sendable () -> Date

    public init(
        runningVersion: String? = UpdateCheck.bundleVersion(),
        transport: any Transport = GitHubReleaseTransport(),
        preferencesFile: URL = UpdatePreferences.defaultFileURL(),
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.runningVersion = runningVersion
        self.transport = transport
        self.preferencesFile = preferencesFile
        self.now = now
    }

    /// What this build says it is.
    ///
    /// The marketing version, not `CFBundleVersion`: the build number is
    /// monotonic and carries no relation to a release tag, so comparing it to
    /// one would be comparing two different numbering schemes.
    public static func bundleVersion(bundle: Bundle = .main) -> String? {
        bundle.infoDictionary?["CFBundleShortVersionString"] as? String
    }

    /// The answer, asking GitHub only if it is time to.
    ///
    /// Never throws and never blocks anything: callers run it beside the screen
    /// they are drawing, and every failure lands in `.cannotTell`.
    ///
    /// - Parameter force: ask now, whatever the daily limit and the switch say.
    ///   For the "Check now" button and nothing else.
    ///
    ///   Both guards below exist to stop the appliance contacting GitHub
    ///   *unprompted* — the daily limit so it does not pester, the switch so an
    ///   owner can stop it entirely. Neither is a statement about what should
    ///   happen when somebody presses a button asking the question themselves.
    ///
    ///   Without this, the first press of the day answers and every press after
    ///   it reports "hasn't managed to check yet", which reads as a broken
    ///   control rather than a rate limit; and with the daily check switched
    ///   off, the button would answer "you turned that off" — the app declining
    ///   to look because of a preference about *automatic* looking.
    public func run(force: Bool = false) async -> UpdateAvailability {
        let preferences = UpdatePreferences.load(from: preferencesFile)
        guard force || preferences.checksForUpdates else { return .cannotTell(.turnedOff) }

        // Before the network, not after. If this build cannot say what it is,
        // no answer from GitHub can be compared to it, and asking would be an
        // outbound request made for nothing.
        guard let running = runningVersion.flatMap(ReleaseVersion.init(tag:)) else {
            return .cannotTell(.unknownRunningVersion)
        }

        guard force || isDue(preferences) else { return remembered(preferences, running: running) }

        let answer = await ask()
        UpdatePreferences.amend(at: preferencesFile) { stored in
            stored.lastCheckedAt = now()
            if case .release(let version, let page) = answer {
                stored.lastSeenVersion = version.description
                stored.lastSeenPage = page.absoluteString
            }
        }

        switch answer {
        case .problem(let problem):
            return .cannotTell(problem)
        case .release(let version, let page):
            return verdict(latest: version, running: running, page: page)
        }
    }

    private func isDue(_ preferences: UpdatePreferences) -> Bool {
        guard let last = preferences.lastCheckedAt else { return true }
        // Also true when the stored date is in the future, which happens when
        // the Mac's clock is corrected backwards. Otherwise a machine that was
        // briefly set to next year would never check again.
        let elapsed = now().timeIntervalSince(last)
        return elapsed >= Self.interval || elapsed < 0
    }

    /// What the last successful check found, without asking again.
    private func remembered(
        _ preferences: UpdatePreferences,
        running: ReleaseVersion
    ) -> UpdateAvailability {
        guard let seen = preferences.lastSeenVersion,
              let version = ReleaseVersion(tag: seen) else {
            // Checked recently, learned nothing. Saying "up to date" here would
            // be inventing an answer out of a failed request.
            return .cannotTell(.notCheckedYet)
        }
        let page = preferences.lastSeenPage.flatMap(URL.init(string:)) ?? Self.releasesPage
        return verdict(latest: version, running: running, page: page)
    }

    private func verdict(
        latest: ReleaseVersion,
        running: ReleaseVersion,
        page: URL
    ) -> UpdateAvailability {
        // Strictly newer. A build ahead of the last published release — which is
        // every build made on this machine — is not behind, and must not be
        // offered a download that would take it backwards.
        latest > running ? .newer(version: latest.description, page: page) : .upToDate
    }

    // MARK: Asking

    private enum Answer {
        case release(ReleaseVersion, URL)
        case problem(UpdateCheckProblem)
    }

    private func ask() async -> Answer {
        var request = URLRequest(url: Self.latestReleaseAPI)
        request.httpMethod = "GET"
        request.timeoutInterval = Self.timeout
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        // GitHub rejects requests with no User-Agent outright. The name alone
        // and no version: the request already tells GitHub a Mac is asking, and
        // which build it is running is not something to volunteer on top.
        request.setValue("Mynah", forHTTPHeaderField: "User-Agent")

        let status: Int
        let body: Data
        do {
            (status, body) = try await transport.fetch(request)
        } catch {
            return .problem(.noAnswer)
        }

        switch status {
        case 200:
            break
        case 403, 429:
            // GitHub rate-limits unauthenticated callers by IP, so a household
            // behind one address can reach this without anybody doing anything
            // wrong.
            return .problem(.rateLimited)
        case 404:
            return .problem(.notVisible)
        default:
            return .problem(.serverProblem)
        }

        guard let payload = try? JSONDecoder().decode(Payload.self, from: body) else {
            return .problem(.unreadable)
        }
        // `tag_name` first, then the release's title. Tags are what this project
        // will version by, but nothing has enforced that yet and a title reading
        // "Mynah 1.2.0" is a better answer than none.
        guard let version = ReleaseVersion(tag: payload.tag_name ?? "")
                ?? ReleaseVersion(tag: payload.name ?? "") else {
            return .problem(.unreadable)
        }
        return .release(version, page(from: payload.html_url))
    }

    /// `/releases/latest`, which GitHub defines as excluding drafts and
    /// prereleases — so a beta pushed for one tester never becomes an update
    /// notice on the owner's Mac.
    private struct Payload: Decodable {
        let tag_name: String?
        let name: String?
        let html_url: String?
    }

    /// The download link, from the payload only when the payload's link is one
    /// this app would have built itself.
    ///
    /// This string arrives over the network and ends up handed to the browser,
    /// so it is checked rather than trusted: anything that is not an https URL
    /// on github.com falls back to the releases page, which is a link the owner
    /// can act on and is not attacker-chosen.
    private func page(from link: String?) -> URL {
        guard let link, let url = URL(string: link),
              url.scheme?.lowercased() == "https",
              let host = url.host?.lowercased(),
              host == "github.com" || host == "www.github.com" else {
            return Self.releasesPage
        }
        return url
    }
}

// MARK: - The real network

/// One GET, over a session that keeps nothing.
///
/// Ephemeral on purpose: no cookie store, no disk cache, nothing about this
/// request left on the Mac afterwards and nothing carried into the next one.
/// The whole feature is a privacy cost being spent deliberately, so it spends as
/// little as it can.
public struct GitHubReleaseTransport: UpdateCheck.Transport {

    public init() {}

    public func fetch(_ request: URLRequest) async throws -> (status: Int, body: Data) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = UpdateCheck.timeout
        configuration.httpCookieStorage = nil
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        let session = URLSession(configuration: configuration)
        defer { session.finishTasksAndInvalidate() }

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw URLError(.badServerResponse)
        }
        return (http.statusCode, data)
    }
}
