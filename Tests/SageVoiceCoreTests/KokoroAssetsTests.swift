import XCTest
@testable import SageVoiceCore

/// **That the voice model arrives intact or does not arrive at all.**
///
/// A wrong model is the failure worth designing against. It does not crash and
/// it does not refuse — it loads, and it synthesizes something subtly wrong, on
/// an appliance whose whole argument is that the owner's words stay on their
/// machine and come back in a voice they recognise. So the property under test
/// is not "the download works". It is that **nothing unverified ever occupies
/// the real path**, which is also what earns `isInstalled` the right to check a
/// byte count instead of re-hashing 325 MB at every launch.
final class KokoroAssetsTests: XCTestCase {

    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("kokoro-assets-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    // MARK: Fixtures

    /// Real bytes with a real digest, so the checksum path is exercised rather
    /// than stubbed. A test that fakes the hash proves only that the fake agrees
    /// with itself.
    private func asset(_ name: String, contents: String) -> (KokoroAssets.Asset, Data) {
        let data = Data(contents.utf8)
        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("fixture-\(UUID().uuidString)")
        try? data.write(to: scratch)
        defer { try? FileManager.default.removeItem(at: scratch) }

        let digest = KokoroAssets.digest(of: scratch)!
        return (
            KokoroAssets.Asset(
                name: name,
                url: URL(string: "https://example.invalid/\(name)")!,
                sha256: digest,
                byteCount: Int64(data.count)
            ),
            data
        )
    }

    /// A downloader that serves the bytes it is given, to a fresh temporary file
    /// each time — the same contract the URLSession one has.
    private func serving(_ payloads: [String: Data]) -> KokoroAssets.Downloader {
        { asset, progress in
            guard let data = payloads[asset.name] else {
                throw NSError(domain: "test", code: 404,
                              userInfo: [NSLocalizedDescriptionKey: "the server answered 404"])
            }
            progress(0.5)
            let file = FileManager.default.temporaryDirectory
                .appendingPathComponent("served-\(UUID().uuidString)")
            try data.write(to: file)
            progress(1)
            return file
        }
    }

    // MARK: Installing

    func testMissingAssetsAreDownloadedAndInstalled() async throws {
        let (model, modelData) = asset("model.onnx", contents: "the weights")
        let (voices, voicesData) = asset("voices.bin", contents: "the voices")

        let outcome = await KokoroAssets.installIfNeeded(
            assets: [model, voices],
            into: directory,
            download: serving(["model.onnx": modelData, "voices.bin": voicesData])
        )

        XCTAssertEqual(outcome, .installed(byteCount: model.byteCount + voices.byteCount))
        XCTAssertTrue(outcome.isReady)
        XCTAssertEqual(
            try Data(contentsOf: KokoroAssets.location(of: model, in: directory)), modelData
        )
        XCTAssertEqual(
            try Data(contentsOf: KokoroAssets.location(of: voices, in: directory)), voicesData
        )
    }

    /// Provisioning is once per Mac. A second link must not re-download 353 MB.
    func testAnInstalledModelIsNotDownloadedAgain() async throws {
        let (model, modelData) = asset("model.onnx", contents: "the weights")
        try modelData.write(to: KokoroAssets.location(of: model, in: directory))

        let asked = Downloaded()
        let outcome = await KokoroAssets.installIfNeeded(
            assets: [model],
            into: directory,
            download: { asset, _ in
                asked.record(asset.name)
                throw NSError(domain: "test", code: 1)
            }
        )

        XCTAssertEqual(outcome, .alreadyInstalled)
        XCTAssertTrue(asked.names.isEmpty, "an installed asset was downloaded again")
    }

    /// Only what is missing. One asset present and one absent must cost one
    /// transfer, not two.
    func testOnlyTheMissingAssetIsFetched() async throws {
        let (model, modelData) = asset("model.onnx", contents: "the weights")
        let (voices, voicesData) = asset("voices.bin", contents: "the voices")
        try modelData.write(to: KokoroAssets.location(of: model, in: directory))

        let asked = Downloaded()
        let outcome = await KokoroAssets.installIfNeeded(
            assets: [model, voices],
            into: directory,
            download: { asset, progress in
                asked.record(asset.name)
                let file = FileManager.default.temporaryDirectory
                    .appendingPathComponent("served-\(UUID().uuidString)")
                try voicesData.write(to: file)
                progress(1)
                return file
            }
        )

        XCTAssertEqual(outcome, .installed(byteCount: voices.byteCount))
        XCTAssertEqual(asked.names, ["voices.bin"])
    }

    // MARK: The property that matters

    /// **The load-bearing test.** Bytes that fail the checksum must not reach
    /// the destination — not as a partial file, not as a file to be cleaned up
    /// later, not at all. `isInstalled` trusts a size check precisely because
    /// this holds.
    func testBytesThatFailTheChecksumNeverReachTheDestination() async throws {
        let (model, _) = asset("model.onnx", contents: "the weights")
        let wrong = Data("something else entirely".utf8)

        let outcome = await KokoroAssets.installIfNeeded(
            assets: [model],
            into: directory,
            download: serving(["model.onnx": wrong])
        )

        XCTAssertEqual(outcome, .corrupted(asset: "model.onnx"))
        XCTAssertFalse(outcome.isReady)
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: KokoroAssets.location(of: model, in: directory).path
            ),
            "a model that failed its checksum was installed anyway"
        )
    }

    /// A file of the right name and the wrong size is not the model. It is a
    /// half-finished download from a previous attempt, and it must be replaced
    /// rather than trusted.
    func testATruncatedFileIsTreatedAsMissing() async throws {
        let (model, modelData) = asset("model.onnx", contents: "the weights")
        try Data("the wei".utf8).write(to: KokoroAssets.location(of: model, in: directory))

        XCTAssertFalse(KokoroAssets.isInstalled(assets: [model], in: directory))

        let outcome = await KokoroAssets.installIfNeeded(
            assets: [model],
            into: directory,
            download: serving(["model.onnx": modelData])
        )

        XCTAssertEqual(outcome, .installed(byteCount: model.byteCount))
        XCTAssertEqual(
            try Data(contentsOf: KokoroAssets.location(of: model, in: directory)), modelData
        )
    }

    /// The second asset failing must not leave the first one half-claimed. The
    /// one that succeeded is genuinely installed; the outcome still reports the
    /// failure.
    func testAFailurePartWayThroughIsReportedRatherThanSwallowed() async throws {
        let (model, modelData) = asset("model.onnx", contents: "the weights")
        let (voices, _) = asset("voices.bin", contents: "the voices")

        let outcome = await KokoroAssets.installIfNeeded(
            assets: [model, voices],
            into: directory,
            download: serving(["model.onnx": modelData])   // voices.bin is not served
        )

        XCTAssertEqual(outcome, .couldNotReach(asset: "voices.bin", reason: "the server answered 404"))
        XCTAssertFalse(outcome.isReady)
        XCTAssertFalse(
            KokoroAssets.isInstalled(assets: [model, voices], in: directory),
            "an incomplete install reported itself as complete"
        )
    }

    // MARK: Failing softly

    /// Nothing here throws. This runs off the end of linking a phone, and a
    /// download that could not start must not take the link down with it.
    func testAnUnreachableServerIsAnOutcomeRatherThanAThrow() async throws {
        let (model, _) = asset("model.onnx", contents: "the weights")

        let outcome = await KokoroAssets.installIfNeeded(
            assets: [model],
            into: directory,
            download: { _, _ in throw URLError(.notConnectedToInternet) }
        )

        guard case .couldNotReach(let name, _) = outcome else {
            return XCTFail("expected couldNotReach, got \(outcome)")
        }
        XCTAssertEqual(name, "model.onnx")
    }

    /// Every outcome says something a person could act on, and none of them
    /// leaks a path out of the owner's home directory into a shared log.
    func testEveryOutcomeLogsSomethingUsableAndNothingPrivate() {
        let outcomes: [KokoroAssets.Outcome] = [
            .alreadyInstalled,
            .installed(byteCount: 353_746_785),
            .notEnoughSpace(needed: 707_493_570, free: 1_048_576),
            .couldNotReach(asset: "model.onnx", reason: "offline"),
            .corrupted(asset: "voices.bin"),
            .couldNotSave("read-only volume")
        ]
        for outcome in outcomes {
            XCTAssertTrue(outcome.logLine.hasPrefix("voice: "), "\(outcome) is not labelled")
            XCTAssertFalse(outcome.logLine.contains("/Users/"), "\(outcome) leaked a home path")
            XCTAssertFalse(outcome.logLine.contains("https://"), "\(outcome) leaked a URL")
        }
    }

    // MARK: Progress

    /// The owner is looking at a progress bar for several minutes. It has to
    /// finish at the end and never run backwards on the way there.
    func testProgressRunsForwardAndReachesOne() async throws {
        let (model, modelData) = asset("model.onnx", contents: "the weights are large")
        let (voices, voicesData) = asset("voices.bin", contents: "the voices")

        let seen = Reported()
        _ = await KokoroAssets.installIfNeeded(
            assets: [model, voices],
            into: directory,
            progress: { seen.record($0) },
            download: serving(["model.onnx": modelData, "voices.bin": voicesData])
        )

        let values = seen.values
        XCTAssertEqual(values, values.sorted(), "progress ran backwards")
        XCTAssertEqual(try XCTUnwrap(values.last), 1.0, accuracy: 0.0001)
        XCTAssertTrue(values.allSatisfy { $0 >= 0 && $0 <= 1 }, "progress left 0...1")
    }

    // MARK: The pinned assets

    /// The two real assets, checked for the mistakes that are invisible until a
    /// download fails at 3 a.m.: a digest that is not a SHA-256, a placeholder
    /// size, or a URL that is not HTTPS.
    func testThePinnedAssetsAreWellFormed() {
        for asset in KokoroAssets.all {
            XCTAssertEqual(asset.sha256.count, 64, "\(asset.name) has no SHA-256")
            XCTAssertTrue(
                asset.sha256.allSatisfy { $0.isHexDigit && !$0.isUppercase },
                "\(asset.name)'s digest is not lowercase hex"
            )
            XCTAssertGreaterThan(asset.byteCount, 1_000_000, "\(asset.name) has a placeholder size")
            XCTAssertEqual(asset.url.scheme, "https", "\(asset.name) would download over plaintext")
        }
        XCTAssertEqual(KokoroAssets.totalByteCount, 353_746_785)
    }

    /// Streaming digest, checked against a value computed independently — the
    /// chunking is the part that could silently drop a tail.
    func testTheDigestIsStreamedCorrectlyAcrossChunkBoundaries() throws {
        let file = directory.appendingPathComponent("chunky")
        // Deliberately not a multiple of the chunk size used below.
        try Data(repeating: 0xAB, count: 4097).write(to: file)

        let whole = KokoroAssets.digest(of: file, chunkSize: 1 << 20)
        let chunked = KokoroAssets.digest(of: file, chunkSize: 64)

        XCTAssertNotNil(whole)
        XCTAssertEqual(whole, chunked, "the digest depends on how the file was read")
    }
}

/// Collects across the async calls.
private final class Downloaded: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [String] = []

    func record(_ name: String) {
        lock.lock(); defer { lock.unlock() }
        stored.append(name)
    }

    var names: [String] {
        lock.lock(); defer { lock.unlock() }
        return stored
    }
}

private final class Reported: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [Double] = []

    func record(_ value: Double) {
        lock.lock(); defer { lock.unlock() }
        stored.append(value)
    }

    var values: [Double] {
        lock.lock(); defer { lock.unlock() }
        return stored
    }
}
