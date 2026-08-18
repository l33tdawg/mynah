import Foundation
import XCTest
@testable import SageVoiceCore

/// The local brain was refused on every machine that was not a Mac, however
/// large — and the refusal described somebody else's hardware.
///
/// `LocalModelCapability.forMachine` gated on `isAppleSilicon`, which
/// `SystemHardwareProbe` hardcodes to `false` off Darwin because the question it
/// asks is "is Metal available". So a 128 GB Threadripper with a 4090 in the
/// slot — a machine that answers a routing turn faster than the reference M2
/// mini does — was told *"Running the brain on this Mac needs Apple Silicon —
/// on an Intel chip a reply takes far too long to be spoken conversation."* Four
/// claims, none of them true about the box printing them, on the one screen an
/// owner cannot get past.
///
/// Everything here is a synthetic `HardwareReport` carrying its own
/// `platform`, so **every case runs identically on both platforms**: a Mac
/// proves the Linux verdicts and Linux proves the Mac ones. That is deliberate.
/// A rule that can only be exercised on the machine it is wrong about is how
/// this one survived to 2.3.0.
final class ALinuxBoxIsNotAnIntelMacTests: XCTestCase {

    private let planner = BrainSetupPlanner()

    private static let gib: UInt64 = 1024 * 1024 * 1024

    // MARK: - Synthetic machines

    /// The owner's Linux box: 128 GB, 32 cores, a 4090 in the slot. Nothing in
    /// the report can see the 4090 — that is exactly the situation the new rule
    /// has to be honest about rather than guess its way out of.
    private static func linuxTower(memoryGiB: UInt64 = 128) -> HardwareReport {
        HardwareReport(
            physicalMemoryBytes: memoryGiB * gib,
            freeDiskBytes: 2_000_000_000_000,
            modelStorageDirectory: "/home/owner/.ollama/models",
            cpuBrand: "AMD Ryzen Threadripper PRO 5975WX 32-Cores",
            physicalCoreCount: 32,
            isAppleSilicon: false,
            platform: .linux
        )
    }

    /// A Linux machine that genuinely cannot do this: a 4 GB single-board
    /// computer. The weights alone are 3.4 GB.
    private static func smallLinuxBox() -> HardwareReport {
        var report = linuxTower(memoryGiB: 4)
        report.cpuBrand = "ARMv8 Processor rev 3"
        report.physicalCoreCount = 4
        report.freeDiskBytes = 60_000_000_000
        return report
    }

    private static func appleSiliconMac(memoryGiB: UInt64) -> HardwareReport {
        HardwareReport(
            physicalMemoryBytes: memoryGiB * gib,
            freeDiskBytes: 400_000_000_000,
            modelStorageDirectory: "/Users/owner/.ollama/models",
            cpuBrand: "Apple M2",
            physicalCoreCount: 8,
            isAppleSilicon: true,
            platform: .darwin
        )
    }

    private static func intelMac() -> HardwareReport {
        HardwareReport(
            physicalMemoryBytes: 32 * gib,
            freeDiskBytes: 400_000_000_000,
            modelStorageDirectory: "/Users/owner/.ollama/models",
            cpuBrand: "Intel(R) Core(TM) i9-9880H CPU @ 2.30GHz",
            physicalCoreCount: 8,
            isAppleSilicon: false,
            platform: .darwin
        )
    }

    /// Daemon up, chat model and embedding model both pulled — `isReadyToServe`.
    private static let ollamaServing = LocalModelRuntimeReport(
        isRuntimeInstalled: true,
        runtimeExecutablePath: "/usr/local/bin/ollama",
        isDaemonReachable: true,
        installedModels: ["qwen3.5:4b", "nomic-embed-text"]
    )

    private func probe(
        _ hardware: HardwareReport,
        runtime: LocalModelRuntimeReport = LocalModelRuntimeReport()
    ) -> EnvironmentProbeResult {
        EnvironmentProbeResult(
            localRuntime: runtime,
            agentCLIs: AgentCLIKind.allCases.map { AgentCLIReport(kind: $0) },
            hardware: hardware
        )
    }

