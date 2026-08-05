import XCTest
@testable import SageVoiceCore

/// Nothing outside the window app may arm a browser engine.
///
/// ## What this is guarding
///
/// On 5 August 2026 the appliance died mid-sentence: `EXC_BREAKPOINT` inside
/// `WebKit::InitializeWebKit2()`, reached from `WKWebViewConfiguration.init()`
/// in `BrowserSearchBackend.load`, in `sage-voiced` — a launchd daemon with no
/// `NSApplication`. It had just told the owner *"I'm on it… I'll let you know
/// the moment it's done."* launchd restarted it three seconds later and nothing
/// ever reached his phone.
///
/// ## Why a source scan and not a behavioural test
///
/// Because the behaviour cannot be tested and the existing tests cannot see the
/// fix. Three tests already call `defaultBackends()` and assert on provider
/// names, and **every one of them passes identically before and after the
/// change** — nothing turns red to say it took effect. The one thing that must
/// stay true is a property of the *source*: that exactly one place constructs a
/// browser backend, that it is gated, and that only the app passes an armed
/// token.
///
/// And it cannot be tested by running it. The test bundle is itself not an
/// application, so a test that reached `BrowserSearchBackend.load` would trap
/// the runner exactly as the daemon trapped — the whole suite would die, which
/// is a worse outcome than the bug. Reading the source touches no WebKit.
///
/// Modelled on `NoTimerRacedInATaskGroupTests`, including its non-vacuity
/// sentinels: a guard that finds nothing must fail rather than pass, or a rename
/// silently retires it.
final class NoBrowserEngineOutsideTheAppTests: XCTestCase {

