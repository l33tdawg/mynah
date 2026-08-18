import Foundation

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

extension Process {

    /// Waits for the child to exit without parking the main run loop.
    ///
    /// **`waitUntilExit()` is not safe off Darwin.** swift-corelibs-foundation
    /// implements it as `RunLoop.run(mode:before:)`, and that call can block
    /// forever ignoring the date it was given: CFRunLoop asks `ppoll` for an
    /// *untimed* sleep and relies on a libdispatch timer to wake it, so when
    /// that wake-up is lost the loop never returns. Reproduced on 6.0, 6.0.3,
    /// 6.1 and 6.2, on x86_64 and arm64, in a package containing no project
    /// code at all — it is the toolchain, not us. It is the same fault that
    /// wedged the Linux test suite, and the suite could grow a watchdog to
    /// survive it. `sage-voiced` ships no watchdog, so a call reached on the
    /// main thread does not come back.
    ///
    /// Polling is what `MCPClient.stop()` already does, for the same reason,
    /// and its comment says so. This is that decision applied everywhere the
    /// off-Darwin build compiles a wait.
    ///
    /// **Every caller drains the pipe to EOF first**, so by the time this runs
    /// the child has written everything it will ever write and is exiting. The
    /// loop is a reap, not a wait, and in practice ends on its first pass.
    ///
    /// On Darwin this forwards to `waitUntilExit()` unchanged, so the shipped
    /// Mac behaviour is exactly what it was.
    public func waitForExitWithoutBlockingTheRunLoop(
        pollSeconds: TimeInterval = 0.02
    ) {
        #if canImport(Darwin)
        waitUntilExit()
        #else
        while isRunning {
            Thread.sleep(forTimeInterval: pollSeconds)
        }
        #endif
    }
}
