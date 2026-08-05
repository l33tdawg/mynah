import CryptoKit
import Foundation

/// Working out which agent on the node is *this* one.
///
/// Sounds trivial and was not. The screens that wanted to show the appliance's
/// own standing were matching rows on the display name, because an attempt to
/// derive the id from the key "matched no row" — and the honest conclusion drawn
/// from that was that the node assigns an id unrelated to the key.
///
/// It does not. The id is exactly the hex of the key's Ed25519 public key. The
/// derivation failed because there are two key files in the appliance's support
/// directory and the obvious one is the dead one:
///
///   * `MynahIdentity.keyURL()` — `agent.key`, the app window's old identity.
///     Since "One appliance is one agent" the window signs as the appliance, so
///     nothing registers this key any more. On the author's machine it derives
///     to `17641c48…`, which is genuinely absent from the roster.
///   * `MynahIdentity.applianceKeyURL()` — the identity everything actually
///     signs as. It has since moved to `~/.sage/agents/mynah/agent.key`, where
///     CEREBRUM can find it; the bytes and therefore the id are unchanged,
///     which is the whole point of that migration.
///
/// ## Which agent that is, and how to find out rather than believe this
///
/// **The appliance signs as `74140c2d…`.** On the owner's node that is the
/// agent displayed as *"Mynah - Sage Voice Bridge"*, registered name
/// `agent-74140c2d`, provider `audit`.
///
/// `1ab7aa10…` is a *different agent*: `agent/sage-voice-bridge`, the Claude
/// Code MCP identity belonging to this repository. It is a developer key, and
/// it holds more standing than the appliance does. Confusing the two is not an
/// academic error — it is how the owner's messages once reached strangers.
///
/// **This comment used to assert the opposite, in a section headed "A
/// correction", and said both ids had been "checked against the live node".**
/// That is why the paragraph below matters more than the two hex strings above.
///
/// The retraction reasoned like this: `74140c2d…` was a row created by
/// `sage_inception` auto-registering whatever key signed it, and that row was
/// `pending_review`, so an active row under the expected name must be the real
/// one. The premise was probably true when it was written. The inference was
/// not, and the conclusion is false today — `74140c2d…` is `active`, and
/// `1ab7aa10…` was never the appliance at all.
///
/// The reason it went wrong is worth more than the fix. Every question it
/// asked — does a row exist under this name, is that row active — is a question
/// a *developer's* key passes too, because the developer's key is also
/// registered, also active, and also named after this project. A roster row
/// proves nothing about which key file a process signs with.
///
/// So do not trust the hex above. Ask the appliance's own signature:
///
///     Run `sage_status` signed as the appliance and read `agent_id`.
///
/// That is the one check that cannot be answered by the wrong key, because the
/// answer *is* the signature. It is also the route `ApplianceWriteReadiness`
/// and the Memories page now read standing from, for the same reason. Verifying
/// any SAGE surface through a developer's own MCP connection green-lights
/// screens that are broken for Mynah — which is precisely how a 401 on a roster
/// came to be read as "the appliance cannot report its own standing".
///
/// See `MynahIdentity.migrateApplianceKeyIfNeeded` for how a wrong key came to
/// be pinned in the first place.
///
/// Matching on the name is not merely less exact, it is actively wrong over
/// time: `SageRitual.adoptDisplayName` deliberately lets an operator's rename in
/// CEREBRUM stand, so the first time an owner personalises the agent the
/// name-match stops finding it and the screen reports a registered agent as
/// missing.
public enum SageAgentIdentity {

    /// The on-chain agent id for a key file, or nil if it cannot be read.
    ///
    /// Accepts both shapes the node writes, because both exist on a normal
    /// machine and the difference is invisible from the path:
    ///
    ///   * 32 bytes — the Ed25519 *seed* alone, which is what the appliance's
    ///     own keys are.
    ///   * 64 bytes — seed followed by the public key, which is what
    ///     `~/.sage/agent.key` is.
    ///
    /// Taking the first 32 bytes and deriving is correct for both: in the
    /// 64-byte form the trailing half is the public key that derivation
    /// reproduces. Verified against `~/.sage/agent.key`, which derives to
    /// `aa59221191776dfe…` — the node's `genesis-admin`.
    ///
    /// Deriving rather than reading the trailing bytes is deliberate. A
    /// truncated or half-written file would otherwise yield a plausible-looking
    /// id for a key that cannot sign, and an id that does not correspond to the
    /// signing key is worse than no id: it would attribute another agent's
    /// standing to this one.
    public static func agentID(ofKeyAt url: URL) -> String? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return agentID(ofKeyBytes: data)
    }

    /// Split out so the derivation can be tested without a file.
    public static func agentID(ofKeyBytes data: Data) -> String? {
        guard data.count == 32 || data.count == 64 else { return nil }
        guard let key = try? Curve25519.Signing.PrivateKey(rawRepresentation: data.prefix(32)) else {
            return nil
        }
        return key.publicKey.rawRepresentation.map { String(format: "%02x", $0) }.joined()
    }

    /// The appliance's own id — the identity every part of this product signs
    /// as, window and daemon alike.
    public static func applianceAgentID(
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> String? {
        agentID(ofKeyAt: MynahIdentity.applianceKeyURL(homeDirectory: homeDirectory))
    }
}
