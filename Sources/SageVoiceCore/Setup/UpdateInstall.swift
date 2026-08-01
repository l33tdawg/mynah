import Foundation

// MARK: - How much of it has arrived

/// Bytes in and bytes expected — the only two numbers a download can honestly
/// report.
public struct UpdateTransfer: Sendable, Equatable {

    public let received: Int64

    /// `nil` when the server sent no length. A bar that invents a total runs to
    /// 100% and then keeps going, which tells the owner less than no bar at all.
    public let expected: Int64?

    public init(received: Int64, expected: Int64?) {
        self.received = max(0, received)
        self.expected = (expected ?? 0) > 0 ? expected : nil
    }

    public var fraction: Double? {
        guard let expected else { return nil }
        return min(max(Double(received) / Double(expected), 0), 1)
    }

    /// "246.1 MB of 555.4 MB", or just the first half when the size was never
    /// given. Megabytes rather than a percentage because a stalled download at
    /// 41% and a moving one at 41% look identical; the byte count moves.
    public var spokenDescription: String {
        guard let expected else { return Self.size(received) }
        return "\(Self.size(received)) of \(Self.size(expected))"
    }

    static func size(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: max(0, bytes), countStyle: .file)
    }
}

// MARK: - What it is doing

/// The four things that happen, in the order they happen.
///
/// Ordered and `Comparable` so a screen can draw the whole list at once and tick
/// off what is behind it. An owner watching 555 MB arrive wants to know what
/// else is coming — particularly that their copy is not touched until after the
/// signature has been checked.
public enum UpdateInstallStage: Int, Sendable, Comparable, CaseIterable {
    case finding
    case downloading
    case checking
    case installing
    case installed

    public var title: String {
        switch self {
        case .finding: return "Finding the release"
        case .downloading: return "Downloading"
        case .checking: return "Checking the signature"
        case .installing: return "Putting it in place"
        case .installed: return "Installed"
        }
    }

    /// The stages a card lists while it works. `installed` is the outcome, not a
    /// step, so it is not one of them.
    public static var steps: [UpdateInstallStage] { [.finding, .downloading, .checking, .installing] }

    public static func < (lhs: UpdateInstallStage, rhs: UpdateInstallStage) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

public struct UpdateInstallProgress: Sendable, Equatable {
    public let stage: UpdateInstallStage
    /// Only ever set during `.downloading`.
    public let transfer: UpdateTransfer?

    public init(stage: UpdateInstallStage, transfer: UpdateTransfer? = nil) {
        self.stage = stage
        self.transfer = transfer
    }
}

// MARK: - Why it stopped

/// Every way the swap can fail, as a sentence the owner can act on.
///
/// The rule for the wording is the one this project already holds itself to: a
/// dead end has to name the next door. Almost all of these end at the releases
/// page, which is a thing anybody can do with a browser, so `offersThePage`
/// says which ones.
public enum UpdateInstallProblem: Error, Sendable, Equatable {
    /// GitHub could not be asked, or could not be understood.
    case cannotAsk(UpdateCheckProblem)
    /// The release has no Apple-silicon disk image on it.
    case noBuildToInstall
    /// Nothing newer is published. Not a failure — the owner pressed a button
    /// and this is the answer.
    case alreadyCurrent(String)
    case notEnoughRoom(needed: Int64)
    case downloadRefused(Int)
    case downloadFailed
    case cancelled
    case imageWouldNotOpen
    case imageHasNoApp
    /// The app in the image is not this app.
    case differentApp(found: String)
    /// This copy carries no Developer ID, so there is nothing to hold the new
    /// one to. Every build off this project's release script has one.
    case thisCopyIsUnsigned
    case differentSigner(found: String)
    case gatekeeperRefused(String)
    /// Running straight from the mounted disk image.
    case runningFromTheImage
    case cannotWriteThere(String)
    /// The swap failed and the copy that was there is back.
    case putBack(String)
    /// The swap failed and putting the old copy back failed too. The one state
    /// in here that leaves the Mac worse than it found it, so it says exactly
    /// where the old copy is.
    case leftInBackup(String)
    /// The new copy is in place; this one could not hand over to it. Nothing is
    /// broken and nothing needs downloading again — it is a restart the owner
    /// now has to do themselves.
    case couldNotRestart

