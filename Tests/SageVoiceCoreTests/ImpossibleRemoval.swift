import Foundation

// `geteuid()`, `chflags()` and `dlsym()` are libc, and nothing re-exports them
// off Darwin.
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif

/// A removal this process cannot perform, staged over a directory.
///
/// **This is shared because a test that skips is a test that does not exist,
/// and two suites had reached that state over the same product path.**
/// `PauseState.setPaused(false)` deletes the pause flag, and its failure branch
/// — the one that stops a tool printing "answering again" over a flag still on
/// disk — is exercised by exactly two tests: `SettingsWithoutTheMacTests`
/// covers `PauseState` itself, `SettingsFromAShellTests` covers the
/// `sage-voiced settings resume` shim over it. Both stage the failure the same
/// way, by taking write permission off the directory the flag sits in.
///
/// A root process walks past that mode, so both tests began life skipping
/// under root. `.github/workflows/linux.yml` runs the suite in
/// `swift:6.0.3-jammy`, where every process is uid 0 — so on the only Linux
/// this port is tested on, both skipped, and the failure branch of the only
/// pause control an off-Darwin owner has had never once executed off Darwin
/// while the run reported itself complete. The shim's test was given this
/// mechanism when the Linux port landed and the store's test was not, so the
/// machinery sat as a private method of one `XCTestCase` where the other could
/// not reach it. It lives here so that neither copy can drift and no third
/// caller has to invent a fourth trick.
///
/// **Tricks that were tried and do not work**, so nobody spends the afternoon
/// again: `removeItem` on a non-empty directory deletes it recursively rather
/// than refusing, and a symlink into an unwritable directory is removed as
/// itself.
enum ImpossibleRemoval {

    /// Everything in `holder` made impossible for **this process** to remove,
    /// and the undo. Call `putItBack()` before the directory is torn down.
    ///
    /// **Write the file the test asserts on into `holder` before calling
    /// this.** The Darwin arm gives the root bypass up by making the entries
    /// that exist at this moment immutable, so anything created afterwards
    /// would be the one thing still deletable — a test staged in the wrong
    /// order would pass by removing a file nothing was protecting.
    ///
    /// Taking write permission off the directory is the real case — a state
    /// directory the owner cannot write — and for the user these suites
    /// normally run as, the mode is the whole mechanism. When the process is
    /// root the *bypass* is given up for the duration rather than the test —
    /// the capability on Linux, per-file immutability on Darwin — and the same
    /// directory mode then does the same work it does for an owner. The
    /// product sees an ordinary refusal from the filesystem either way;
    /// nothing about `PauseState` or `HeadlessSettings` is faked.
    ///
    /// Proved on a decoy before the caller asserts anything, because a
    /// mechanism that silently failed to take would leave the removal
    /// succeeding — and a test that passed anyway would be reporting a control
    /// it never exercised, which is the thing being tested for.
    static func staged(in holder: URL) throws -> () -> Void {
        let manager = FileManager.default
        // Not the flag the caller is about to assert on: proving the mechanism
        // must not be the thing that consumes it.
        let decoy = holder.appendingPathComponent("decoy", isDirectory: false)
        try Data().write(to: decoy)

        var undo: [() -> Void] = []
        func putItBack() { for step in undo.reversed() { step() } }

        if geteuid() == 0 {
            guard let restored = releaseTheRootBypass(over: holder) else {
                putItBack()
                throw CannotStageAFailedRemoval(holder: holder.path)
            }
            undo.append(restored)
        }
        try manager.setAttributes([.posixPermissions: 0o500], ofItemAtPath: holder.path)
        undo.append {
            try? manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: holder.path)
        }

