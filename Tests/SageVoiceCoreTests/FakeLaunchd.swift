// **Mac-only, because it tests `MynahMac`.**
//
// `MynahMac` is the AppKit/SwiftUI half of this package, and Package.swift does
// not declare that target off Darwin — so the import below resolves on a Mac
// and nowhere else. The guard wraps the whole file rather than just the import,
// because every test in here drives a Mac type: a file that compiled down to an
// empty test class would let Linux report a green suite that ran nothing, which
// is the exact failure this branch exists to stop. See `coreTestDependencies`
// in Package.swift.
#if os(macOS)
import Foundation
@testable import MynahMac
@testable import SageVoiceCore

/// One launchd for every test that has to stand in for it.
///
/// **There were three, and they disagreed.** `RecordingLaunchctlRunner`,
/// `LoadedLaunchctl` and a third written for this change each modelled the parts
/// of launchctl their own test happened to exercise, and each returned an empty
/// `launchctl print` with exit 0 — a job that is running nothing in particular.
/// That was harmless while nothing read the output and became wrong the moment
/// `enable` started asking launchd which build it had loaded. `LoadedLaunchctl`'s
/// own doc comment said it *"reports both jobs loaded"*, which by then it did
/// not; the comment described an intention the code had stopped implementing.
///
/// That is the same failure the 1.7.4 sweep found across ~30 SAGE tests: a
/// stand-in written by hand, believed accurate, quietly diverging from the thing
/// it stands for while every test over it stayed green. One fake can still be
/// wrong — but it can only be wrong once, and fixing it fixes every caller.
///
/// So this one does what launchd does rather than what a caller expects:
/// `bootstrap` loads the build stamp out of the plist it is handed, `bootout`
/// unloads it, and `print` reports what is loaded, in launchctl's own layout
/// including the `inherited environment` block that must not be mistaken for the
/// job's own.
actor FakeLaunchd: ProbeCommandRunning {

    struct Call: Sendable {
        let executable: URL
        let arguments: [String]
    }

    private(set) var calls: [Call] = []
    private var loaded: [String: String] = [:]
    private var startsSucceed = true

    init() {}

    var bootstraps: Int { calls.filter { $0.arguments.first == "bootstrap" }.count }
    var bootouts: Int { calls.filter { $0.arguments.first == "bootout" }.count }

    /// Puts launchd in the state where both jobs are already running the build
    /// this configuration installs — the state a reconcile should leave alone.
    func load(_ configuration: SignalServiceConfiguration) {
        // Only when there is one, for the same reason WhatsApp is conditional
        // below: a WhatsApp-only appliance has no Signal helper to load, and a
        // fake that loaded one anyway would be modelling a machine that cannot
        // exist.
        if let signalCLI = configuration.signalCLI {
            loaded[SignalBackgroundServiceManager.signalLabel] =
                SignalBackgroundServiceManager.executableStamp(signalCLI)
        }
        loaded[SignalBackgroundServiceManager.bridgeLabel] =
            SignalBackgroundServiceManager.executableStamp(configuration.bridge)
        // Only when the configuration has one. A fake that loaded a WhatsApp job
        // for a Signal-only appliance would be modelling a machine that cannot
        // exist, and every reconcile test would then be asserting against it.
        if let whatsApp = configuration.whatsApp {
            loaded[SignalBackgroundServiceManager.whatsAppLabel] =
                SignalBackgroundServiceManager.executableStamp(whatsApp.bridge)
        }
    }

    /// Puts launchd in the state the owner's Mac was in on 5 August: both jobs
    /// running, both running something other than what is installed.
    func loadAPreviousBuild() {
        loaded[SignalBackgroundServiceManager.signalLabel] = "1-1-1"
        loaded[SignalBackgroundServiceManager.bridgeLabel] = "2-2-2"
    }

    /// launchctl accepts the command and the job does not come up on the new
    /// build — the 5 August failure, whatever its underlying cause turns out to
    /// have been.
    func refuseToStart() { startsSucceed = false }

    /// The transient cause clears. Needed to show that a retry after a failure
    /// actually brings the appliance back — without it a test can only prove
    /// something was attempted, not that attempting it was worth allowing.
    func allowStarts() {
        startsSucceed = true
        refusedLabels.removeAll()
    }

    /// The same failure for one job only.
    ///
    /// Needed because "all three refuse" cannot tell the interesting case from
    /// the boring one: the check being pinned is whether a reconcile notices a
    /// *third* job missing while the two it has always asked about are fine.
    /// With everything refusing, a check that still only looks at two would fail
    /// for the right reason by accident.
    func refuseToStartWhatsApp() {
        refusedLabels.insert(SignalBackgroundServiceManager.whatsAppLabel)
    }

    /// A job loaded behind Mynah's back — a leftover plist bootstrapped at
    /// login, or a hand-run launchctl.
    func loadStrayWhatsApp() {
        loaded[SignalBackgroundServiceManager.whatsAppLabel] = "stray-1-1"
    }

    func isLoaded(_ label: String) -> Bool { loaded[label] != nil }

    private var refusedLabels: Set<String> = []

    func forgetCalls() { calls = [] }

    func run(
        executable: URL,
        arguments: [String],
        timeout: TimeInterval
    ) async -> ProbeCommandResult? {
        calls.append(Call(executable: executable, arguments: arguments))

        switch arguments.first {
        case "bootstrap":
            guard startsSucceed,
                  !refusedLabels.contains(Self.label(ofPlistAt: arguments.last ?? "")) else {
                // Exit 0 and nothing loaded: launchctl accepted the command and
                // the job did not come up, which is the whole point.
                return ProbeCommandResult(exitCode: 0, standardOutput: "", standardError: "")
            }
            guard let path = arguments.last,
                  let plist = NSDictionary(contentsOfFile: path),
                  let environment = plist["EnvironmentVariables"] as? [String: String],
                  let stamp = environment["MYNAH_BUILD_STAMP"] else {
                return ProbeCommandResult(
                    exitCode: 5,
                    standardOutput: "",
                    standardError: "Bootstrap failed: 5: Input/output error"
                )
            }
            loaded[Self.label(ofPlistAt: path)] = stamp
            return ProbeCommandResult(exitCode: 0, standardOutput: "", standardError: "")

        case "bootout":
            // Non-zero when there was nothing to stop, the way the real one
            // answers on a first install.
            let label = Self.label(inDomainPath: arguments[1])
            let wasLoaded = loaded.removeValue(forKey: label) != nil
            return ProbeCommandResult(
                exitCode: wasLoaded ? 0 : 3,
                standardOutput: "",
                standardError: wasLoaded ? "" : "Boot-out failed: 3: No such process"
            )

        case "print":
            let label = Self.label(inDomainPath: arguments[1])
            guard let stamp = loaded[label] else {
                return ProbeCommandResult(
                    exitCode: 113,
                    standardOutput: "",
                    standardError: "Could not find service \"\(label)\" in domain for uid"
                )
            }
            return ProbeCommandResult(
                exitCode: 0,
                standardOutput: Self.printBody(label: label, stamp: stamp),
                standardError: ""
            )

        default:
            return ProbeCommandResult(exitCode: 0, standardOutput: "", standardError: "")
        }
    }

    /// Shaped after a capture from the owner's Mac, kept in
    /// `Tests/Fixtures/launchctl-print-stale-bridge.txt`. The `inherited
    /// environment` block is here on purpose: it comes first in launchctl's
    /// output, and a parser that took the first `MYNAH_BUILD_STAMP` it found
    /// would read the wrong one.
    private static func printBody(label: String, stamp: String) -> String {
        """
        \(label) = {
        \tactive count = 1
        \tstate = running
        \tinherited environment = {
        \t\tSSH_AUTH_SOCK => /private/tmp/com.apple.launchd.geWSOp95uS/Listeners
        \t}

        \tdefault environment = {
        \t\tPATH => /usr/bin:/bin:/usr/sbin:/sbin
        \t}

        \tenvironment = {
        \t\tOSLogRateLimit => 64
        \t\tMYNAH_BUILD_STAMP => \(stamp)
        \t\tXPC_SERVICE_NAME => \(label)
        \t}
        }
        """
    }

    private static func label(ofPlistAt path: String) -> String {
        URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent
    }

    private static func label(inDomainPath path: String) -> String {
        String(path.split(separator: "/").last ?? "")
    }
}
#endif  // os(macOS)