    public var spokenDescription: String {
        switch self {
        case .cannotAsk(let problem):
            return problem.spokenDescription
        case .noBuildToInstall:
            return "GitHub's newest release has no Apple-silicon download on it. "
                + "The releases page has every build."
        case .alreadyCurrent(let version):
            return "You are on \(version), which is the newest version GitHub has been given."
        case .notEnoughRoom(let needed):
            return "There isn't room on this Mac for the download — Mynah needs about "
                + "\(UpdateTransfer.size(needed)) free to replace itself. Clear some space and "
                + "try again."
        case .downloadRefused(let status):
            return "GitHub wouldn't hand over the download (\(status)). You can fetch it from the "
                + "releases page instead."
        case .downloadFailed:
            return "The download stopped before it finished. Nothing on this Mac was changed — "
                + "try again, or fetch it from the releases page."
        case .cancelled:
            return "Stopped. Nothing on this Mac was changed."
        case .imageWouldNotOpen:
            return "macOS wouldn't open the downloaded disk image. Fetch it from the releases "
                + "page and open it yourself."
        case .imageHasNoApp:
            return "The downloaded disk image has no Mynah in it. Fetch it from the releases page "
                + "and look for yourself."
        case .differentApp(let found):
            return "The app in that download is \(found), not Mynah, so Mynah left it alone. "
                + "Nothing on this Mac was changed."
        case .thisCopyIsUnsigned:
            return "This copy of Mynah carries no developer signature, so Mynah has nothing to "
                + "check a new one against and won't replace itself. Download the new version "
                + "from the releases page."
        case .differentSigner(let found):
            return "The download is signed by \(found), which is not who signed this copy. Mynah "
                + "refused it and changed nothing."
        case .gatekeeperRefused(let detail):
            return "macOS refused the download: \(detail). Mynah changed nothing."
        case .runningFromTheImage:
            return "Mynah is running from the disk image it was downloaded in, so it can't replace "
                + "itself. Drag Mynah into your Applications folder first, open it from there, "
                + "and this will work."
        case .cannotWriteThere(let path):
            return "Mynah can't replace itself in \(path) — that folder is read-only for you. "
                + "Move Mynah into your Applications folder, or download the new version yourself."
        case .putBack(let detail):
            return "Installing failed, so Mynah put the copy you had back: \(Self.ending(detail))"
        case .leftInBackup(let path):
            return "Installing failed and Mynah could not put your old copy back. It is at "
                + "\(path) — drag it into Applications."
        case .couldNotRestart:
            return "The new version is installed, but Mynah couldn't start it for you. Quit "
                + "Mynah and open it again — what opens will be the new one."
        }
    }

    /// A borrowed sentence, finished.
    ///
    /// The details in here come from `FileManager` and from `codesign`, and
    /// those two disagree about full stops. Putting one on is the difference
    /// between a sentence and a log line pasted into a screen.
    static func ending(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let last = trimmed.last else { return "" }
        return ".!?".contains(last) ? trimmed : trimmed + "."
    }

