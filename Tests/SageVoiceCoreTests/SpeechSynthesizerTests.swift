import XCTest
@testable import SageVoiceCore

final class WAVAudioTests: XCTestCase {
    func testEncodeThenParseRoundTrips() throws {
        let samples = (0..<24000).map { Float(sin(Double($0) * 0.01)) }
        let wav = WAVAudio.encode(samples: samples, sampleRate: 24000)

        XCTAssertEqual(wav.count, WAVAudio.headerByteCount + samples.count * 2)

        let format = try WAVAudio.format(of: wav)
        XCTAssertEqual(format.sampleRate, 24000)
        XCTAssertEqual(format.channelCount, 1)
        XCTAssertEqual(format.bitsPerSample, 16)
        XCTAssertEqual(format.dataByteCount, samples.count * 2)
        XCTAssertEqual(format.duration, 1.0, accuracy: 0.0001)
    }

    func testFullScaleSamplesDoNotWrap() throws {
        let wav = WAVAudio.encode(samples: [1.0, -1.0, 2.0, -2.0], sampleRate: 8000)
        let body = wav.dropFirst(WAVAudio.headerByteCount)
        let decoded = stride(from: 0, to: body.count, by: 2).map { offset -> Int16 in
            let index = body.startIndex + offset
            return Int16(bitPattern: UInt16(body[index]) | (UInt16(body[index + 1]) << 8))
        }
        XCTAssertEqual(decoded, [32767, -32767, 32767, -32767])
    }

    func testRejectsNonWAVPayload() {
        XCTAssertThrowsError(try WAVAudio.format(of: Data("{\"error\":\"nope\"}".utf8)))
    }
}

final class SpeechTextSegmenterTests: XCTestCase {
    func testSplitsOnSentenceBoundaries() {
        let segments = SpeechTextSegmenter.segments(
            for: "You have three open tasks. The oldest is fixing the whisper model. Nothing else."
        )
        XCTAssertEqual(segments, [
            "You have three open tasks.",
            "The oldest is fixing the whisper model.",
            "Nothing else.",
        ])
    }

    func testDoesNotSplitInsideDecimalsOrAbbreviations() {
        let segments = SpeechTextSegmenter.segments(for: "Model qwen3.5:4b routed 91.2% of calls.")
        XCTAssertEqual(segments, ["Model qwen3.5:4b routed 91.2% of calls."])
    }

    func testHardSplitsRunawaySentences() {
        let long = String(repeating: "word ", count: 200).trimmingCharacters(in: .whitespaces)
        let segments = SpeechTextSegmenter.segments(for: long, maximumLength: 60)
        XCTAssertGreaterThan(segments.count, 1)
        for segment in segments {
            XCTAssertLessThanOrEqual(segment.count, 60)
        }
    }

    func testEmptyTextProducesNoSegments() {
        XCTAssertTrue(SpeechTextSegmenter.segments(for: "   \n ").isEmpty)
    }
}

final class KokoroHTTPSynthesizerTests: XCTestCase {
    /// Set `SAGE_SPEECH_ENDPOINT` to a loopback URL that answers the
    /// `/api/speech` contract to run the live half of this suite.
    private var liveEndpoint: URL? {
        guard let raw = ProcessInfo.processInfo.environment["SAGE_SPEECH_ENDPOINT"] else { return nil }
        return URL(string: raw)
    }

    func testRejectsEmptyText() async {
        let synthesizer = KokoroHTTPSynthesizer()
        do {
            _ = try await synthesizer.synthesize(text: "   ")
            XCTFail("expected emptyText")
        } catch let error as SpeechSynthesisError {
            XCTAssertEqual(error, .emptyText)
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

    func testRejectsNonLoopbackEndpoint() async {
        let synthesizer = KokoroHTTPSynthesizer(endpoint: URL(string: "http://example.com/api/speech")!)
        do {
            _ = try await synthesizer.synthesize(text: "hello")
            XCTFail("expected nonLoopbackEndpoint")
        } catch let error as SpeechSynthesisError {
            XCTAssertEqual(error, .nonLoopbackEndpoint("http://example.com/api/speech"))
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

    func testHealthEndpointDefaultsToServerRoot() {
        let root = KokoroHTTPSynthesizer.rootURL(of: URL(string: "http://127.0.0.1:8765/api/speech?x=1")!)
        XCTAssertEqual(root.absoluteString, "http://127.0.0.1:8765/")
    }

    // MARK: - Live

    func testLiveSynthesisReturnsPlayableWAV() async throws {
        guard let endpoint = liveEndpoint else {
            throw XCTSkip("set SAGE_SPEECH_ENDPOINT to run the live speech test")
        }
        let synthesizer = KokoroHTTPSynthesizer(endpoint: endpoint)
        let available = await synthesizer.isAvailable()
        XCTAssertTrue(available, "health probe failed for \(endpoint)")

        let lines = [
            "You have three open tasks. The oldest is fixing the whisper model on the mac mini.",
            "I sent that note to the MacBook Pro agent. It has two items on its plate.",
            "Nothing new in your inbox since this morning.",
        ]
        for line in lines {
            let speech = try await synthesizer.synthesize(text: line)
            XCTAssertEqual(speech.sampleRate, KokoroHTTPSynthesizer.nominalSampleRate)
            XCTAssertEqual(speech.channelCount, 1)
            XCTAssertGreaterThan(speech.duration, 1.0)
            XCTAssertGreaterThan(speech.wav.count, WAVAudio.headerByteCount)
            XCTAssertEqual(String(decoding: speech.wav.prefix(4), as: UTF8.self), "RIFF")
            print("[live] \(speech.duration.rounded(toPlaces: 2))s audio in "
                + "\(speech.generationDuration.rounded(toPlaces: 3))s "
                + "(RTF \(speech.realTimeFactor.rounded(toPlaces: 3)))")
        }
    }

    func testLiveSentenceStreamingDeliversSegmentsInOrder() async throws {
        guard let endpoint = liveEndpoint else {
            throw XCTSkip("set SAGE_SPEECH_ENDPOINT to run the live speech test")
        }
        let synthesizer = KokoroHTTPSynthesizer(endpoint: endpoint)
        var indexes: [Int] = []
        var total: TimeInterval = 0
        try await synthesizer.synthesizeBySentence(
            text: "You have three open tasks. The oldest is fixing the whisper model on the mac mini. "
                + "Nothing new in your inbox since this morning."
        ) { speech, index in
            indexes.append(index)
            total += speech.duration
        }
        XCTAssertEqual(indexes, [0, 1, 2])
        XCTAssertGreaterThan(total, 3.0)
    }

    func testLiveNonAudioBodySurfacesAsMalformedAudio() async throws {
        guard let endpoint = liveEndpoint else {
            throw XCTSkip("set SAGE_SPEECH_ENDPOINT to run the live speech test")
        }
        var components = URLComponents(url: endpoint, resolvingAgainstBaseURL: false)!
        components.path = "/notaudio"
        let synthesizer = KokoroHTTPSynthesizer(endpoint: components.url!)
        do {
            _ = try await synthesizer.synthesize(text: "hello")
            XCTFail("expected malformedAudio")
        } catch let error as SpeechSynthesisError {
            guard case .malformedAudio = error else {
                return XCTFail("unexpected error: \(error)")
            }
        }
    }
}

private extension Double {
    func rounded(toPlaces places: Int) -> Double {
        let factor = pow(10.0, Double(places))
        return (self * factor).rounded() / factor
    }
}
