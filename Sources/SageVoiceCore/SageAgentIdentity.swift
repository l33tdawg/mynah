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
///   * `MynahIdentity.applianceKeyURL()` — `appliance-agent.key`, the identity
///     everything actually signs as. On the author's machine it now derives to
///     `1ab7aa10…`, the node's active `agent/sage-voice-bridge`.
///
/// Both were checked against the live node before this file was written.
///
/// ## A correction, because the earlier version of this comment was evidence
///
/// This said the pinned key derived to `74140c2d…`, "which is the row named
/// 'Mynah - Sage Voice Bridge'". Every word of that was observed and it still
/// pointed at the wrong key. `74140c2d…` *was* a row under that name — because
/// `sage_inception` auto-registers whatever key signs it, and the row it had
/// created was `pending_review`. A pending row and an active one look identical
/// through the only question that was asked, "does a row exist".
///
/// The question that separates them is **status**, and the node answers it
/// plainly: `sage_find_agent` lists only active agents, and it returns exactly
/// one for this appliance. So an id checked against the live node is worth
/// nothing here unless the check was for an *active* registration — finding the
/// name you expected is the failure mode, not the confirmation.
///
/// See `MynahIdentity.migrateApplianceKeyIfNeeded` for how the wrong key came
/// to be pinned in the first place.
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