    /// Whether offering the releases page is a useful next step. It is not, for
    /// the two states where the Mac itself is what needs attention.
    public var offersThePage: Bool {
        switch self {
        case .runningFromTheImage, .notEnoughRoom, .cancelled, .leftInBackup, .couldNotRestart:
            return false
        default:
            return true
        }
    }
}

// MARK: - The two things this needs from outside

/// Fetches one asset to a file, reporting bytes as they land.
///
/// A protocol so tests can hand over a file without a network, and so the
/// progress reporting is the same shape whatever is behind it.
public protocol UpdateFetching: Sendable {
    /// - Returns: the HTTP status, so the caller can tell a 200 from GitHub's
    ///   polite refusals rather than treating both as bytes.
    func download(
        _ request: URLRequest,
        to destination: URL,
        progress: @escaping @Sendable (UpdateTransfer) -> Void
    ) async throws -> Int
}

/// `hdiutil`, `codesign`, `spctl` — the three tools the swap cannot be done
/// without, behind one call so tests never reach the real ones.
public protocol UpdateCommanding: Sendable {
    @discardableResult
    func run(_ tool: String, _ arguments: [String]) throws -> String
}

public struct UpdateCommandFailure: Error, Equatable {
    public let tool: String
    public let status: Int32
    public let output: String

    public init(tool: String, status: Int32, output: String) {
        self.tool = tool
        self.status = status
        self.output = output
    }

    /// The last line with anything in it. `spctl` and `codesign` put the reason
    /// at the end and the path at the start, and the reason is the half worth
    /// showing somebody.
    public var lastLine: String {
        output
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .last { !$0.isEmpty } ?? "no reason given"
    }
}

// MARK: - Replacing this copy with the new one

/// Downloads the newest release, checks it is genuinely Mynah signed by whoever
/// signed this copy, and swaps it in.
///
/// **This is a change of position, and it is worth saying why.** `UpdateCheck`
/// used to end at a link, on the reasoning that an appliance holding a live
/// Signal connection and an open microphone should not rewrite itself
/// underneath either. That reasoning was about the *restart*, not about the
/// file — and it made every owner do by hand something their Mac can do
/// exactly, which on a machine that lives in a cupboard means it does not get
/// done at all.
///
/// So the swap happens on disk while everything keeps running: replacing a
/// bundle does not disturb a process already running out of it, because the
/// running copy holds its own inode until it exits. Nothing is interrupted
/// until the owner presses Restart, which is theirs to press. The daemon comes
/// back on the new build by itself — `SignalBackgroundServices` stamps the
/// executable into its LaunchAgent precisely so that replacing the app is
/// noticed.
///
/// What it will not do, ever, is install something it cannot show is the same
/// app from the same signer: bundle identifier, Developer ID team, and
/// Gatekeeper's own verdict, all three, before anything is moved.
public struct UpdateInstaller: Sendable {

    public struct Asset: Sendable, Equatable {
        public let name: String
        public let url: URL
        public let size: Int64?
    }

    private let runningVersion: String?
    private let bundleURL: URL
    private let bundleIdentifier: String?
    private let support: URL
    private let transport: any UpdateCheck.Transport
    private let fetcher: any UpdateFetching
    private let commands: any UpdateCommanding
    private let fileManager: FileManager
    private let log = MynahLog(category: "update")

    public init(
        runningVersion: String? = UpdateCheck.bundleVersion(),
        bundleURL: URL = Bundle.main.bundleURL,
        bundleIdentifier: String? = Bundle.main.bundleIdentifier,
        support: URL = UpdatePreferences.defaultFileURL().deletingLastPathComponent(),
        transport: any UpdateCheck.Transport = GitHubReleaseTransport(),
        fetcher: any UpdateFetching = GitHubAssetDownloader(),
        commands: any UpdateCommanding = SystemCommands(),
        fileManager: FileManager = .default
    ) {
        self.runningVersion = runningVersion
        self.bundleURL = bundleURL
        self.bundleIdentifier = bundleIdentifier
        self.support = support
        self.transport = transport
        self.fetcher = fetcher
        self.commands = commands
        self.fileManager = fileManager
    }