    private func localOption(
        _ hardware: HardwareReport,
        runtime: LocalModelRuntimeReport = LocalModelRuntimeReport()
    ) throws -> BrainSetupOption {
        try XCTUnwrap(
            planner.plan(for: probe(hardware, runtime: runtime)).option(withID: .fullyLocal),
            "fully local must stay in the catalog in every state"
        )
    }

    // MARK: - The capable Linux box

    func testACapableLinuxBoxIsOfferedTheLocalBrain() throws {
        let hardware = Self.linuxTower()
        XCTAssertEqual(hardware.localModelCapability, .comfortable)

        let option = try localOption(hardware, runtime: Self.ollamaServing)
        XCTAssertTrue(
            option.isAvailable,
            "a 128 GB / 32-core Linux tower was refused: "
                + (option.availability.reason ?? "with no reason given")
        )
        XCTAssertEqual(option.requirement, .nothing, "the model is already pulled and serving")
        XCTAssertEqual(option.modelName, "qwen3.5:4b")
    }

    /// Privacy by default has to survive the port, not just the refusal.
    func testACapableLinuxBoxGetsTheLocalBrainAsItsFreshInstallDefault() {
        let choices = planner.plan(for: probe(Self.linuxTower(), runtime: Self.ollamaServing))
        XCTAssertEqual(choices.recommendation?.optionID, .fullyLocal)
        XCTAssertNotNil(choices.freshInstallDefault)
        XCTAssertNil(choices.freshInstallDefaultObstacle)
    }

    /// The refusal survives where it is true. 4 GB is 4 GB on any kernel.
    func testAnUnderpoweredLinuxBoxIsStillRefusedWithBothFigures() throws {
        let hardware = Self.smallLinuxBox()
        XCTAssertEqual(hardware.localModelCapability, .unsupported)

        let option = try localOption(hardware)
        XCTAssertFalse(option.isAvailable)
        let reason = try XCTUnwrap(option.availability.reason)
        XCTAssertTrue(reason.contains("8.6 GB"), "must state the floor: \(reason)")
        XCTAssertTrue(reason.contains("4.3 GB"), "must state what the box has: \(reason)")
    }

    /// The whole defect, stated as an assertion: no sentence printed on Linux
    /// may be about Macs, Apple Silicon, or Intel chips.
    func testNoLinuxRefusalMentionsAppleSiliconOrMacs() throws {
        for hardware in [Self.smallLinuxBox(), Self.linuxTower(memoryGiB: 4)] {
            let reason = try XCTUnwrap(localOption(hardware).availability.reason)
            XCTAssertFalse(reason.contains("Apple Silicon"), reason)
            XCTAssertFalse(reason.contains("Intel"), reason)
            XCTAssertFalse(reason.contains("Mac"), reason)
        }
    }

    // MARK: - macOS must not move

    func testEveryMacVerdictIsUnchanged() {
        XCTAssertEqual(Self.appleSiliconMac(memoryGiB: 16).localModelCapability, .comfortable)
        XCTAssertEqual(Self.appleSiliconMac(memoryGiB: 8).localModelCapability, .tight)
        XCTAssertEqual(Self.appleSiliconMac(memoryGiB: 4).localModelCapability, .unsupported)
        XCTAssertEqual(Self.intelMac().localModelCapability, .unsupported)
        XCTAssertTrue(Self.appleSiliconMac(memoryGiB: 16).canComfortablyRunLocalFourBillionModel)
    }

