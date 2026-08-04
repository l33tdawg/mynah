import AppKit
import Foundation
import Observation
import SageVoiceCore
import SwiftUI

private let log = MynahLog(category: "update")

// MARK: - The one thing that knows about updates

/// Whether a newer Mynah exists, checked on a timer, and the swap when the owner
/// asks for it.
///
/// **Shared, and it has to be.** Two objects each holding an install task can
/// each start one, and two processes replacing the same bundle at the same time
/// is the one failure here that leaves an owner with no working app. The Settings
/// row and the banner are two views onto this, never two copies of it.
///
/// It lives here rather than on `AppModel` because it owns a running task and a
/// piece of installation state, and `AppModel` is read by every preview in the
/// app — a preview should not start checking GitHub for updates.
@MainActor
@Observable
final class UpdateWatch {

    /// The instance the app uses. Previews and tests build their own.
    static let shared = UpdateWatch()

    /// How a swap is going, when one is happening.
    ///
    /// Three states rather than a handful of flags, because the sheet draws one
    /// of exactly three things: it is working, it finished, or it stopped and
    /// said why. `nil` is no sheet at all.
    enum InstallState: Equatable {
        case working(UpdateInstallProgress)
        case installed(String)
        case failed(UpdateInstallProblem)

        var isWorking: Bool {
            if case .working = self { return true }
            return false
        }
    }

    /// What the last check found. `nil` while the first one is still running,
    /// which is the only state that means "asking".
    private(set) var availability: UpdateAvailability?

    private(set) var installState: InstallState?

    /// The version sitting on disk waiting for a restart, once one is.
    ///
    /// Kept apart from `installState` deliberately: closing the sheet puts the
    /// sheet away, and it must not also throw away the fact that this Mac is now
    /// carrying a newer Mynah than the one running.
    private(set) var installedAndWaiting: String?

    private(set) var isChecking = false

    private let preferencesFile: URL
    private let interval: TimeInterval
    private var watching: Task<Void, Never>?
    private var installWork: Task<Result<String, UpdateInstallProblem>, Never>?

    init(
        preferencesFile: URL = UpdatePreferences.defaultFileURL(),
        interval: TimeInterval = UpdateCheck.interval
    ) {
        self.preferencesFile = preferencesFile
        self.interval = interval
    }

    // MARK: Watching

    /// Starts asking, and keeps asking every `interval`.
    ///
    /// Idempotent, because it is called from `.task` on a view that SwiftUI is
    /// entitled to re-run. A second call while the first loop is alive does
    /// nothing rather than starting a second loop.
    ///
    /// The first check happens immediately on the assumption that a launch is a
    /// reasonable moment to look — but `UpdateCheck.run` still decides whether
    /// that becomes a network request, so a Mac restarted six times in an hour
    /// makes one. What launching always does is *read the cached answer*, which
    /// is what puts the banner back on screen for a release the owner has
    /// already been told about and not yet taken.
    func start() {
        guard watching == nil else { return }
        watching = Task { [weak self] in
            while !Task.isCancelled {
                await self?.check()
                guard let seconds = self?.interval else { return }
                try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            }
        }
    }

    func stop() {
        watching?.cancel()
        watching = nil
    }

    /// Throws away the last answer, so the row goes back to "asking" rather than
    /// leaving yesterday's verdict on screen while a fresh one is fetched.
    ///
    /// For the moment the owner changes the switch, and nothing else: an answer
    /// discarded anywhere else would take the banner down without the update
    /// having been taken.
    func forgetAnswer() { availability = nil }

    /// Asks, subject to the interval and the owner's switch.
    func check() async {
        availability = await UpdateCheck(preferencesFile: preferencesFile).run()
    }

    /// Asks now, whatever the interval and the switch say.
    ///
    /// `force: true` for the reason spelled out on `UpdateCheck.run` — the
    /// interval exists so the appliance does not pester GitHub *unprompted*, and
    /// somebody pressing a button is the opposite of unprompted.
    func checkNow() async {
        guard !isChecking else { return }
        isChecking = true
        defer { isChecking = false }
        availability = await UpdateCheck(preferencesFile: preferencesFile).run(force: true)
    }