    /// The whole errand, start to finish.
    ///
    /// Never throws: everything that can go wrong is a sentence for the owner,
    /// and a screen driving this should not have to translate errors.
    ///
    /// - Parameter progress: called as each stage begins, and repeatedly during
    ///   the download. Off the main actor — the caller hops.
    /// - Returns: the version now on disk, or why there isn't one.
    public func run(
        progress: @escaping @Sendable (UpdateInstallProgress) -> Void
    ) async -> Result<String, UpdateInstallProblem> {
        progress(UpdateInstallProgress(stage: .finding))

        guard let running = runningVersion.flatMap(ReleaseVersion.init(tag:)) else {
            return .failure(.cannotAsk(.unknownRunningVersion))
        }
        // Before the network, not after. Whether this copy can be replaced at
        // all is knowable in a millisecond, and finding out afterwards would
        // mean pulling down 555 MB to then say "actually, no".
        if let refusal = placeRefusal() { return .failure(refusal) }
        guard let team = signingTeam(of: bundleURL) else { return .failure(.thisCopyIsUnsigned) }

        let found: (version: ReleaseVersion, asset: Asset)
        switch await newestRelease() {
        case .failure(let problem): return .failure(problem)
        case .success(let release): found = release
        }
        guard found.version > running else {
            return .failure(.alreadyCurrent(running.description))
        }

        log.info("update: \(found.version) found, downloading \(found.asset.name)")
        progress(UpdateInstallProgress(stage: .downloading, transfer: UpdateTransfer(
            received: 0, expected: found.asset.size
        )))

        let image: URL
        switch await fetch(found.asset, progress: progress) {
        case .failure(let problem): return .failure(problem)
        case .success(let url): image = url
        }

        progress(UpdateInstallProgress(stage: .checking))
        let mounted: URL
        do {
            mounted = try mount(image)
        } catch {
            log.error("update: the image would not mount: \(String(describing: error))")
            return .failure(.imageWouldNotOpen)
        }
        defer {
            _ = try? commands.run("/usr/bin/hdiutil", ["detach", mounted.path, "-quiet"])
        }

        guard let candidate = app(in: mounted) else { return .failure(.imageHasNoApp) }
        if let refusal = identityRefusal(of: candidate, expectedTeam: team) {
            log.error("update: refused the download — \(refusal.spokenDescription)")
            return .failure(refusal)
        }

        progress(UpdateInstallProgress(stage: .installing))
        if let refusal = swap(in: candidate) { return .failure(refusal) }

        // The image is 555 MB and its only remaining job is done. The backup of
        // the previous app is kept — that one cannot be fetched again if the
        // release is ever pulled.
        try? fileManager.removeItem(at: image)

        log.info("update: \(found.version) is installed; waiting for the owner to restart")
        progress(UpdateInstallProgress(stage: .installed))
        return .success(found.version.description)
    }

    // MARK: Where this copy lives

    /// Why this copy cannot be replaced where it stands, when it cannot.
    private func placeRefusal() -> UpdateInstallProblem? {
        // A mounted disk image is read-only, and an owner running from one has
        // not installed Mynah at all yet — so the answer is not "this failed",
        // it is "drag it to Applications first".
        if bundleURL.path.hasPrefix("/Volumes/") { return .runningFromTheImage }
        let parent = bundleURL.deletingLastPathComponent()
        guard fileManager.isWritableFile(atPath: parent.path) else {
            return .cannotWriteThere(parent.path)
        }
        return nil
    }

    // MARK: Which release

    /// Internal rather than private so `pick(from:)` can be tested without a
    /// network: the picker is the part with a rule in it.
    struct ReleasePayload: Decodable {
        struct Asset: Decodable {
            let name: String?
            let browser_download_url: String?
            let size: Int64?
        }
        let tag_name: String?
        let name: String?
        let assets: [Asset]?
    }

