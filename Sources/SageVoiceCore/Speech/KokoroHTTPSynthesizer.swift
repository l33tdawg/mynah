import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Speaks via Kokoro running in the Python voice bridge on this machine.
///
/// Kokoro stays out of process on purpose. It needs PyTorch, and the whole point
/// of `SageVoiceCore` is that the Swift side has no dependencies - so we talk to
/// it over loopback HTTP and keep the heavy runtime behind a socket. The wire
/// contract is: POST some JSON, get a WAV body back.
///
/// Measured on the Mac mini M2 (16GB, macOS 26.5.2) against the deployed bridge:
/// real-time factor 0.16-0.17, i.e. roughly six seconds of speech produced per
/// second of wall clock, ~0.87s to synthesize a fifteen-word sentence.
public struct KokoroHTTPSynthesizer: SpeechSynthesizing {
    /// How to phrase the request body. The audio always comes back as a raw WAV
    /// body; only the request JSON differs.
    public enum RequestEncoding: Sendable, Equatable {
        /// `{"text": ..., "voice": ..., "speed": ...}` - the SAGE voice bridge.
        case sageBridge
        /// `{"model": ..., "input": ..., "voice": ..., "speed": ..., "response_format": "wav"}`
        /// - the OpenAI `/v1/audio/speech` shape, which kokoro-fastapi also serves.
        case openAISpeech(model: String)
    }

    /// Default endpoint: the `/api/speech` route on the local voice bridge.
    public static let defaultEndpoint = URL(string: "http://127.0.0.1:8765/api/speech")!

    /// Default Kokoro voice, from the one place that declares it.
    public static let defaultKokoroVoice = KokoroVoices.defaultVoiceName

    /// Kokoro emits 24 kHz mono. Declared so callers can size buffers before the
    /// first response arrives; the value actually used is read from the WAV header.
    public static let nominalSampleRate = 24000

    private let endpoint: URL
    private let healthEndpoint: URL
    private let encoding: RequestEncoding
    private let voice: String
    private let timeoutSeconds: TimeInterval
    private let session: URLSession

    public init(
        endpoint: URL = KokoroHTTPSynthesizer.defaultEndpoint,
        healthEndpoint: URL? = nil,
        encoding: RequestEncoding = .sageBridge,
        voice: String = KokoroHTTPSynthesizer.defaultKokoroVoice,
        timeoutSeconds: TimeInterval = 30.0,
        session: URLSession? = nil
    ) {
        self.endpoint = endpoint
        self.healthEndpoint = healthEndpoint ?? KokoroHTTPSynthesizer.rootURL(of: endpoint)
        self.encoding = encoding
        self.voice = voice
        self.timeoutSeconds = timeoutSeconds
        // Default to a redirect-refusing session. URLSession follows 3xx and
        // re-sends the body by default, so a loopback host check alone does not
        // stop the owner's words being 307'd off-box.
        self.session = session ?? LoopbackSecurity.makeSession(timeout: timeoutSeconds)
    }

    /// Point at any server implementing OpenAI's `POST /v1/audio/speech`
    /// (kokoro-fastapi, or a future Swift sidecar exposing the same route).
    public static func openAICompatible(
        endpoint: URL,
        model: String = "kokoro",
        voice: String = KokoroHTTPSynthesizer.defaultKokoroVoice,
        timeoutSeconds: TimeInterval = 30.0
    ) -> KokoroHTTPSynthesizer {
        KokoroHTTPSynthesizer(
            endpoint: endpoint,
            encoding: .openAISpeech(model: model),
            voice: voice,
            timeoutSeconds: timeoutSeconds
        )
    }

    // MARK: - SpeechSynthesizing

    public var identifier: String { "kokoro-http" }

    public var defaultVoice: String { voice }

