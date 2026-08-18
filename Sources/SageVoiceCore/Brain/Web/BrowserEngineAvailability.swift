import Foundation
#if canImport(ObjectiveC)
import ObjectiveC.runtime
#endif

/// Whether this process may start a browser engine.
///
/// ## What this exists to stop
///
/// On 5 August 2026 the owner asked Signal for something that needed a web
/// search. The appliance said *"I'm on it. It'll take a few minutes — I'll let
/// you know the moment it's done."* and then died: `EXC_BREAKPOINT` inside
/// `WebKit::InitializeWebKit2()`, reached from `WKWebViewConfiguration.init()`
/// in `BrowserSearchBackend.load`. launchd restarted the daemon three seconds
/// later and nothing ever reached his phone. He asked the same question in the
/// Mac window a minute afterwards and had an answer, with sources, in seven
/// seconds.
///
/// WebKit2 does not decline to start outside an application. It **traps**, and
/// that difference is the whole design here. A provider that fails can be caught
/// and fallen through — `WebSearchToolSource` has a chain behind it for exactly
/// that. A provider that kills the process cannot: no `catch`, no deadline, no
/// retry and no fallback runs after a `SIGTRAP`. Code placed behind it is
/// unreachable, which is why `DuckDuckGoSearchBackend`, sitting last in the
/// chain and written to be the floor nobody falls through, never once ran in the
/// appliance.
///
/// ## Why a value rather than a compile-time check
///
/// The guard was `#if canImport(WebKit)`. That is true of every macOS build of
/// **both** targets, so it never distinguished the window from the daemon —
/// it read like a safety check and was a portability check.
///
/// ## Why it fails closed at both ends
///
/// The default is `.unavailable`, everywhere, including tests. The costs are not
/// symmetric: a process that wrongly *omits* the browser gets slightly worse
/// search results, and a process that wrongly *includes* it takes the owner's
/// appliance down mid-sentence. So the safe answer is the one you get by saying
/// nothing.
///
/// The opt-in fails closed too, and that is the less obvious half. The first
/// draft of this took `AnyObject?` and reported available for anything non-nil —
/// which reads as safe and is not, because `makeToolSource` in the daemon has a
/// live `mcp` client and a `notes` source in scope at the exact line somebody
/// would edit to "turn search back on". A doc comment saying *intended to be
/// called with `NSApp`* is not a check. So `hostedBy` verifies the object really
/// is an `NSApplication`, by walking the Objective-C superclass chain.
///
/// ## Why the class is checked by name instead of importing AppKit
///
/// Two reasons, either sufficient. `NSApp` is `NS_SWIFT_UI_ACTOR`, so reading it
/// is main-actor isolated — and `WebSearchToolSource.defaultBackends()` is
/// called synchronously, off the main thread, during daemon start-up. Reading it
/// there would need either an `await` (an isolation hop in start-up: precisely
/// the shape written up in `sage-voiced/main.swift` as the cause of a
/// twenty-eight hour outage) or `MainActor.assumeIsolated`, which traps off the
/// main thread. Handing the value in as a parameter needs neither.
///
/// And `SageVoiceCore` is linked by both binaries, so an `import AppKit` here is
/// an import in the daemon as well. That is the cheaper of the two costs —
/// WebKit already pulls AppKit into `sage-voiced` at launch through a non-weak
/// dependency, so the framework is mapped either way — but the isolation
/// argument stands on its own.
public struct BrowserEngineAvailability: Sendable, Equatable {

    public let isAvailable: Bool

    private init(isAvailable: Bool) {
        self.isAvailable = isAvailable
    }

    /// No browser engine. The default for every caller that does not say
    /// otherwise: the daemon, the CLI subcommands, and the test runner.
    public static let unavailable = BrowserEngineAvailability(isAvailable: false)

    /// Available only if `application` is a live `NSApplication`.
    ///
    /// Meant to be called as `.hostedBy(NSApp)` from a main-actor context in the
    /// window app, and it is written so that calling it with anything else is
    /// harmless rather than fatal. `NSApp` is `nil` until an `NSApplication`
    /// exists and reading it does not create one — unlike
    /// `NSApplication.shared`, which does, and which must never be used to
    /// answer this question.
    ///
    /// The class check is the part that matters. Without it this is a function
    /// that says "yes" to any object at all, in a codebase whose most-repeated
    /// defect is a change made at one call site while an identical one goes
    /// unwatched.
    ///
    /// **Off Darwin it is `.unavailable` and cannot be anything else**, which is
    /// the truth rather than a stub: there is no `NSApplication` to be handed,
    /// and `BrowserSearchBackend` — the only thing this gate has ever opened —
    /// is not compiled at all, because it is `WKWebView` from top to bottom.
    /// `WebSearchToolSource` already asks `canImport(WebKit)` before it reaches
    /// for the browser backend, so this answer and that guard agree.
    ///
    /// The check is written as a whole-body `#if` rather than by stubbing
    /// `isAnApplication` to `false`, so that a future port which does gain a
    /// browser engine has to come here and say so, instead of inheriting a
    /// permanently-closed door it cannot see.
    public static func hostedBy(_ application: AnyObject?) -> BrowserEngineAvailability {
        #if canImport(ObjectiveC)
        guard let application else { return .unavailable }
        return isAnApplication(type(of: application)) ? BrowserEngineAvailability(isAvailable: true) : .unavailable
        #else
        return .unavailable
        #endif
    }

    /// Whether `candidate` is `NSApplication` or descends from it.
    ///
    /// By name, walking the superclass chain, so a subclass — which an app is
    /// entitled to have, and which `NSApp`'s own `__kindof NSApplication`
    /// declaration anticipates — is still recognised.
    #if canImport(ObjectiveC)
    static func isAnApplication(_ candidate: AnyClass) -> Bool {
        var cursor: AnyClass? = candidate
        while let current = cursor {
            if String(cString: class_getName(current)) == "NSApplication" { return true }
            cursor = class_getSuperclass(current)
        }
        return false
    }
    #endif
}