    /// Asks the same endpoint `UpdateCheck` asks, and for the same reason:
    /// `/releases/latest` excludes drafts and prereleases, so a beta pushed for
    /// one tester is never something an owner's Mac installs by itself.
    ///
    /// Asked again here rather than carried over from the check, because the
    /// check's answer can be a day old — it is allowed to be remembered — and
    /// the one thing that must be current is which bytes are about to replace
    /// this app.
    private func newestRelease() async -> Result<(ReleaseVersion, Asset), UpdateInstallProblem> {
        var request = URLRequest(url: UpdateCheck.latestReleaseAPI)
        request.httpMethod = "GET"
        request.timeoutInterval = UpdateCheck.timeout
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("Mynah", forHTTPHeaderField: "User-Agent")

        let status: Int
        let body: Data
        do {
            (status, body) = try await transport.fetch(request)
        } catch {
            return .failure(.cannotAsk(.noAnswer))
        }
        switch status {
        case 200: break
        case 403, 429: return .failure(.cannotAsk(.rateLimited))
        case 404: return .failure(.cannotAsk(.notVisible))
        default: return .failure(.cannotAsk(.serverProblem))
        }

        guard let payload = try? JSONDecoder().decode(ReleasePayload.self, from: body),
              let version = ReleaseVersion(tag: payload.tag_name ?? "")
                ?? ReleaseVersion(tag: payload.name ?? "") else {
            return .failure(.cannotAsk(.unreadable))
        }
        guard let asset = Self.pick(from: payload.assets ?? []) else {
            return .failure(.noBuildToInstall)
        }
        return .success((version, asset))
    }

