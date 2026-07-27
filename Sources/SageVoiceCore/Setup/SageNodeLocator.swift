import Foundation

/// Finds the SAGE node this appliance should talk to, and starts it.
///
/// ## Why there is no "install SAGE" step
///
/// SAGE ships inside this app, vendored at build time into
/// `Contents/Resources/SAGE.app` and codesigned as part of our bundle. That is
/// the arrangement QuietType already ships, and it is deliberate:
///
///  - A vendored bundle inherits this app's notarization, so it launches with
///    no Gatekeeper prompt and nothing for the owner to approve.
///  - An app downloaded at runtime and copied into `/Applications` carries a
///    `com.apple.quarantine` flag, needs privileges we would have to ask for,
///    and is exactly the shape a user is right to be suspicious of.
///
/// So the normal path is: the node is already here, start it. Downloading is a
/// fallback for a build that was not vendored, and even then this type does not
/// silently install — see `SageNodeInstaller`.
public enum SageNodeLocator {
    /// Executable name inside a SAGE app bundle.
    public static let executableName = "sage-gui"

    /// The bundle identifier a genuine SAGE.app carries. Checked before we run
    /// anything, so a stray directory of the right name cannot get executed.
    public static let expectedBundleIdentifier = "com.sage.brain"

    /// `SAGE.app` vendored inside the running app's `Resources`.
    ///
    /// `nil` under `swift test` and for the CLI harness, where there is no app
    /// bundle — which is correct, not a failure.
    public static func vendoredExecutableURL(bundle: Bundle = .main) -> URL? {
        guard let resources = bundle.resourceURL else { return nil }
        let candidate = resources
            .appendingPathComponent("SAGE.app/Contents/MacOS/\(executableName)")
        return FileManager.default.isExecutableFile(atPath: candidate.path) ? candidate : nil
    }

    /// Verifies that a path really is a SAGE app bundle before we run it.
    ///
    /// Mirrors `require_sage_app` in QuietType's vendoring script. The bundle-id
    /// check is the one that matters: everything else confirms the layout, but
    /// only this confirms identity.
    public static func verifyBundle(
        at appURL: URL,
        fileManager: FileManager = .default
    ) -> Result<URL, SageNodeError> {
        let executable = appURL.appendingPathComponent("Contents/MacOS/\(executableName)")
        let plist = appURL.appendingPathComponent("Contents/Info.plist")

        guard fileManager.fileExists(atPath: appURL.path) else {
            return .failure(.notFound(appURL.path))
        }
        guard fileManager.isExecutableFile(atPath: executable.path) else {
            return .failure(.notRunnable(executable.path))
        }
        guard let data = try? Data(contentsOf: plist),
              let info = try? PropertyListSerialization.propertyList(
                  from: data, options: [], format: nil
              ) as? [String: Any] else {
            return .failure(.malformedBundle("missing or unreadable Info.plist at \(plist.path)"))
        }
        let identifier = info["CFBundleIdentifier"] as? String
        guard identifier == expectedBundleIdentifier else {
            return .failure(.unexpectedBundleIdentifier(
                found: identifier ?? "none",
                expected: expectedBundleIdentifier
            ))
        }
        return .success(executable)
    }

    /// Bundle version string, for reporting which node we are about to run.
    public static func bundleVersion(at appURL: URL) -> String? {
        let plist = appURL.appendingPathComponent("Contents/Info.plist")
        guard let data = try? Data(contentsOf: plist),
              let info = try? PropertyListSerialization.propertyList(
                  from: data, options: [], format: nil
              ) as? [String: Any] else {
            return nil
        }
        return info["CFBundleShortVersionString"] as? String
    }

    /// The app bundle containing an executable path, or `nil` if it is a bare
    /// binary on `PATH` rather than something in a bundle.
    public static func appBundle(containing executable: URL) -> URL? {
        // …/SAGE.app/Contents/MacOS/sage-gui -> …/SAGE.app
        let bundle = executable
            .deletingLastPathComponent()   // MacOS
            .deletingLastPathComponent()   // Contents
            .deletingLastPathComponent()   // SAGE.app
        return bundle.pathExtension == "app" ? bundle : nil
    }
}

public enum SageNodeError: Error, Equatable, CustomStringConvertible {
    case notFound(String)
    case notRunnable(String)
    case malformedBundle(String)
    case unexpectedBundleIdentifier(found: String, expected: String)
    case launchFailed(String)

    public var description: String {
        switch self {
        case .notFound(let path):
            return "No SAGE app bundle at \(path)."
        case .notRunnable(let path):
            return "SAGE bundle is not runnable; no executable at \(path)."
        case .malformedBundle(let detail):
            return "SAGE bundle is malformed: \(detail)"
        case .unexpectedBundleIdentifier(let found, let expected):
            return "Refusing to run \(found.isEmpty ? "an unidentified bundle" : found) as SAGE; expected \(expected)."
        case .launchFailed(let detail):
            return "Could not start the SAGE node: \(detail)"
        }
    }
}