    /// When GitHub was last asked, in words.
    var lastCheckedDescription: String {
        let cadence = "Every fifteen minutes."
        guard let when = UpdatePreferences.load(from: preferencesFile).lastCheckedAt else {
            return "\(cadence) It hasn't asked yet."
        }
        let ago = Date().timeIntervalSince(when)
        // Under a minute is "just now" rather than "0 seconds ago", which is
        // what the relative formatter says and is not how anybody speaks.
        guard ago >= 60 else { return "\(cadence) Last asked just now." }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return "\(cadence) Last asked \(formatter.localizedString(for: when, relativeTo: Date()))."
    }

    // MARK: What the banner says

    /// The banner's content, or `nil` for no banner.
    ///
    /// **There is no dismiss, by the owner's decision**: *"if you check, we cache
    /// and then the banner stays till you update"*. So this is not gated on
    /// anything the owner has clicked past — it goes away when the reason for it
    /// goes away, which is when the newer version is the running one.
    ///
    /// That happens by itself. Once the swap is done and Mynah has been
    /// restarted, the running version equals the released one, `UpdateCheck`
    /// says `.upToDate`, and there is nothing here to draw.
    nonisolated struct Banner: Equatable {
        var headline: String
        var detail: String
        /// The release's own page, for "What's new".
        var page: URL
        /// True between the file landing on disk and the restart, when the verb
        /// is no longer "update" but "restart".
        var isWaitingForRestart: Bool
    }

    var banner: Banner? {
        Self.banner(for: availability, installedAndWaiting: installedAndWaiting)
    }

    /// A pure function of the two things that decide it, so the wording and the
    /// cases can be tested without a network, a bundle or a running app.
    ///
    /// `nonisolated` because it touches nothing on the instance — being forced
    /// onto the main actor to ask what a banner would say is a test that has to
    /// spin up an actor hop to check a sentence.
    nonisolated static func banner(
        for availability: UpdateAvailability?,
        installedAndWaiting: String?
    ) -> Banner? {
        // Ahead of the check, and deliberately: the running copy is still the
        // old version, so `UpdateCheck` goes on reporting a newer one. It is
        // right, and it is not the sentence this owner needs.
        if let waiting = installedAndWaiting {
            return Banner(
                headline: "Mynah \(waiting) is installed.",
                detail: "It starts answering on the new version when you restart. "
                    + "Until then the one you have keeps running.",
                page: page(from: availability),
                isWaitingForRestart: true
            )
        }
        // Every other case draws nothing — including `cannotTell`. A Mac that is
        // offline, or a GitHub that returned a 404, has not said an update
        // exists, and a band across the window is far too loud a way to report
        // that a background request failed. Settings says so; the banner does
        // not.
        guard case .newer(let version, let page)? = availability else { return nil }
        return Banner(
            headline: "Mynah \(version) is ready.",
            detail: "Mynah fetches it and puts it in place while it carries on answering "
                + "your phone.",
            page: page,
            isWaitingForRestart: false
        )
    }

    nonisolated private static func page(from availability: UpdateAvailability?) -> URL {
        if case .newer(_, let page)? = availability { return page }
        return UpdateCheck.releasesPage
    }

    /// The release's own page where GitHub named one, so "What's new" lands on
    /// the build being offered rather than on a list of every build.
    var releasePage: URL { Self.page(from: availability) }

    /// The version being offered, for the sheet's title.
    var offeredVersion: String {
        if case .newer(let version, _)? = availability { return version }
        return installedAndWaiting ?? ""
    }

    // MARK: Swapping

    /// Fetches the release, checks who signed it, and puts it in place.
    ///
    /// The stages arrive on a stream rather than through a closure that writes
    /// this object: the installer runs off this actor, and handing it something
    /// that mutates the model from wherever it happens to be is how a screen
    /// ends up redrawing from a background thread. The stream's continuation is
    /// the only thing that crosses.
    func install() async {
        guard installWork == nil else { return }
        installState = .working(UpdateInstallProgress(stage: .finding))

        let (steps, feed) = AsyncStream<UpdateInstallProgress>.makeStream()
        let installer = UpdateInstaller()
        let work = Task { () -> Result<String, UpdateInstallProblem> in
            let outcome = await installer.run { feed.yield($0) }
            feed.finish()
            return outcome
        }
        installWork = work

        for await step in steps {
            installState = .working(step)
        }

        let outcome = await work.value
        installWork = nil
        switch outcome {
        case .success(let version):
            log.info("update: \(version) is on disk, waiting for a restart")
            installedAndWaiting = version
            installState = .installed(version)
        case .failure(let problem):
            log.error("update: \(problem.spokenDescription)")
            installState = .failed(problem)
        }
    }