    /// The Apple-silicon disk image on a release, preferring the one with the
    /// version in its name.
    ///
    /// Both names are the same bytes — the release carries `Mynah-1.2.5-…` and
    /// a fixed `Mynah-macOS-arm64.dmg` so that `releases/latest/download/…` can
    /// resolve. The versioned one is picked so the file that lands in
    /// `Updates/` says what it is, which matters when somebody is reading that
    /// folder to work out what happened.
    static func pick(from assets: [ReleasePayload.Asset]) -> Asset? {
        let images: [Asset] = assets.compactMap { asset in
            guard let name = asset.name,
                  name.lowercased().hasSuffix("macos-arm64.dmg"),
                  let link = asset.browser_download_url,
                  let url = URL(string: link),
                  url.scheme?.lowercased() == "https",
                  let host = url.host?.lowercased(),
                  host.hasSuffix("github.com") || host.hasSuffix("githubusercontent.com") else {
                return nil
            }
            return Asset(name: name, url: url, size: asset.size)
        }
        // A digit right after "Mynah-" is what tells the two names apart.
        return images.first { $0.name.range(of: #"-\d"#, options: .regularExpression) != nil }
            ?? images.first
    }

    // MARK: Getting it

    private func fetch(
        _ asset: Asset,
        progress: @escaping @Sendable (UpdateInstallProgress) -> Void
    ) async -> Result<URL, UpdateInstallProblem> {
        let updates = support.appendingPathComponent("Updates", isDirectory: true)
        do {
            try fileManager.createDirectory(at: updates, withIntermediateDirectories: true)
        } catch {
            return .failure(.cannotWriteThere(updates.path))
        }
        // Whatever a previous attempt left. Kept until now rather than deleted
        // on success so that a failed attempt's bytes are still there to look
        // at; cleared here so two builds never sit in the folder at once.
        prune(updates, keeping: 0)

        // The image, the copy of the app made out of it, and the old app moved
        // aside — three times the download, near enough, and running out of
        // room halfway through the swap is the one failure worth spending a
        // millisecond to avoid.
        if let size = asset.size {
            let needed = size * 3
            let free = (try? updates.resourceValues(
                forKeys: [.volumeAvailableCapacityForImportantUsageKey]
            ))?.volumeAvailableCapacityForImportantUsage
            if let free, free < needed { return .failure(.notEnoughRoom(needed: needed)) }
        }

        let destination = updates.appendingPathComponent(asset.name)
        var request = URLRequest(url: asset.url)
        request.setValue("application/octet-stream", forHTTPHeaderField: "Accept")
        request.setValue("Mynah", forHTTPHeaderField: "User-Agent")

        do {
            let status = try await fetcher.download(request, to: destination) { transfer in
                progress(UpdateInstallProgress(stage: .downloading, transfer: transfer))
            }
            guard (200..<300).contains(status) else {
                try? fileManager.removeItem(at: destination)
                return .failure(.downloadRefused(status))
            }
            return .success(destination)
        } catch is CancellationError {
            try? fileManager.removeItem(at: destination)
            return .failure(.cancelled)
        } catch {
            try? fileManager.removeItem(at: destination)
            log.error("update: the download failed: \(String(describing: error))")
            return .failure(Task.isCancelled ? .cancelled : .downloadFailed)
        }
    }

    // MARK: Opening it

    private func mount(_ image: URL) throws -> URL {
        let output = try commands.run(
            "/usr/bin/hdiutil",
            ["attach", image.path, "-nobrowse", "-readonly", "-plist"]
        )
        guard let url = Self.mountPoint(inPropertyList: output) else {
            throw UpdateCommandFailure(tool: "hdiutil", status: 0, output: output)
        }
        return url
    }

    /// The mount point out of `hdiutil -plist`, which lists every entity on the
    /// image and gives only the mountable one a `mount-point`.
    static func mountPoint(inPropertyList text: String) -> URL? {
        guard let data = text.data(using: .utf8),
              let plist = try? PropertyListSerialization.propertyList(
                  from: data, options: [], format: nil
              ) as? [String: Any],
              let entities = plist["system-entities"] as? [[String: Any]] else {
            return nil
        }
        guard let path = entities.compactMap({ $0["mount-point"] as? String }).first else {
            return nil
        }
        return URL(fileURLWithPath: path, isDirectory: true)
    }

    /// The app inside the image: the one named like this one, or the only one
    /// there is.
    private func app(in volume: URL) -> URL? {
        let expected = volume.appendingPathComponent(bundleURL.lastPathComponent, isDirectory: true)
        if fileManager.fileExists(atPath: expected.path) { return expected }
        let contents = (try? fileManager.contentsOfDirectory(
            at: volume, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
        )) ?? []
        return contents.first { $0.pathExtension == "app" }
    }

    // MARK: Is it really us

    /// Three questions, all of which have to answer yes before anything moves.
    ///
    /// Identifier first, because a bundle identifier is what macOS hangs
    /// microphone and accessibility permission on: installing something else
    /// under this app's name would hand it every permission the owner has
    /// granted Mynah. Then the signer, then Gatekeeper — cheapest first, and
    /// each one is enough on its own to stop.
    private func identityRefusal(of candidate: URL, expectedTeam: String) -> UpdateInstallProblem? {
        let info = candidate.appendingPathComponent("Contents/Info.plist")
        let identifier = (NSDictionary(contentsOf: info)?["CFBundleIdentifier"] as? String)
        guard let identifier, identifier == bundleIdentifier else {
            return .differentApp(found: identifier ?? "an app with no identifier")
        }

        do {
            try commands.run(
                "/usr/bin/codesign",
                ["--verify", "--deep", "--strict", "--verbose=2", candidate.path]
            )
        } catch let failure as UpdateCommandFailure {
            return .gatekeeperRefused(failure.lastLine)
        } catch {
            return .gatekeeperRefused("the signature could not be read")
        }

        guard let team = signingTeam(of: candidate) else {
            return .differentSigner(found: "nobody")
        }
        guard team == expectedTeam else { return .differentSigner(found: team) }

        do {
            // Gatekeeper's own answer, which is the one that covers notarization
            // — a signature can be valid and the build still never have been
            // seen by Apple.
            try commands.run("/usr/sbin/spctl", ["-a", "-t", "exec", "-vv", candidate.path])
        } catch let failure as UpdateCommandFailure {
            return .gatekeeperRefused(failure.lastLine)
        } catch {
            return .gatekeeperRefused("macOS would not assess it")
        }
        return nil
    }

    /// The Developer ID team an app is signed by, or `nil` when it carries no
    /// signature at all.
    private func signingTeam(of app: URL) -> String? {
        guard let output = try? commands.run(
            "/usr/bin/codesign", ["-dv", "--verbose=4", app.path]
        ) else {
            return nil
        }
        return Self.team(inCodesignOutput: output)
    }

    static func team(inCodesignOutput output: String) -> String? {
        for line in output.split(separator: "\n") {
            guard line.hasPrefix("TeamIdentifier=") else { continue }
            let value = String(line.dropFirst("TeamIdentifier=".count))
                .trimmingCharacters(in: .whitespaces)
            // An ad-hoc or self-signed build says exactly this, and it is not a
            // team.
            return value.isEmpty || value == "not set" ? nil : value
        }
        return nil
    }

    // MARK: The swap

    /// Copy beside, move the old one out, move the new one in.
    ///
    /// The order is the whole point. The copy is the slow part and it happens
    /// while the working app is still in place, so a failure there costs
    /// nothing. The two moves are renames within one folder — near-instant, and
    /// there is no moment where neither copy exists.
    private func swap(in candidate: URL) -> UpdateInstallProblem? {
        let parent = bundleURL.deletingLastPathComponent()
        let staging = parent.appendingPathComponent(bundleURL.lastPathComponent + ".updating")
        try? fileManager.removeItem(at: staging)

        do {
            try fileManager.copyItem(at: candidate, to: staging)
        } catch {
            try? fileManager.removeItem(at: staging)
            return .putBack("the new copy could not be written next to the old one. "
                + error.localizedDescription)
        }

        let backups = support.appendingPathComponent("Backups", isDirectory: true)
        try? fileManager.createDirectory(at: backups, withIntermediateDirectories: true)
        prune(backups, keeping: 0)
        let backup = backups.appendingPathComponent(
            "\(bundleURL.deletingPathExtension().lastPathComponent)-\(Self.stamp()).app",
            isDirectory: true
        )

        let hadOne = fileManager.fileExists(atPath: bundleURL.path)
        if hadOne {
            do {
                try fileManager.moveItem(at: bundleURL, to: backup)
            } catch {
                try? fileManager.removeItem(at: staging)
                return .putBack("the copy you have could not be moved aside. "
                    + error.localizedDescription)
            }
        }

        do {
            try fileManager.moveItem(at: staging, to: bundleURL)
        } catch {
            try? fileManager.removeItem(at: staging)
            guard hadOne else { return .putBack(error.localizedDescription) }
            do {
                try fileManager.moveItem(at: backup, to: bundleURL)
                return .putBack(error.localizedDescription)
            } catch {
                return .leftInBackup(backup.path)
            }
        }
        return nil
    }

    /// Newest first, then everything past the first `keeping`.
    private func prune(_ directory: URL, keeping: Int) {
        let contents = (try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        )) ?? []
        let ordered = contents.sorted { left, right in
            let a = (try? left.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate ?? .distantPast
            let b = (try? right.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate ?? .distantPast
            return a > b
        }
        for item in ordered.dropFirst(max(0, keeping)) {
            try? fileManager.removeItem(at: item)
        }
    }

    static func stamp(_ date: Date = Date()) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter.string(from: date)
    }
}

// MARK: - The real network

/// One asset, to one file, reporting as it goes.
///
/// Delegate-based rather than `URLSession.download(for:)` because that call
/// reports nothing until it finishes, and a 555 MB download with no sign of
/// movement is indistinguishable from a hung one.
public final class GitHubAssetDownloader: NSObject, UpdateFetching, URLSessionDownloadDelegate,
                                          @unchecked Sendable {

    private let lock = NSLock()
    private var continuation: CheckedContinuation<(Int, Error?), Never>?
    private var destination: URL?
    private var progress: (@Sendable (UpdateTransfer) -> Void)?
    private var expected: Int64?
    private var lastReported: Int64 = 0
    private var task: URLSessionDownloadTask?
    private var session: URLSession?

    public override init() { super.init() }

    /// Every 2 MB. Per-chunk would be tens of thousands of hops onto the main
    /// actor for a bar that moves a fraction of a pixel.
    private static let reportEvery: Int64 = 2 * 1024 * 1024

    public func download(
        _ request: URLRequest,
        to destination: URL,
        progress: @escaping @Sendable (UpdateTransfer) -> Void
    ) async throws -> Int {
        // In a synchronous method, not inline: taking a lock in an async
        // function is a suspension point away from a deadlock, and the compiler
        // says so.
        prepare(destination: destination, progress: progress)

        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.urlCache = nil
        // Long, deliberately: this is half a gigabyte and the timeout that
        // matters is "no bytes at all for a while", which is what
        // `timeoutIntervalForRequest` measures.
        configuration.timeoutIntervalForRequest = 60
        configuration.timeoutIntervalForResource = 60 * 60
        let session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
        self.session = session
        defer { session.finishTasksAndInvalidate() }

        let (status, failure) = await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<(Int, Error?), Never>) in
                lock.lock()
                self.continuation = continuation
                let task = session.downloadTask(with: request)
                self.task = task
                lock.unlock()
                task.resume()
            }
        } onCancel: {
            lock.lock()
            let task = self.task
            lock.unlock()
            task?.cancel()
        }