    private func sourceFiles(under directory: String) throws -> [URL] {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent(directory, isDirectory: true)
        let files = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)?
            .compactMap { $0 as? URL }
            .filter { $0.pathExtension == "swift" } ?? []
        XCTAssertFalse(files.isEmpty, "found no Swift sources under \(directory), so this guard is checking nothing")
        return files
    }

    /// The construction happens once, and only behind the runtime gate.
    func testTheOnlyBrowserBackendConstructionIsGated() throws {
        var sites: [String] = []
        for file in try sourceFiles(under: "Sources") {
            guard let source = try? String(contentsOf: file, encoding: .utf8) else { continue }
            let scan = SwiftSourceScan(source)
            for index in scan.indices(of: "BrowserSearchBackend()") {
                sites.append("\(file.lastPathComponent):\(scan.line(of: index))")
                // The 200 characters in front of the construction. The gate is
                // an `if` immediately above it, so anything further away is not
                // guarding this line.
                let window = scan.text(in: max(0, index - 200)..<index)
                XCTAssertTrue(
                    window.contains("browserEngine.isAvailable"),
                    """
                    \(file.lastPathComponent):\(scan.line(of: index)) builds a browser \
                    backend without the runtime gate in front of it. WebKit2 does not \
                    decline to start outside an application, it traps the process — so \
                    this line is not a search provider, it is a way to kill the daemon.
                    """
                )
            }
        }

        // Non-vacuity, in the direction that matters. Zero sites would mean the
        // type was renamed and this guard is reading for a string that no longer
        // exists, which is indistinguishable from success.
        XCTAssertEqual(
            sites.count, 1,
            """
            expected exactly one construction of BrowserSearchBackend in Sources/, found \
            \(sites.count): \(sites.joined(separator: ", ")). One gated site is what makes \
            the gate meaningful; a second one is a second way to crash the appliance, and \
            zero means this guard has stopped guarding anything.
            """
        )
    }

    /// Only the window app may pass an armed token, and only from one place.
    ///
    /// `Sources/SageVoiceCore` is included in the forbidden set deliberately.
    /// The library is what `sage-voiced` links, so an armed token handed over
    /// inside it reaches the daemon just as surely as one written in
    /// `main.swift` — and that is the recurrence path a `internal` on the type
    /// would leave wide open.
    func testNothingOutsideTheWindowAppArmsTheEngine() throws {
        for directory in ["Sources/sage-voiced", "Sources/SageVoiceCore", "Sources/Mynah"] {
            for file in try sourceFiles(under: directory) {
                guard let source = try? String(contentsOf: file, encoding: .utf8) else { continue }
                let scan = SwiftSourceScan(source)
                for index in scan.indices(of: "browserEngine:") {
                    // The declaration of the parameter itself is not a call.
                    let statement = scan.statement(at: index)
                    guard !statement.contains("BrowserEngineAvailability = .unavailable") else { continue }
                    XCTFail(
                        """
                        \(file.lastPathComponent):\(scan.line(of: index)) passes a browserEngine \
                        argument outside the window app: \(statement). Only a process with a live \
                        NSApplication may start WebKit; everything here runs in the daemon, where \
                        it traps.
                        """
                    )
                }
            }
        }
    }

    /// And the app's single armed site is the main-actor one.
    func testTheAppArmsTheEngineExactlyOnceAndFromNSApp() throws {
        var armed: [String] = []
        for file in try sourceFiles(under: "Sources/MynahMac") {
            guard let source = try? String(contentsOf: file, encoding: .utf8) else { continue }
            let scan = SwiftSourceScan(source)
            for index in scan.indices(of: "BrowserEngineAvailability.hostedBy(") {
                armed.append("\(file.lastPathComponent):\(scan.line(of: index))")
                XCTAssertTrue(
                    scan.statement(at: index).contains("hostedBy(NSApp)"),
                    """
                    \(file.lastPathComponent):\(scan.line(of: index)) arms the browser engine from \
                    something other than NSApp: \(scan.statement(at: index)). NSApp being non-nil \
                    is the evidence that an NSApplication exists; any other object is a guess.
                    """
                )
            }
        }
        XCTAssertEqual(
            armed.count, 1,
            """
            expected exactly one site in MynahMac arming the browser engine, found \
            \(armed.count): \(armed.joined(separator: ", ")). Zero means the window silently \
            lost its best search provider; more than one means a second surface can arm WebKit \
            without this guard having been read.
            """
        )
    }

    // MARK: The token itself

    /// The opt-in fails closed for anything that is not an application.
    ///
    /// This is the half that a doc comment cannot enforce. The first draft of
    /// `hostedBy` reported "available" for any non-nil object — and the daemon's
    /// `makeToolSource` has a live MCP client and a notes source in scope at the
    /// exact line somebody would edit to turn search back on.
    func testOnlyAnApplicationArmsTheEngine() {
        XCTAssertFalse(BrowserEngineAvailability.unavailable.isAvailable)
        XCTAssertFalse(BrowserEngineAvailability.hostedBy(nil).isAvailable)
        XCTAssertFalse(
            BrowserEngineAvailability.hostedBy(NSObject()).isAvailable,
            "a bare object armed the browser engine, so the opt-in trusts its caller instead of checking"
        )
        XCTAssertFalse(
            BrowserEngineAvailability.hostedBy(Bundle.main).isAvailable,
            "a Foundation object armed the browser engine"
        )
    }

    /// And it recognises a real application, including a subclass.
    ///
    /// Checked by name against the runtime rather than by importing AppKit,
    /// because this test target must not create an `NSApplication` — doing so is
    /// what the whole guard exists to keep out of non-app processes.
    func testAnApplicationSubclassIsStillAnApplication() throws {
        let application = try XCTUnwrap(
            NSClassFromString("NSApplication"),
            "AppKit is not loaded in this test process, so this check cannot run"
        )
        XCTAssertTrue(BrowserEngineAvailability.isAnApplication(application))

        // A subclass, which `NSApp`'s own `__kindof NSApplication` declaration
        // anticipates and which an app is entitled to have.
        let subclass = try XCTUnwrap(
            objc_allocateClassPair(application, "MynahTestApplicationSubclass", 0),
            "could not build a subclass to test with"
        )
        objc_registerClassPair(subclass)
        XCTAssertTrue(
            BrowserEngineAvailability.isAnApplication(subclass),
            "an NSApplication subclass was not recognised, so an app with its own principal class loses web search"
        )

        XCTAssertFalse(BrowserEngineAvailability.isAnApplication(NSObject.self))
    }
}
