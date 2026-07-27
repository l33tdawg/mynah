import Foundation

/// Identity this daemon registers under on the SAGE chain.
///
/// Replaces QuietType's `SageAgentIdentity.privateDictate`. Corrections and
/// vocabulary learned here are written to SAGE rather than to a local file,
/// so they federate to the operator's other SAGE nodes.
public enum SageVoiceIdentity {
    public static let agentName = "sage-voice-bridge"
    public static let agentType = "voice_agent_manager"
    public static let capabilities = [
        "dictation_profile_memory",
        "vocabulary_memory",
        "correction_memory",
        "style_profile_memory",
        "agent_manager",
    ]
}