    /// The Mac sentences, byte for byte, as 2.3.0 prints them. Substring checks
    /// would not have caught a stray double space from the rewrapping this
    /// change required.
    func testTheMacWordsAreExactlyWhatShippedAt2_3_0() throws {
        let offered = try localOption(Self.appleSiliconMac(memoryGiB: 16), runtime: Self.ollamaServing)
        XCTAssertEqual(offered.label, "Fully on this Mac")
        XCTAssertEqual(
            offered.summary,
            "Runs qwen3.5:4b on this Mac. Nothing you say leaves the machine, and there's nothing "
                + "to sign into or pay for."
        )

        let refused = try localOption(Self.intelMac())
        XCTAssertEqual(
            refused.availability.reason,
            "Running the brain on this Mac needs Apple Silicon — on an Intel chip a reply takes "
                + "far too long to be spoken conversation. This Mac reports Intel(R) Core(TM) "
                + "i9-9880H CPU @ 2.30GHz."
        )

        let tight = try localOption(Self.appleSiliconMac(memoryGiB: 8), runtime: Self.ollamaServing)
        XCTAssertEqual(
            tight.summary,
            "Runs qwen3.5:4b on this Mac. Nothing you say leaves the machine, and there's nothing "
                + "to sign into or pay for. This Mac has 8.6 GB of memory, which is enough but not "
                + "roomy — expect it to be slower and to compete with speech recognition."
        )
    }

    // MARK: - Weights on disk are not a hardware verdict

    /// **The answer to "should `isReadyToServe` be checked before the hardware
    /// gate".** Only for the guess it can actually settle.
    ///
    /// `LocalModelRuntimeReport` is built from `/api/version` and `/api/tags`:
    /// the daemon answered and the weights are on disk. Neither is the claim the
    /// memory floor makes, which is that 3.4 GB of weights fit beside a 1.6 GB
    /// ASR model. On a 4 GB box a pulled model is precisely the state that ends
    /// in swapping mid-reply, so deferring to it would turn a true refusal into
    /// dead air on the first question.
    func testAServingDaemonDoesNotOverrideTheMemoryFloorOnEitherPlatform() throws {
        for hardware in [Self.smallLinuxBox(), Self.appleSiliconMac(memoryGiB: 4)] {
            let option = try localOption(hardware, runtime: Self.ollamaServing)
            XCTAssertFalse(
                option.isAvailable,
                "\(hardware.platform): weights on disk are not room in memory"
            )
            let reason = try XCTUnwrap(option.availability.reason)
            XCTAssertTrue(reason.contains("8.6 GB"), reason)
        }
    }

    func testAServingDaemonDoesNotRescueAnIntelMac() throws {
        let option = try localOption(Self.intelMac(), runtime: Self.ollamaServing)
        XCTAssertFalse(option.isAvailable, "an Intel Mac is still too slow for a spoken reply")
        XCTAssertTrue(try XCTUnwrap(option.availability.reason).contains("Apple Silicon"))
    }

    /// Every dead end needs a door. An owner staring at a working `ollama run`
    /// in the next window is owed the sentence that reconciles it.
    func testARefusalNamesTheDaemonItIsRefusingInSpiteOf() throws {
        for hardware in [Self.smallLinuxBox(), Self.intelMac(), Self.appleSiliconMac(memoryGiB: 4)] {
            let reason = try XCTUnwrap(
                localOption(hardware, runtime: Self.ollamaServing).availability.reason
            )
            XCTAssertTrue(
                reason.contains("already serving qwen3.5:4b"),
                "\(hardware.platform) refusal ignores the running daemon: \(reason)"
            )
        }
    }

    func testARefusalWithNoDaemonSaysNothingAboutOne() throws {
        let reason = try XCTUnwrap(localOption(Self.smallLinuxBox()).availability.reason)
        XCTAssertFalse(reason.contains("already serving"), reason)
    }

    // MARK: - The uncertainty that has to be said out loud

    /// Off Darwin the probe measures the memory and cannot see the accelerator.
    /// The option is still offered — refusing unmeasured machines is what this
    /// change exists to stop — so the gap has to be in the words, or the offer
    /// is an over-promise dressed as a measurement.
    func testTheLinuxOfferSaysItCannotSeeTheGPU() throws {
        for option in [
            try localOption(Self.linuxTower(), runtime: Self.ollamaServing),
            try localOption(Self.linuxTower())
        ] {
            XCTAssertTrue(option.isAvailable)
            XCTAssertTrue(option.summary.contains("GPU"), option.summary)
            XCTAssertTrue(option.summary.contains("CPU"), option.summary)
        }
    }

