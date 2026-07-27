import Foundation

public struct WhisperKitServerTranscriber: AudioFileTranscribing {
    public static let streamingTimeoutSeconds: TimeInterval = 10.0
    public static let warmupTimeoutSeconds: TimeInterval = 30.0
    public static let minimumFullAudioTimeoutSeconds: TimeInterval = 45.0
    public static let maximumFullAudioTimeoutSeconds: TimeInterval = 180.0

    private let endpoint: URL
    private let model: String
    private let language: String?
    private let timeoutSeconds: TimeInterval

    public init(
        endpoint: URL = URL(string: "http://127.0.0.1:50060/v1/audio/transcriptions")!,
        model: String = "large-v3-v20240930_626MB",
        language: String? = "en",
        timeoutSeconds: TimeInterval = 8.0
    ) {
        self.endpoint = endpoint
        self.model = model
        self.language = language
        self.timeoutSeconds = timeoutSeconds
    }

    public func transcribe(audioFile: URL, options: AudioTranscriptionOptions) async throws -> String {
        try await createTranscription(audioFile: audioFile, options: options, includeWordTimestamps: false).text
    }

    public func transcribeWithTiming(audioFile: URL, options: AudioTranscriptionOptions) async throws -> TimedTranscriptionResult {
        try await createTranscription(audioFile: audioFile, options: options, includeWordTimestamps: true)
    }

    public static func timeoutForFullAudio(durationSeconds: TimeInterval) -> TimeInterval {
        min(
            maximumFullAudioTimeoutSeconds,
            max(minimumFullAudioTimeoutSeconds, durationSeconds * 8.0)
        )
    }

    public static func describeRequestFailure(_ error: Error, timeoutSeconds: TimeInterval) -> String {
        let nsError = error as NSError
        if nsError.domain == NSURLErrorDomain, nsError.code == NSURLErrorTimedOut {
            return "Native WhisperKit request timed out after \(Int(timeoutSeconds.rounded()))s. The Apple Silicon speech engine may still be warming or the recording may be too long for this Mac."
        }
        return String(describing: error)
    }

    private func createTranscription(audioFile: URL, options: AudioTranscriptionOptions, includeWordTimestamps: Bool) async throws -> TimedTranscriptionResult {
        guard endpoint.isLoopbackHTTP else {
            throw AudioTranscriberError.nonLoopbackEndpoint(endpoint.absoluteString)
        }

        let boundary = "QuietType-\(UUID().uuidString)"
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = timeoutSeconds
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.httpBody = try multipartBody(
            audioFile: audioFile,
            boundary: boundary,
            options: options,
            includeWordTimestamps: includeWordTimestamps
        )

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            throw AudioTranscriberError.requestFailed(Self.describeRequestFailure(error, timeoutSeconds: timeoutSeconds))
        }
        guard let http = response as? HTTPURLResponse else {
            throw AudioTranscriberError.badResponse(-1)
        }
        guard (200..<300).contains(http.statusCode) else {
            throw AudioTranscriberError.badResponse(http.statusCode)
        }