        let cameAwayAnyway: Bool
        do {
            try manager.removeItem(at: decoy)
            cameAwayAnyway = true
        } catch {
            cameAwayAnyway = false
        }
        guard !cameAwayAnyway else {
            putItBack()
            throw CannotStageAFailedRemoval(holder: holder.path)
        }
        return putItBack
    }

    /// The one part of being root this needs taken away: the right to ignore a
    /// directory's mode. `nil` when the system offers no way to give it up, and
    /// the caller then fails loudly rather than passing on an unstaged test.
    private static func releaseTheRootBypass(over holder: URL) -> (() -> Void)? {
        #if canImport(Darwin)
        // Darwin has no capability model, so the files are made immutable
        // instead: `unlink` refuses an immutable file for uid 0 as well — root
        // has to clear the flag first, which is precisely the step a `resume`
        // does not take.
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: holder, includingPropertiesForKeys: nil
        ) else { return nil }
        for entry in entries {
            _ = entry.withUnsafeFileSystemRepresentation { chflags($0, UInt32(UF_IMMUTABLE)) }
        }
        return {
            for entry in entries {
                _ = entry.withUnsafeFileSystemRepresentation { chflags($0, 0) }
            }
        }
        #elseif canImport(Glibc) || canImport(Musl)
        return LinuxCapabilities.withoutTheRightToIgnoreADirectoryMode()
        #else
        return nil
        #endif
    }

    /// A dead end with a door on it: what could not be staged, and what to do
    /// about it. `LocalizedError` as well, because XCTest reports a thrown
    /// error through `localizedDescription`, which for a bare `Error` off
    /// Darwin is a sentence with none of this in it.
    private struct CannotStageAFailedRemoval: Error, LocalizedError, CustomStringConvertible {
        let holder: String

        var description: String {
            """
            this process can still delete files inside \(holder) with write \
            permission taken off it, so the resume-that-cannot-clear-the-flag \
            the calling test is about cannot be staged here — and the test will \
            not skip, because that failure path is the only thing standing \
            between an owner and an appliance that says it is answering while \
            the flag is still on disk.
            Run the suite as a non-root user, or on a Linux where \
            CAP_DAC_OVERRIDE can be dropped from this thread.
            """
        }

        var errorDescription: String? { description }
    }
}

#if canImport(Glibc) || canImport(Musl)
/// `capget`/`capset`, by symbol rather than by header.
///
/// The declarations live in `<sys/capability.h>`, which belongs to libcap and
/// is not something the Glibc module exposes; the two symbols themselves are in
/// libc, and the structures are kernel ABI pinned by the version word. Reached
/// through `dlsym` so that a system without them is a `nil` the caller reports,
/// not a link error that stops this file compiling.
private enum LinuxCapabilities {

    private struct Header {
        /// `_LINUX_CAPABILITY_VERSION_3`, which is the 64-bit-capability layout
        /// and the reason `Words` is asked for in twos.
        var version: UInt32 = 0x2008_0522
        /// Zero means this thread.
        var pid: Int32 = 0
    }

    private struct Words {
        var effective: UInt32 = 0
        var permitted: UInt32 = 0
        var inheritable: UInt32 = 0
    }

    private typealias Call =
        @convention(c) (UnsafeMutableRawPointer?, UnsafeMutableRawPointer?) -> Int32

    /// `CAP_DAC_OVERRIDE`, `CAP_DAC_READ_SEARCH` and `CAP_FOWNER` — the three
    /// that let uid 0 walk past a mode that would stop an owner — dropped from
    /// the effective set, and the undo.
    ///
    /// They stay in the *permitted* set, so raising them again always works,
    /// and a bit the container never granted is masked out of a set it was not
    /// in: lowering the effective set is the one capset the kernel cannot
    /// refuse, which is why this does not depend on how the container was
    /// started. Capabilities are per-thread on Linux, so this touches only the
    /// thread the test is running on: no `SIGSETXID` broadcast, nothing for
    /// another thread to answer, and nothing a wedged one could hold up.
    static func withoutTheRightToIgnoreADirectoryMode() -> (() -> Void)? {
        guard let image = dlopen(nil, RTLD_NOW),
            let read = dlsym(image, "capget").map({ unsafeBitCast($0, to: Call.self) }),
            let write = dlsym(image, "capset").map({ unsafeBitCast($0, to: Call.self) })
        else { return nil }

        var header = Header()
        var held = [Words](repeating: Words(), count: 2)
        guard read(&header, &held) == 0 else { return nil }

        let toRestore = held
        let bypass: UInt32 = (1 << 1) | (1 << 2) | (1 << 3)
        var reduced = held
        reduced[0].effective &= ~bypass
        guard write(&header, &reduced) == 0 else { return nil }

        return {
            var header = Header()
            var restored = toRestore
            _ = write(&header, &restored)
        }
    }
}
#endif
