#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif
import Foundation

/// Signing an ordinary HTTP request to the node as the appliance.
///
/// **Everything else in this product reaches SAGE over MCP**, where the
/// `sage-gui mcp` child process holds `SAGE_IDENTITY_PATH` and does the signing,
/// and Mynah never touches a key. That arrangement is deliberate and nothing
/// here changes it.
///
/// This exists because one thing the appliance needs is not an MCP tool. SAGE
/// 11.18.12 added the durable message wake bus as `GET /v1/messages/wake` — a
/// REST route on the app-v23 pipeline-agent boundary, with no tool behind it and
/// no plan for one, because a long-lived SSE stream is not a shape the tool
/// protocol has. So the one caller that needs it has to sign for itself.
///
/// ## Why this is a separate type from the thing that uses it
///
/// `ApplianceStanding` records what happened the last time this product read a
/// REST route: it sent an *unsigned* `GET /v1/agents`, got
/// `401 Missing authentication headers`, and the conclusion drawn was that the
/// appliance could not report its own standing. The route was fine. The request
/// was unsigned.
///
/// A signature is exactly the kind of thing that is either right or produces a
/// 401 that reads like a permissions problem, so the derivation lives on its own
/// with its own tests and a pinned vector, rather than inline in a network
/// client where "did not connect" and "signed wrongly" look identical.
///
/// ## The scheme, from `internal/auth/ed25519.go`
///
///     canonical = method + " " + path[?query] + "\n" + body
///     message   = SHA-256(canonical) ‖ BigEndian(UInt64(timestamp)) [‖ nonce]
///     signature = Ed25519(message)
///
/// carried as three required headers and one optional one:
///
///   * `X-Agent-ID`   — hex of the Ed25519 *public* key, which is also the
///     on-chain agent id. See `SageAgentIdentity`.
///   * `X-Signature`  — hex of the 64-byte signature.
///   * `X-Timestamp`  — unix seconds, accepted within five minutes either way.
///   * `X-Nonce`      — hex, optional, and *this product always sends one*.
///
/// The nonce is client-generated, not server-issued, so there is no round trip
/// to fetch one, and this product always sends one. The node keys its replay
/// cache on `(agentID, signature)`, and a reconnect loop that redials within
/// the same second signs the *same message* twice — so the nonce is what
/// guarantees the two attempts are distinguishable.
///
/// It happens not to be load-bearing today, and the reason is worth knowing
/// rather than depending on: CryptoKit's Ed25519 is *hedged*, so signing
/// identical bytes twice already yields two different signatures. That is an
/// implementation property of the platform, not of the protocol — Go's
/// `ed25519.Sign` is deterministic, and a CryptoKit that followed it would make
/// the nonce the only thing standing between a redial and `Replay detected`.
/// `testSigningTheSameBytesTwiceGivesTwoValidSignatures` is where that
/// assumption is pinned, so the day it changes is a red test rather than an
/// intermittent 401.
///
/// **The path must be signed exactly as it is sent, query string included.**
/// `Ed25519AuthMiddleware` rebuilds it as `r.URL.Path + "?" + r.URL.RawQuery`,
/// so a client that signs the path and then appends query items has signed a
/// different request than it made, and gets a 401 that says nothing about why.
public enum SageRequestSigning {

    /// How far the node's clock tolerance stretches, from `maxTimestampSkew`.
    ///
    /// Not enforced here — the node enforces it. Recorded because a caller that
    /// signs once and retries for longer than this will fail on the retry with
    /// `Timestamp expired`, and the fix is to re-sign rather than to back off.
    public static let clockSkewAllowance: TimeInterval = 5 * 60

    /// The exact bytes the node verifies.
    ///
    /// Split out from ``headers(method:path:body:key:timestamp:nonce:)`` so a
    /// test can pin the construction against a vector without owning a key, and
    /// so the two halves of a signing bug — wrong bytes, wrong key — can be
    /// told apart.
    public static func message(
        method: String,
        path: String,
        body: Data,
        timestamp: Int64,
        nonce: Data
    ) -> Data {
        var canonical = Data("\(method) \(path)\n".utf8)
        canonical.append(body)

        var message = Data(SHA256.hash(data: canonical))
        // `binary.BigEndian.PutUint64(ts, uint64(timestamp))` on the node — the
        // *bit pattern* of the int64, not a saturating conversion, which is why
        // this goes through `UInt64(bitPattern:)` rather than `UInt64(_:)`. The
        // difference is invisible until a clock reports a negative epoch, where
        // the conversion would trap and take the daemon with it.
        withUnsafeBytes(of: UInt64(bitPattern: timestamp).bigEndian) {
            message.append(contentsOf: $0)
        }
        message.append(nonce)
        return message
    }

    /// The headers to attach to a request, or nil if the key cannot sign.
    ///
    /// Nil rather than throwing, and nil rather than an empty dictionary: the
    /// only caller's correct response to "this appliance has no usable key" is
    /// to not make the request at all, and a request sent with no auth headers
    /// is the exact mistake documented at the top of this file.
    public static func headers(
        method: String,
        path: String,
        body: Data = Data(),
        key: Curve25519.Signing.PrivateKey,
        timestamp: Int64,
        nonce: Data
    ) -> [String: String]? {
        let signed = message(
            method: method, path: path, body: body, timestamp: timestamp, nonce: nonce
        )
        // CryptoKit's signing is throwing. There is no recovery worth writing
        // for a key that loaded and then declined to sign, and no request worth
        // sending without the header, so it joins the nil case above.
        guard let signature = try? key.signature(for: signed) else { return nil }
        return [
            "X-Agent-ID": hex(key.publicKey.rawRepresentation),
            "X-Signature": hex(signature),
            "X-Timestamp": String(timestamp),
            "X-Nonce": hex(nonce)
        ]
    }

    /// Sixteen bytes of randomness, which is what the node's replay cache needs
    /// to tell two same-second requests apart.
    public static func freshNonce() -> Data {
        var bytes = Data(count: 16)
        for index in bytes.indices { bytes[index] = UInt8.random(in: 0...255) }
        return bytes
    }

    /// The appliance's signing key, read from the same file everything else
    /// signs as.
    ///
    /// Accepts both shapes the node writes — 32 bytes of seed, or 64 bytes of
    /// seed followed by the public key — for the reason
    /// `SageAgentIdentity.agentID(ofKeyBytes:)` does, and by taking the first 32
    /// bytes in both cases so the two agree by construction. Two answers to
    /// "which key is this" is how one of them stays wrong.
    public static func applianceKey(
        at url: URL = MynahIdentity.applianceKeyURL()
    ) -> Curve25519.Signing.PrivateKey? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        guard data.count == 32 || data.count == 64 else { return nil }
        return try? Curve25519.Signing.PrivateKey(rawRepresentation: data.prefix(32))
    }

    private static func hex(_ data: Data) -> String {
        data.map { String(format: "%02x", $0) }.joined()
    }
}
