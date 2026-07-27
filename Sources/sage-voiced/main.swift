import Foundation
import SageVoiceCore

// Smoke harness for the lifted QuietType ASR core.
// Usage: sage-voiced transcribe <file.wav> [--endpoint URL] [--model NAME]
//
// The real daemon (Signal transport + Ollama brain + TTS) lands on top of this.

func usage() -> Never {
    FileHandle.standardError.write(Data("""
    usage: sage-voiced transcribe <file.wav> [--endpoint URL] [--model NAME]

    """.utf8))
    exit(2)
}

let args = Array(CommandLine.arguments.dropFirst())
guard args.first == "transcribe", args.count >= 2 else { usage() }

let path = args[1]
var endpoint = URL(string: "http://127.0.0.1:50060/v1/audio/transcriptions")!
var model = "large-v3"

var i = 2
while i + 1 < args.count {
    switch args[i] {
    case "--endpoint": endpoint = URL(string: args[i + 1]) ?? endpoint
    case "--model": model = args[i + 1]
    default: break
    }
    i += 2
}

let fileURL = URL(fileURLWithPath: path)
guard FileManager.default.fileExists(atPath: fileURL.path) else {
    FileHandle.standardError.write(Data("no such file: \(path)\n".utf8))
    exit(1)
}

let transcriber = WhisperKitServerTranscriber(
    endpoint: endpoint,
    model: model,
    language: "en",
    timeoutSeconds: WhisperKitServerTranscriber.minimumFullAudioTimeoutSeconds
)

let sem = DispatchSemaphore(value: 0)
var status: Int32 = 0

Task {
    let started = Date()
    do {
        let text = try await transcriber.transcribe(
            audioFile: fileURL,
            options: AudioTranscriptionOptions()
        )
        let elapsed = Date().timeIntervalSince(started)
        print(String(format: "[%.2fs] %@", elapsed, text))
    } catch {
        FileHandle.standardError.write(Data("transcribe failed: \(error)\n".utf8))
        status = 1
    }
    sem.signal()
}

sem.wait()
exit(status)
