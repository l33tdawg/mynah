import Foundation
import XCTest
@testable import SageVoiceCore

final class ASRFallbackTelemetryTests: XCTestCase {
    func testASuccessfulFallbackReportsTheBackendItRescued() async throws {
        let lines = LockedLines()
        let transcriber = CascadingAudioFileTranscriber(
            [Fails(reason: "native server refused the clip"), Hears(text: "hello")],
            log: { lines.append($0) }
        )

        let text = try await transcriber.transcribe(
            audioFile: URL(fileURLWithPath: "/tmp/not-read.wav"),
            options: .none
        )

        XCTAssertEqual(text, "hello")
        let line = try XCTUnwrap(lines.values.first)
        XCTAssertTrue(line.contains("[asr] rescued by backend 2"), line)
        XCTAssertTrue(line.contains("backend 1: native server refused the clip"), line)
    }

    func testTheFirstBackendSucceedingDoesNotPretendThereWasARescue() async throws {
        let lines = LockedLines()
        let transcriber = CascadingAudioFileTranscriber(
            [Hears(text: "hello"), Fails(reason: "must not run")],
            log: { lines.append($0) }
        )

        _ = try await transcriber.transcribe(
            audioFile: URL(fileURLWithPath: "/tmp/not-read.wav"),
            options: .none
        )

        XCTAssertTrue(lines.values.isEmpty)
    }

    func testTimedTranscriptionReportsARescueToo() async throws {
        let lines = LockedLines()
        let transcriber = CascadingAudioFileTranscriber(
            [Fails(reason: "quiet clip"), Hears(text: "heard by fallback")],
            log: { lines.append($0) }
        )

        let result = try await transcriber.transcribeWithTiming(
            audioFile: URL(fileURLWithPath: "/tmp/not-read.wav"),
            options: .none
        )

        XCTAssertEqual(result.text, "heard by fallback")
        XCTAssertEqual(lines.values.count, 1)
        XCTAssertTrue(lines.values[0].contains("rescued by backend 2"), lines.values[0])
        XCTAssertTrue(lines.values[0].contains(" after "), lines.values[0])
        XCTAssertTrue(lines.values[0].contains("quiet clip"), lines.values[0])
    }

    /// The unit tests above inject the logger directly. This pins the production
    /// seam too: without it the cascade still falls back successfully, every
    /// focused telemetry test passes, and the daemon log remains silent.
    func testLocalRuntimeHandsItsLoggerToTheCascade() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(
            contentsOf: root.appendingPathComponent("Sources/SageVoiceCore/LocalASRDiscovery.swift"),
            encoding: .utf8
        )

        XCTAssertTrue(
            source.contains("CascadingAudioFileTranscriber(backends, log: log)"),
            "LocalASRRuntime dropped the daemon logger before constructing the fallback cascade"
        )
    }
}

private struct Fails: AudioFileTranscribing {
    let reason: String

    func transcribe(audioFile: URL, options: AudioTranscriptionOptions) async throws -> String {
        throw AudioTranscriberError.requestFailed(reason)
    }
}

private struct Hears: AudioFileTranscribing {
    let text: String

    func transcribe(audioFile: URL, options: AudioTranscriptionOptions) async throws -> String {
        text
    }
}

private final class LockedLines: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String] = []

    var values: [String] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    func append(_ line: String) {
        lock.lock()
        storage.append(line)
        lock.unlock()
    }
}
