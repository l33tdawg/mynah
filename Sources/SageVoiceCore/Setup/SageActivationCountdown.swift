import Foundation

/// How far a brand-new SAGE node is from being able to remember anything.
///
/// ## Why this exists
///
/// A vendored node's genesis sets consensus app version 23, and the first-party
/// Companion cannot write until governed **app-v24** activates. Until then every
/// write is refused with "first-party companion memory writes require governed
/// app-v24 activation". Measured on two independent fresh chains: activation is
/// planned for height 204, reached at roughly one block every four seconds —
/// about thirteen minutes from first launch.
///
/// That window is unavoidable and self-resolving, so the job here is not to fix
/// it but to *describe* it. An appliance that sits mute for thirteen minutes
/// with no explanation is indistinguishable from a broken one, and this codebase
/// already refuses to let a node look like it is working when it is not — this
/// is the same rule pointed the other way: do not look broken while working.
///
/// ## Why the block height and not a clock
///
/// A wall-clock countdown is a promise about the future. Block pacing is set by
/// the pending-plan pump and is not guaranteed, so "3 minutes" that takes nine
/// is the same class of lie. Height is an observed fact: it is published, it
/// only moves forward, and the remaining distance is arithmetic rather than
/// prediction. Time is derived from it for display and is explicitly an
/// estimate.
///
/// ## Why CometBFT's RPC rather than SAGE's REST
///
/// Because REST needs a signature and this does not. `GET /v1/agents` began
/// answering **401 Missing authentication headers** in 11.16.x, and the
/// consensus RPC's `/abci_info` is unauthenticated on loopback and carries
/// exactly the two facts needed — `app_version` and `last_block_height` — in one
/// request, with no identity established yet. On a first run there *is* no
/// identity: genesis is what mints it.
public struct SageActivationState: Sendable, Equatable {

    /// Consensus app version the node is currently running.
    public let appVersion: Int
    /// Height of the last committed block.
    public let height: Int64

    public init(appVersion: Int, height: Int64) {
        self.appVersion = appVersion
        self.height = height
    }

    /// The app version at which the Companion is admitted.
    public static let companionAppVersion = 24

    /// Where the governed upgrade plan lands on a fresh personal node.
    ///
    /// **An estimate used only for the progress figure, never for the verdict.**
    /// Measured as 204 on two independently created chains, but it is SAGE's
    /// number to choose and there is no unauthenticated endpoint that reports
    /// the pending plan. `isActivated` therefore reads `appVersion`, which is
    /// authoritative: if SAGE ever moves the plan, the bar is wrong for a while
    /// and the answer is still right.
    public static let estimatedActivationHeight: Int64 = 204

    /// Roughly four seconds per block, measured on a quiescent chain being
    /// heartbeaten by the pending-plan pump (whose own interval is five).
    public static let estimatedSecondsPerBlock: Double = 4

    /// Whether the Companion can write. The authoritative signal.
    public var isActivated: Bool { appVersion >= Self.companionAppVersion }

    /// Blocks still to go, or zero once activated.
    ///
    /// Clamped at zero rather than allowed to go negative: a chain that passes
    /// the estimate without the version flipping should read as "almost there",
    /// not as a negative countdown.
    public var blocksRemaining: Int64 {
        if isActivated { return 0 }
        return max(0, Self.estimatedActivationHeight - height)
    }

    /// How far along, 0 to 1, for a progress indicator.
    public var fractionComplete: Double {
        if isActivated { return 1 }
        guard Self.estimatedActivationHeight > 0 else { return 0 }
        let done = Double(min(height, Self.estimatedActivationHeight))
        return max(0, min(1, done / Double(Self.estimatedActivationHeight)))
    }

    /// Estimated seconds remaining. `nil` once activated.
    public var estimatedSecondsRemaining: TimeInterval? {
        if isActivated { return nil }
        return Double(blocksRemaining) * Self.estimatedSecondsPerBlock
    }

    /// Owner-facing sentence.
    ///
    /// Minutes, rounded up, and never "0 minutes" — a countdown that reaches
    /// zero while the thing is still working has started lying at the last
    /// moment. "Less than a minute" stays true right up until it is done. No
    /// block heights either: the number is real but it is not a fact anybody
    /// outside this file should have to hold.
    public var ownerDescription: String {
        if isActivated { return "SAGE is ready." }
        guard let seconds = estimatedSecondsRemaining, seconds > 0 else {
            return "Getting SAGE ready — nearly there."
        }
        let minutes = Int(ceil(seconds / 60))
        if minutes <= 1 { return "Getting SAGE ready — less than a minute left." }
        return "Getting SAGE ready — about \(minutes) minutes left."
    }
}

// MARK: - Reading it off the node

/// Reads `SageActivationState` from the local consensus RPC.
public struct SageActivationProbe: Sendable {

    private let endpoint: URL
    private let session: URLSession

    public init(endpoint: URL? = nil, timeout: TimeInterval = 3) {
        self.endpoint = endpoint ?? Self.defaultEndpoint()
        self.session = LoopbackSecurity.makeSession(timeout: timeout)
    }

    /// `127.0.0.1:26657` is CometBFT's shipped RPC default, which is what a
    /// node Mynah starts will be listening on. `SAGE_CMT_RPC_ADDR` overrides it
    /// and is honoured only when it points at this machine, for the same reason
    /// `ApplianceWriteReadinessCheck` refuses a non-loopback `SAGE_API_URL`: a
    /// reading taken from a stranger's node is somebody else's chain reported
    /// as the owner's.
    public static func defaultEndpoint(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL {
        let fallback = URL(string: "http://127.0.0.1:26657")!
        let base = environment["SAGE_CMT_RPC_ADDR"]
            .flatMap(Self.httpURL(fromRPCAddress:))
            .flatMap { LoopbackSecurity.isLoopback($0) ? $0 : nil }
            ?? fallback
        return base.appendingPathComponent("abci_info")
    }

    /// CometBFT writes this as `tcp://host:port`, which `URL` will parse but
    /// `URLSession` will not fetch.
    static func httpURL(fromRPCAddress raw: String) -> URL? {
        var value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return nil }
        for prefix in ["tcp://", "http://", "https://"] where value.hasPrefix(prefix) {
            value = String(value.dropFirst(prefix.count))
            break
        }
        return URL(string: "http://\(value)")
    }

    /// `nil` when no node answered — which on this path is ordinary rather than
    /// exceptional, because the caller may well have started one a moment ago.
    public func read() async -> SageActivationState? {
        guard (try? LoopbackSecurity.requireLoopback(endpoint)) != nil else { return nil }
        var request = URLRequest(url: endpoint)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        guard let (data, response) = try? await session.data(for: request),
              (try? LoopbackSecurity.verifyResponseOrigin(response, expected: endpoint)) != nil,
              let code = (response as? HTTPURLResponse)?.statusCode, code == 200 else {
            return nil
        }
        return Self.parse(data)
    }

    /// Both numbers arrive as JSON *strings* in CometBFT's response, and a
    /// missing `app_version` means zero rather than absent — pre-v24 nodes have
    /// been seen to omit it.
    public static func parse(_ data: Data) -> SageActivationState? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let result = root["result"] as? [String: Any],
              let response = result["response"] as? [String: Any] else {
            return nil
        }
        guard let height = integer(response["last_block_height"]) else { return nil }
        let version = integer(response["app_version"]) ?? 0
        return SageActivationState(appVersion: Int(version), height: height)
    }

    private static func integer(_ value: Any?) -> Int64? {
        if let string = value as? String { return Int64(string) }
        if let number = value as? NSNumber { return number.int64Value }
        return nil
    }
}
