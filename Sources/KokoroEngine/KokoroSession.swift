import COnnxRuntime
import Foundation
import SageVoiceCore

/// Runs Kokoro's ONNX graph, in this process.
///
/// ## What this replaces
///
/// A 309 MB Python virtual environment behind a loopback HTTP server, of which
/// the genuinely load-bearing part was one `session.run` call. Everything else —
/// scipy for a resample, numpy for a clip, fastapi and uvicorn to carry a WAV
/// across localhost — has already been replaced by `AudioUpsampler`,
/// `SilenceTrim`, `KokoroTokenizer` and `KokoroVoices`. This is the last piece,
/// and it deletes the server, the port and the launchd job with it.
///
/// ## The graph
///
/// Three inputs, one output, verified by introspecting the model rather than
/// read from documentation:
///
///   - `tokens`  int64  `[1, sequence_length]`
///   - `style`   float32 `[1, 256]`
///   - `speed`   float32 `[1]`
///   - `audio`   float32 `[audio_length]` — **1-D, with no batch dimension**
///
/// ## Why an actor
///
/// ONNX Runtime sessions are documented as thread-safe for `Run`, but the
/// resources here — the environment, the session, the allocator — are C pointers
/// with manual lifetimes, and a synthesis that outlives its session by one
/// instruction is a crash rather than an exception. The actor makes the
/// lifetime single-threaded and costs nothing: synthesis is already serialised
/// behind a single voice.
public actor KokoroSession {

    public enum Failure: Error, Equatable {
        case runtimeUnavailable
        case cannotCreateEnvironment(String)
        case modelNotFound(String)
        case cannotLoadModel(String)
        case cannotBuildInput(String)
        case inferenceFailed(String)
        /// The graph answered with something other than a 1-D float array.
        case unexpectedOutput(String)
        case emptyText
    }

    /// What Kokoro emits, before any resampling.
    public static let sampleRate = 24_000

    /// The bounds `kokoro_onnx` asserts on. Outside them the model does not
    /// fail, it produces speech at a speed nobody asked for.
    public static let speedRange: ClosedRange<Float> = 0.5...2.0

    // Set once in `init` and only read afterwards, so `nonisolated(unsafe) let`
    // states what is true rather than working around a diagnostic: these are C
    // pointers with no Swift-visible mutation, `init` runs before any other
    // caller can reach the actor, and `deinit` runs after the last one has left.
    // Declaring them isolated `var` instead makes both `init` and `deinit`
    // illegal in Swift 6 for a safety the actor is not providing anyway.
    private nonisolated(unsafe) let api: UnsafePointer<OrtApi>
    private nonisolated(unsafe) let environment: OpaquePointer?
    private nonisolated(unsafe) let session: OpaquePointer?

    /// Loads the model. Expensive — about three quarters of a second — and
    /// therefore done once and held, exactly as the Python server did. Paying it
    /// per request would double the latency of every spoken reply and be the
    /// single largest cost in the path.
    public init(modelPath: URL) throws {
        guard let base = OrtGetApiBase(),
              let getApi = base.pointee.GetApi,
              let api = getApi(UInt32(ORT_API_VERSION)) else {
            throw Failure.runtimeUnavailable
        }
        guard FileManager.default.fileExists(atPath: modelPath.path) else {
            throw Failure.modelNotFound(modelPath.lastPathComponent)
        }

        var environment: OpaquePointer?
        // ORT_LOGGING_LEVEL_WARNING: the model loads with informational notes
        // about unused initialisers that would otherwise be written to the
        // owner's log on every launch.
        try Self.check(api, api.pointee.CreateEnv(ORT_LOGGING_LEVEL_WARNING, "mynah", &environment)) {
            Failure.cannotCreateEnvironment($0)
        }

        var options: OpaquePointer?
        try Self.check(api, api.pointee.CreateSessionOptions(&options)) { Failure.cannotLoadModel($0) }
        defer { api.pointee.ReleaseSessionOptions(options) }
        // The Python path runs CPU-only and reaches a real-time factor of 0.16
        // on this hardware — roughly six seconds of speech per second of wall
        // clock. CoreML is available in this build and is deliberately not
        // enabled: it would change the arithmetic, and the golden vectors this
        // port is verified against were produced on CPU.
        _ = api.pointee.SetIntraOpNumThreads(options, 0)

        var session: OpaquePointer?
        do {
            try Self.check(
                api, api.pointee.CreateSession(environment, modelPath.path, options, &session)
            ) { Failure.cannotLoadModel($0) }
        } catch {
            // The environment was created and this initialiser is about to stop
            // existing, so nothing will ever run `deinit` for it.
            api.pointee.ReleaseEnv(environment)
            throw error
        }

        // Assigned together, at the end. Every `Self.check` above is a
        // nonisolated call, and Swift 6 forbids touching an actor's stored
        // properties around one inside `init`.
        self.api = api
        self.environment = environment
        self.session = session
    }

    deinit {
        if let session { api.pointee.ReleaseSession(session) }
        if let environment { api.pointee.ReleaseEnv(environment) }
    }

    // MARK: - Synthesis

    /// Raw model output for one batch of phonemes: 24 kHz mono float, untrimmed.
    ///
    /// Untrimmed on purpose. `kokoro_onnx` trims **per batch** before
    /// concatenating, so a caller assembling long text has to trim each piece
    /// itself — trimming the joined result instead would leave every internal
    /// pad in place and put pauses in the middle of sentences.
    public func audio(
        phonemes: String,
        style: [Float],
        speed: Float = 1.0
    ) throws -> [Float] {
        let tokens = KokoroTokenizer.tokens(for: phonemes)
        // Two is the padding alone — nothing survived the vocabulary.
        guard tokens.count > 2 else { throw Failure.emptyText }
        guard style.count == KokoroVoices.styleWidth else {
            throw Failure.cannotBuildInput("style must be \(KokoroVoices.styleWidth) floats")
        }

        var memoryInfo: OpaquePointer?
        try check(
            api.pointee.CreateCpuMemoryInfo(OrtArenaAllocator, OrtMemTypeDefault, &memoryInfo)
        ) { Failure.cannotBuildInput($0) }
        defer { api.pointee.ReleaseMemoryInfo(memoryInfo) }

        var tokenValues = tokens
        var styleValues = style
        var speedValues = [min(max(speed, Self.speedRange.lowerBound), Self.speedRange.upperBound)]

        var tokenShape: [Int64] = [1, Int64(tokens.count)]
        var styleShape: [Int64] = [1, Int64(KokoroVoices.styleWidth)]
        var speedShape: [Int64] = [1]

        let tokenTensor = try tensor(
            &tokenValues, shape: &tokenShape,
            type: ONNX_TENSOR_ELEMENT_DATA_TYPE_INT64, memoryInfo: memoryInfo
        )
        defer { api.pointee.ReleaseValue(tokenTensor) }

        let styleTensor = try tensor(
            &styleValues, shape: &styleShape,
            type: ONNX_TENSOR_ELEMENT_DATA_TYPE_FLOAT, memoryInfo: memoryInfo
        )
        defer { api.pointee.ReleaseValue(styleTensor) }

        let speedTensor = try tensor(
            &speedValues, shape: &speedShape,
            type: ONNX_TENSOR_ELEMENT_DATA_TYPE_FLOAT, memoryInfo: memoryInfo
        )
        defer { api.pointee.ReleaseValue(speedTensor) }

        // The names this model actually exposes. A newer export uses
        // `input_ids` and an int32 speed; that branch is dead for this file and
        // is deliberately not carried, because an int32 speed silently
        // quantises 1.5 to 1 and the bug would be a voice that ignores the
        // speed setting.
        let inputNames = ["tokens", "style", "speed"]
        let outputNames = ["audio"]

        var inputs: [OpaquePointer?] = [tokenTensor, styleTensor, speedTensor]
        var output: OpaquePointer?

        try withCStrings(inputNames) { inputPointers in
            try withCStrings(outputNames) { outputPointers in
                try check(
                    api.pointee.Run(
                        session, nil,
                        inputPointers, &inputs, inputs.count,
                        outputPointers, outputNames.count, &output
                    )
                ) { Failure.inferenceFailed($0) }
            }
        }
        defer { api.pointee.ReleaseValue(output) }

        return try samples(from: output)
    }

    // MARK: - Reading the answer

    private func samples(from value: OpaquePointer?) throws -> [Float] {
        var info: OpaquePointer?
        try check(api.pointee.GetTensorTypeAndShape(value, &info)) { Failure.unexpectedOutput($0) }
        defer { api.pointee.ReleaseTensorTypeAndShapeInfo(info) }

        var elementType = ONNX_TENSOR_ELEMENT_DATA_TYPE_UNDEFINED
        try check(api.pointee.GetTensorElementType(info, &elementType)) {
            Failure.unexpectedOutput($0)
        }
        guard elementType == ONNX_TENSOR_ELEMENT_DATA_TYPE_FLOAT else {
            throw Failure.unexpectedOutput("audio is not float32")
        }

        var count = 0
        try check(api.pointee.GetTensorShapeElementCount(info, &count)) {
            Failure.unexpectedOutput($0)
        }
        guard count > 0 else { throw Failure.unexpectedOutput("audio is empty") }

        var raw: UnsafeMutableRawPointer?
        try check(api.pointee.GetTensorMutableData(value, &raw)) { Failure.unexpectedOutput($0) }
        guard let raw else { throw Failure.unexpectedOutput("audio has no data") }

        // Copied out before the tensor is released two frames up. Returning a
        // buffer that points into freed runtime memory is the kind of bug that
        // works in every test and crashes on a long sentence.
        return Array(UnsafeBufferPointer(
            start: raw.assumingMemoryBound(to: Float.self), count: count
        ))
    }

    // MARK: - C plumbing

    private func tensor<T>(
        _ values: inout [T],
        shape: inout [Int64],
        type: ONNXTensorElementDataType,
        memoryInfo: OpaquePointer?
    ) throws -> OpaquePointer? {
        var tensor: OpaquePointer?
        let byteCount = values.count * MemoryLayout<T>.stride
        try check(
            values.withUnsafeMutableBytes { buffer in
                api.pointee.CreateTensorWithDataAsOrtValue(
                    memoryInfo, buffer.baseAddress, byteCount,
                    &shape, shape.count, type, &tensor
                )
            }
        ) { Failure.cannotBuildInput($0) }
        return tensor
    }

    /// Holds every name alive for the duration of the call.
    ///
    /// The obvious `names.map { strdup($0) }` leaks, and the equally obvious
    /// `names.map { ($0 as NSString).utf8String }` hands ORT pointers whose
    /// owners are already gone — a use-after-free that usually survives because
    /// the memory has not been reused yet.
    private func withCStrings<Result>(
        _ names: [String],
        _ body: (UnsafeMutablePointer<UnsafePointer<CChar>?>) throws -> Result
    ) rethrows -> Result {
        var copies = names.map { strdup($0) }
        defer { copies.forEach { free($0) } }
        return try copies.withUnsafeMutableBufferPointer { buffer in
            try buffer.withMemoryRebound(to: UnsafePointer<CChar>?.self) { rebound in
                try body(rebound.baseAddress!)
            }
        }
    }

    /// Turns an `OrtStatus` into a Swift error, and releases it either way.
    ///
    /// Every ORT call returns a status that is `nil` on success and an owned
    /// object otherwise. Ignoring it leaks; checking it without releasing leaks
    /// exactly as much.
    private func check(_ status: OpaquePointer?, _ failure: (String) -> Failure) throws {
        try Self.check(api, status, failure)
    }

    /// Takes the api explicitly rather than reading `self`, so `init` can use it
    /// before the stored properties exist.
    private static func check(
        _ api: UnsafePointer<OrtApi>,
        _ status: OpaquePointer?,
        _ failure: (String) -> Failure
    ) throws {
        guard let status else { return }
        defer { api.pointee.ReleaseStatus(status) }
        let message = api.pointee.GetErrorMessage(status).map { String(cString: $0) } ?? "unknown"
        throw failure(message)
    }
}