    /// Stops a download in progress. Only offered before anything is moved, so
    /// there is never a half-installed app behind this button.
    func stopInstalling() {
        installWork?.cancel()
    }

    func dismissInstall() {
        installState = nil
    }

    /// Starts the copy now on disk, then stands down.
    ///
    /// The shell waits for this process to be gone before opening the app,
    /// because `open` on an app that is still running activates the old copy
    /// instead of launching the new one — which looks exactly like the update
    /// not having worked.
    ///
    /// The daemon answering the phone comes back by itself: its LaunchAgent
    /// carries a stamp of the executable it was written for, so the new app
    /// notices at launch that the bytes changed and re-installs the job. See
    /// `SignalBackgroundServiceManager.executableStamp`.
    func restartIntoNewVersion(bundleURL: URL = Bundle.main.bundleURL) {
        // Before the shell is even arranged, because what this changes is what
        // `applicationShouldTerminate` does — and without it that method spends
        // up to thirty seconds removing LaunchAgents the next launch will put
        // straight back. See `RestartIntent`.
        let pid = ProcessInfo.processInfo.processIdentifier
        let script = "while /bin/kill -0 \(pid) 2>/dev/null; do /bin/sleep 0.2; done; "
            + "/usr/bin/open \"$1\""
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        // The path as an argument rather than inside the script: a folder name
        // with a quote in it would otherwise end the string and run whatever
        // came after it.
        process.arguments = ["-c", script, "mynah-restart", bundleURL.path]
        do {
            try process.run()
        } catch {
            // Quitting anyway would leave the owner with no Mynah and no
            // explanation. Better to stay up and let them open it themselves.
            log.error("update: could not arrange the restart: \(String(describing: error))")
            installState = .failed(.couldNotRestart)
            return
        }
        // **After the relaunch is arranged and never before.** This changes
        // what quitting does — `applicationShouldTerminate` skips removing the
        // LaunchAgents while it is set, because the next launch would put them
        // straight back. Setting it first and then failing to start the shell
        // would leave the flag on with no restart coming, so the owner's next
        // ordinary Quit would leave their phone still being answered: exactly
        // the bug that method was written to fix.
        RestartIntent.shared.begin()

        // **The card has to come down before the app can go.**
        //
        // *"it still doesn't restart when you click the button - have to press
        // later, then quit and it will auto reopen."* That sentence is the
        // diagnosis: pressing Later dismisses the sheet, and the quit that
        // follows works. `NSApplication.terminate` does not close a window with
        // an attached sheet — the sheet is what the press leaves on screen, so
        // the app sat there with the relaunch already waiting on its process id.
        //
        // Which also means the first version of this fix was never proved. The
        // evidence read at the time — a new process five seconds after the
        // press, and no LaunchAgent teardown in the log — is equally explained
        // by the owner pressing Later and quitting by hand, with the teardown
        // skipped because the flag above was already set. Two readings, one
        // observation, and the wrong one was reported as fact.
        installState = nil
        for window in NSApplication.shared.windows {
            guard let sheet = window.attachedSheet else { continue }
            window.endSheet(sheet)
        }

        // A hop, so AppKit has actually taken the sheet down before the
        // termination is asked for.
        DispatchQueue.main.async {
            NSApplication.shared.terminate(nil)
            // And a floor under the whole thing.
            //
            // A restart that silently does nothing is the failure this button
            // has now had twice, and every cause of it is something AppKit
            // declined to do. Nothing here needs `applicationWillTerminate`:
            // the restart path deliberately leaves the LaunchAgents alone, the
            // conversation is written after each turn rather than at exit, and
            // the copy on disk is already the new one. So if the app is still
            // alive a second later, it leaves anyway.
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                exit(0)
            }
        }
    }
}

// MARK: - The strip under the header