        let result = try Self.parseTimedTranscript(from: data)
        guard !result.text.isEmpty else {
            throw AudioTranscriberError.emptyTranscript
        }
        guard !WhisperCommandASRBackend.isNoiseOnlyTranscript(result.text) else {
            throw AudioTranscriberError.noiseOnlyTranscript(result.text)
        }
        return result
    }

    func multipartBody(
        audioFile: URL,
        boundary: String,
        options: AudioTranscriptionOptions,
        includeWordTimestamps: Bool
    ) throws -> Data {
        var data = Data()
        data.appendMultipartField(name: "model", value: model, boundary: boundary)
        if let language {
            data.appendMultipartField(name: "language", value: language, boundary: boundary)
        }
        if let prompt = options.initialPrompt {
            data.appendMultipartField(name: "prompt", value: prompt, boundary: boundary)
        }
        data.appendMultipartField(name: "response_format", value: includeWordTimestamps ? "verbose_json" : "json", boundary: boundary)
        if includeWordTimestamps {
            data.appendMultipartField(name: "timestamp_granularities[]", value: "word", boundary: boundary)
            data.appendMultipartField(name: "timestamp_granularities[]", value: "segment", boundary: boundary)
        }
        data.appendMultipartFile(name: "file", filename: audioFile.lastPathComponent, contentType: "audio/wav", fileData: try Data(contentsOf: audioFile), boundary: boundary)
        data.appendString("--\(boundary)--\r\n")
        return data
    }

    static func parseTranscript(from data: Data) throws -> String {
        try parseTimedTranscript(from: data).text
    }

    static func parseTimedTranscript(from data: Data) throws -> TimedTranscriptionResult {
        if let object = try? JSONSerialization.jsonObject(with: data) {
            if let object = object as? [String: Any] {
                return TimedTranscriptionResult(
                    text: WhisperCommandASRBackend.sanitizeTranscript(Self.extractText(from: object)),
                    words: Self.extractWords(from: object)
                )
            }
            if let text = object as? String {
                return TimedTranscriptionResult(text: WhisperCommandASRBackend.sanitizeTranscript(text))
            }
            return TimedTranscriptionResult(text: "")
        }
        return TimedTranscriptionResult(text: WhisperCommandASRBackend.sanitizeTranscript(String(data: data, encoding: .utf8) ?? ""))
    }

    private static func extractText(from object: [String: Any]) -> String {
        if let text = object["text"] as? String,
           !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return text
        }
        if let transcript = object["transcript"] as? String,
           !transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return transcript
        }
        if let result = object["result"] as? [String: Any] {
            let text = extractText(from: result)
            if !text.isEmpty {
                return text
            }
        }
        if let segments = object["segments"] as? [[String: Any]] {
            return segments
                .compactMap { segment in
                    (segment["text"] as? String)?
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                }
                .filter { !$0.isEmpty }
                .joined(separator: " ")
        }
        return ""
    }

    private static func extractWords(from object: [String: Any]) -> [TranscribedWordTiming] {
        var words: [TranscribedWordTiming] = []
        words.append(contentsOf: wordTimings(from: object["words"]))

        if let result = object["result"] as? [String: Any] {
            words.append(contentsOf: extractWords(from: result))
        }

        if let segments = object["segments"] as? [[String: Any]] {
            for segment in segments {
                words.append(contentsOf: wordTimings(from: segment["words"]))
            }
        }

        return words.filter { timing in
            !timing.word.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                && timing.endSeconds >= timing.startSeconds
        }
    }

    private static func wordTimings(from value: Any?) -> [TranscribedWordTiming] {
        guard let entries = value as? [[String: Any]] else {
            return []
        }

        return entries.compactMap { entry in
            let word = (entry["word"] as? String)
                ?? (entry["text"] as? String)
                ?? (entry["token"] as? String)
                ?? ""
            guard let start = doubleValue(entry["start"] ?? entry["start_seconds"] ?? entry["startSeconds"]),
                  let end = doubleValue(entry["end"] ?? entry["end_seconds"] ?? entry["endSeconds"]) else {
                return nil
            }
            let confidence = doubleValue(entry["confidence"] ?? entry["probability"] ?? entry["prob"])
            return TranscribedWordTiming(
                word: WhisperCommandASRBackend.sanitizeTranscript(word),
                startSeconds: start,
                endSeconds: end,
                confidence: confidence
            )
        }
    }

    private static func doubleValue(_ value: Any?) -> Double? {
        if let double = value as? Double {
            return double
        }
        if let int = value as? Int {
            return Double(int)
        }
        if let string = value as? String {
            return Double(string)
        }
        return nil
    }
}

private extension Data {
    mutating func appendMultipartField(name: String, value: String, boundary: String) {
        appendString("--\(boundary)\r\n")
        appendString("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n")
        appendString("\(value)\r\n")
    }

    mutating func appendMultipartFile(name: String, filename: String, contentType: String, fileData: Data, boundary: String) {
        appendString("--\(boundary)\r\n")
        appendString("Content-Disposition: form-data; name=\"\(name)\"; filename=\"\(filename)\"\r\n")
        appendString("Content-Type: \(contentType)\r\n\r\n")
        append(fileData)
        appendString("\r\n")
    }

    mutating func appendString(_ value: String) {
        append(contentsOf: value.utf8)
    }
}

private extension URL {
    var isLoopbackHTTP: Bool {
        guard scheme == "http", let host else {
            return false
        }
        return host == "127.0.0.1" || host == "localhost" || host == "::1"
    }
}