    public func isAvailable() async -> Bool {
        guard LoopbackSecurity.isLoopback(healthEndpoint) else { return false }
        var request = URLRequest(url: healthEndpoint)
        request.httpMethod = "GET"
        request.timeoutInterval = min(timeoutSeconds, 3.0)
        do {
            let (_, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else { return false }
            return (200..<300).contains(http.statusCode)
        } catch {
            return false
        }
    }

    public func synthesize(_ request: SpeechRequest) async throws -> SynthesizedSpeech {
        let text = request.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            throw SpeechSynthesisError.emptyText
        }
        guard LoopbackSecurity.isLoopback(endpoint) else {
            throw SpeechSynthesisError.nonLoopbackEndpoint(endpoint.absoluteString)
        }

        var urlRequest = URLRequest(url: endpoint)
        urlRequest.httpMethod = "POST"
        urlRequest.timeoutInterval = timeoutSeconds
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.setValue("audio/wav", forHTTPHeaderField: "Accept")
        urlRequest.httpBody = try body(for: request, text: text)

        let started = Date()
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: urlRequest)
        } catch {
            throw SpeechSynthesisError.requestFailed(Self.describe(error, timeoutSeconds: timeoutSeconds))
        }
        let elapsed = Date().timeIntervalSince(started)

        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw SpeechSynthesisError.badResponse(http.statusCode, Self.shortBody(data))
        }

        let format: WAVAudio.Format
        do {
            format = try WAVAudio.format(of: data)
        } catch {
            // A JSON error body from a healthy-looking server is the common case
            // here, so surface it rather than the byte-level parse failure.
            throw SpeechSynthesisError.malformedAudio(
                Self.shortBody(data).isEmpty ? String(describing: error) : Self.shortBody(data)
            )
        }
        guard format.dataByteCount > 0 else {
            throw SpeechSynthesisError.malformedAudio("WAV contained no samples.")
        }

        return SynthesizedSpeech(
            wav: data,
            sampleRate: format.sampleRate,
            channelCount: format.channelCount,
            duration: format.duration,
            // The bridge answers with the finished file, so first audio and last
            // audio arrive at the same instant.
            timeToFirstAudio: elapsed,
            generationDuration: elapsed
        )
    }

    // MARK: - Request building

    private func body(for request: SpeechRequest, text: String) throws -> Data {
        let resolvedVoice = request.voice ?? voice
        let payload: [String: Any]
        switch encoding {
            case .sageBridge:
                payload = [
                    "text": text,
                    "voice": resolvedVoice,
                    "speed": request.speed,
                ]
            case let .openAISpeech(model):
                payload = [
                    "model": model,
                    "input": text,
                    "voice": resolvedVoice,
                    "speed": request.speed,
                    "response_format": "wav",
                ]
        }
        do {
            return try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
        } catch {
            throw SpeechSynthesisError.requestFailed(String(describing: error))
        }
    }

    // MARK: - Helpers

    static func rootURL(of endpoint: URL) -> URL {
        var components = URLComponents(url: endpoint, resolvingAgainstBaseURL: false)
        components?.path = "/"
        components?.query = nil
        components?.fragment = nil
        return components?.url ?? endpoint
    }

    static func describe(_ error: Error, timeoutSeconds: TimeInterval) -> String {
        let nsError = error as NSError
        guard nsError.domain == NSURLErrorDomain else {
            return String(describing: error)
        }
        switch nsError.code {
            case NSURLErrorTimedOut:
                return "timed out after \(Int(timeoutSeconds.rounded()))s - Kokoro may still be loading."
            case NSURLErrorCannotConnectToHost, NSURLErrorNetworkConnectionLost:
                return "could not reach the voice bridge - is `python run.py` running on port 8765?"
            default:
                return nsError.localizedDescription
        }
    }

    static func shortBody(_ data: Data, limit: Int = 240) -> String {
        guard !data.isEmpty else { return "" }
        let text = String(decoding: data.prefix(limit), as: UTF8.self)
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        // Binary payloads decode into replacement characters; do not echo those.
        guard !trimmed.isEmpty, !trimmed.unicodeScalars.contains("\u{FFFD}") else { return "" }
        return trimmed
    }
}

// The loopback predicate lives in LoopbackSecurity. Two copies of a security
// check is one too many — and both of the previous copies were incomplete,
// validating only the URL dialled and not the one actually reached.