/// One line saying a newer Mynah exists, and the button that takes it.
///
/// **Why this exists at all.** Every part of updating already worked — the check,
/// the verdict, the signed download, the swap, the restart — and all of it was
/// behind Settings, on a screen nobody opens when nothing is wrong. The owner
/// shipped six releases in a day and reported: *"haven't even seen our version
/// of the update banner"*. There was no banner. There was a settings row.
///
/// **No dismiss, by his decision:** *"if you check, we cache and then the banner
/// stays till you update"*. So there is no close button and no "remind me later"
/// — the strip goes when the reason for it goes, which is when the newer version
/// is the one running. Anything else is a control whose only function is to hide
/// the fact that Mynah is out of date.
///
/// **Translucent green, at the owner's instruction:** *"please make it
/// translucent green like quiettype-ish"*. It shipped white first, on the
/// reasoning that this palette had spent a long argument stripping colour of
/// accumulated meanings and an update is neither good news nor bad. He saw it
/// working and asked for green, which settles it — and `Palette.state.goodWash`
/// is the app's own token for exactly this, a low-alpha tint made for inline
/// notes, so the band is green without any new colour entering the palette.
struct UpdateBanner: View {

    var watch: UpdateWatch
    /// Opens a URL. Injected so the preview and the tests do not launch a
    /// browser.
    var open: (URL) -> Void = { NSWorkspace.shared.open($0) }

    var body: some View {
        if let banner = watch.banner {
            HStack(spacing: s4) {
                Image(systemName: banner.isWaitingForRestart
                    ? "arrow.clockwise.circle.fill"
                    : "arrow.down.circle.fill")
                    .font(.system(size: 20, weight: .regular))
                    .foregroundStyle(Palette.state.good)
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: s1) {
                    Text(banner.headline)
                        .mynahFont(.title3)
                        .foregroundStyle(Palette.ink.primary)
                    Text(banner.detail)
                        .mynahFont(.callout)
                        .foregroundStyle(Palette.ink.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: s4)

                // The release's own notes. A link rather than a button because
                // it leaves the Mac, and because an owner who has been offered
                // an update is entitled to read what is in it before taking it.
                Button("What's new") { open(banner.page) }
                    .buttonStyle(.link)
                    .mynahFont(.body)
                    .help("Open the release notes for this version")

                if banner.isWaitingForRestart {
                    MynahButton("Restart Mynah") { watch.restartIntoNewVersion() }
                } else {
                    MynahButton(
                        "Update",
                        isEnabled: !(watch.installState?.isWorking ?? false)
                    ) {
                        Task { await watch.install() }
                    }
                }
            }
            .padding(.horizontal, s6)
            .padding(.vertical, s4)
            .frame(maxWidth: .infinity, alignment: .leading)
            // **The wash goes on top of the surface, not behind it.**
            //
            // This was `.background(raised).background(goodWash)`, which reads
            // like "surface, then tint" and does the opposite: each `background`
            // sits behind the one before it, so the *opaque* raised surface was
            // painted straight over the tint. The icon turned green, the band
            // stayed white, and the modifier that was supposed to colour it did
            // nothing at all.
            //
            // Composed in one `background` now, where the order is the order it
            // is drawn in and cannot be read two ways.
            //
            // Twice, because a single pass of `goodWash` is paler than the
            // reference the owner pointed at. Doubling the palette's own token
            // keeps the light and dark pair it encodes — 0x1D8A4E under a light
            // appearance, 0x3FD07E under a dark one — rather than inventing a
            // second green that would then have to be maintained.
            .background {
                Palette.surface.raised
                    .overlay(Palette.state.goodWash)
                    .overlay(Palette.state.goodWash)
            }
            .overlay(alignment: .bottom) {
                Rectangle()
                    .fill(Palette.state.good.opacity(0.28))
                    .frame(height: 1)
            }
            // Enters from the top so it reads as something arriving rather than
            // something that was always there and went unnoticed.
            .transition(.move(edge: .top).combined(with: .opacity))
            .accessibilityElement(children: .contain)
            .accessibilityLabel("\(banner.headline) \(banner.detail)")
        }
    }
}

#Preview("Update ready") {
    let watch = UpdateWatch()
    return UpdateBanner(watch: watch, open: { _ in })
        .frame(width: 720)
}