        if let failure {
            // A cancelled `URLSessionTask` reports `.cancelled`, which is this
            // app stopping it rather than anything going wrong.
            if (failure as? URLError)?.code == .cancelled { throw CancellationError() }
            throw failure
        }
        return status
    }

    private func prepare(
        destination: URL,
        progress: @escaping @Sendable (UpdateTransfer) -> Void
    ) {
        lock.lock()
        self.destination = destination
        self.progress = progress
        self.expected = nil
        self.lastReported = 0
        lock.unlock()
    }

    // MARK: Delegate

    public func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        lock.lock()
        if totalBytesExpectedToWrite > 0 { expected = totalBytesExpectedToWrite }
        let total = expected
        let due = totalBytesWritten - lastReported >= Self.reportEvery
        if due { lastReported = totalBytesWritten }
        let report = progress
        lock.unlock()

        guard due else { return }
        report?(UpdateTransfer(received: totalBytesWritten, expected: total))
    }

    public func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        lock.lock()
        let destination = self.destination
        lock.unlock()

        guard let destination else { return }
        // Inside the delegate call, which is the only window in which the
        // temporary file still exists.
        try? FileManager.default.removeItem(at: destination)
        do {
            try FileManager.default.moveItem(at: location, to: destination)
        } catch {
            finish(status: 0, failure: error)
        }
    }

    public func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: Error?
    ) {
        let status = (task.response as? HTTPURLResponse)?.statusCode ?? 0
        finish(status: status, failure: error)
    }

    private func finish(status: Int, failure: Error?) {
        lock.lock()
        let continuation = self.continuation
        self.continuation = nil
        lock.unlock()
        continuation?.resume(returning: (status, failure))
    }
}

// MARK: - The real tools

/// Runs one of the three command-line tools the swap needs and hands back what
/// it said.
public struct SystemCommands: UpdateCommanding {

    public init() {}

    @discardableResult
    public func run(_ tool: String, _ arguments: [String]) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments

        // One pipe for both streams: `codesign` and `spctl` say everything
        // useful on stderr, and reading them separately only makes the two
        // halves of one sentence arrive apart.
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()

        // Read before waiting. A pipe buffer that fills while nobody is
        // draining it blocks the child forever, and `hdiutil -plist` on a
        // multi-partition image is bigger than that buffer.
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        let output = String(data: data, encoding: .utf8) ?? ""
        guard process.terminationStatus == 0 else {
            throw UpdateCommandFailure(
                tool: URL(fileURLWithPath: tool).lastPathComponent,
                status: process.terminationStatus,
                output: output
            )
        }
        return output
    }
}