    func testTheMacOfferSaysNothingAboutGPUsBecauseMetalAlreadyAnsweredIt() throws {
        let option = try localOption(Self.appleSiliconMac(memoryGiB: 16), runtime: Self.ollamaServing)
        XCTAssertFalse(option.summary.contains("GPU"), option.summary)
    }

    // MARK: - The decision function itself

    func testTheDecisionFunctionAnswersForPlatformsItIsNotRunningOn() {
        // The same non-Apple-Silicon machine, judged as a Mac and as a Linux box.
        XCTAssertEqual(
            LocalModelCapability.forMachine(
                memoryBytes: 32 * Self.gib, isAppleSilicon: false, platform: .darwin
            ),
            .unsupported
        )
        XCTAssertEqual(
            LocalModelCapability.forMachine(
                memoryBytes: 32 * Self.gib, isAppleSilicon: false, platform: .linux
            ),
            .comfortable
        )
        // Windows lands with Linux: no Metal, but no claim that means anything.
        XCTAssertEqual(
            LocalModelCapability.forMachine(
                memoryBytes: 32 * Self.gib, isAppleSilicon: false, platform: .windows
            ),
            .comfortable
        )
        // The thresholds themselves are the same numbers everywhere.
        XCTAssertEqual(
            LocalModelCapability.forMachine(
                memoryBytes: LocalBrainModelCatalog.comfortableMemoryBytes,
                isAppleSilicon: false, platform: .linux
            ),
            .comfortable
        )
        XCTAssertEqual(
            LocalModelCapability.forMachine(
                memoryBytes: LocalBrainModelCatalog.minimumMemoryBytes,
                isAppleSilicon: false, platform: .linux
            ),
            .tight
        )
        XCTAssertEqual(
            LocalModelCapability.forMachine(
                memoryBytes: LocalBrainModelCatalog.minimumMemoryBytes - 1,
                isAppleSilicon: false, platform: .linux
            ),
            .unsupported
        )
    }

    // MARK: - The report has to carry the platform, and actually does

    /// Proves `HardwareReport.platform` is populated rather than decorative: the
    /// default argument is evaluated inside `SystemHardwareProbe`, so this is
    /// the shipped probe answering about the machine running the suite.
    func testTheShippedProbeRecordsThePlatformItRanOn() {
        let report = SystemHardwareProbe().report(
            modelStorageDirectory: URL(fileURLWithPath: NSTemporaryDirectory())
        )
        XCTAssertEqual(report.platform, .current)
        #if canImport(Darwin)
        XCTAssertEqual(report.platform, .darwin)
        XCTAssertTrue(report.isAppleSilicon, "this suite is expected to run on Apple Silicon")
        #elseif os(Linux)
        XCTAssertEqual(report.platform, .linux)
        XCTAssertGreaterThan(report.physicalMemoryBytes, 0, "/proc/meminfo gave nothing")
        #endif
    }

    /// A support bundle written before the field existed still decodes. A tool
    /// that reads archived reports would otherwise fail on exactly the old ones
    /// somebody went looking for.
    func testAReportFromBeforeThePlatformWasRecordedStillDecodes() throws {
        let json = """
        {"physicalMemoryBytes":17179869184,"modelStorageDirectory":"/Users/owner/.ollama/models",\
        "cpuBrand":"Apple M2","physicalCoreCount":8,"isAppleSilicon":true}
        """
        let report = try JSONDecoder().decode(HardwareReport.self, from: Data(json.utf8))
        XCTAssertEqual(report.platform, .current)
        XCTAssertTrue(report.isAppleSilicon)
        XCTAssertEqual(report.physicalMemoryBytes, 16 * Self.gib)
    }
}
