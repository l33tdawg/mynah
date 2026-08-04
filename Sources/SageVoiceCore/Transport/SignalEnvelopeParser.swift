import Foundation

/// Turns a signal-cli JSON-RPC frame into a `SignalIncomingMessage`.
///
/// Auto receive mode (`--receive-mode=on-start`, the daemon default) emits:
///
///     {"jsonrpc":"2.0","method":"receive","params":{"envelope":{...},"account":"+..."}}
///
/// Manual mode (after `subscribeReceive`) wraps the same payload one level deeper:
///
///     {"jsonrpc":"2.0","method":"receive","params":{"subscription":0,"result":{"envelope":{...},"account":"+..."}}}
///
/// Both shapes are accepted. Envelopes that carry neither a `dataMessage` nor a
/// `syncMessage.sentMessage` (receipts, typing indicators, read syncs) parse to `nil`.
public enum SignalEnvelopeParser {
    public static let receiveMethod = "receive"

    /// Parses a whole `receive` notification.
    public static func parseNotification(
        _ frame: [String: Any],
        attachmentsDirectory: URL,
        fileManager: FileManager = .default
    ) -> SignalIncomingMessage? {
        guard let params = frame["params"] as? [String: Any] else {
            return nil
        }
        let payload = (params["result"] as? [String: Any]) ?? params
        guard let envelope = payload["envelope"] as? [String: Any] else {
            return nil
        }
        let account = string(payload["account"]) ?? string(params["account"]) ?? string(frame["account"])
        return parseEnvelope(
            envelope,
            account: account,
            attachmentsDirectory: attachmentsDirectory,
            fileManager: fileManager
        )
    }

    public static func parseEnvelope(
        _ envelope: [String: Any],
        account: String?,
        attachmentsDirectory: URL,
        fileManager: FileManager = .default
    ) -> SignalIncomingMessage? {
        let source = string(envelope["source"])
        let sourceNumber = string(envelope["sourceNumber"])
        let sourceUUID = string(envelope["sourceUuid"]) ?? string(envelope["sourceUUID"])
        let sourceName = string(envelope["sourceName"])
        let sourceDevice = int(envelope["sourceDevice"])
        let envelopeTimestamp = int64(envelope["timestamp"]) ?? 0

        // An edited message re-delivers its payload inside editMessage.dataMessage.
        let dataMessage = (envelope["dataMessage"] as? [String: Any])
            ?? ((envelope["editMessage"] as? [String: Any])?["dataMessage"] as? [String: Any])

        if let dataMessage {
            return SignalIncomingMessage(
                kind: .direct,
                account: account,
                source: source,
                sourceNumber: sourceNumber,
                sourceUUID: sourceUUID,
                sourceName: sourceName,
                sourceDevice: sourceDevice,
                destination: nil,
                destinationNumber: nil,
                destinationUUID: nil,
                groupID: groupID(from: dataMessage),
                timestamp: int64(dataMessage["timestamp"]) ?? envelopeTimestamp,
                text: text(from: dataMessage),
                attachments: attachments(
                    from: dataMessage,
                    directory: attachmentsDirectory,
                    fileManager: fileManager
                )
            )
        }

        if let syncMessage = envelope["syncMessage"] as? [String: Any],
           let rawSentMessage = syncMessage["sentMessage"] as? [String: Any] {
            // **The same edit unwrap as above, on the path the appliance
            // actually uses.**
            //
            // It was written for `dataMessage` only, and the appliance is driven
            // from Note-to-Self — every message the owner sends it arrives as
            // `syncMessage.sentMessage`, never as a direct `dataMessage`. So the
            // one branch that had the fix was the one branch that never runs
            // here.
            //
            // What it cost, on 4 August 2026: he typed a question, edited it to
            // add a second question mark, and the appliance went silent. Signal
            // re-delivers an edited message with its payload nested inside
            // `editMessage.dataMessage`, so `text` came back empty and the
            // daemon logged `ignored (no text, no audio)` and dropped it. From
            // his side Signal was "completely dead" — every message he sent was
            // one he had edited.
            //
            // Silent, because an envelope with no text is an ordinary thing: a
            // receipt, a typing indicator, a read sync. This one looked exactly
            // like those.
            let sentMessage = (rawSentMessage["editMessage"] as? [String: Any])?["dataMessage"]
                as? [String: Any] ?? rawSentMessage
            return SignalIncomingMessage(
                kind: .syncSent,
                account: account,
                source: source,
                sourceNumber: sourceNumber,
                sourceUUID: sourceUUID,
                sourceName: sourceName,
                sourceDevice: sourceDevice,
                destination: string(sentMessage["destination"]),
                destinationNumber: string(sentMessage["destinationNumber"]),
                destinationUUID: string(sentMessage["destinationUuid"]) ?? string(sentMessage["destinationUUID"]),
                groupID: groupID(from: sentMessage),
                timestamp: int64(sentMessage["timestamp"]) ?? envelopeTimestamp,
                text: text(from: sentMessage),
                attachments: attachments(
                    from: sentMessage,
                    directory: attachmentsDirectory,
                    fileManager: fileManager
                )
            )
        }

        return nil
    }

    // MARK: Pieces

    static func text(from message: [String: Any]) -> String? {
        guard let raw = string(message["message"]) else {
            return nil
        }
        return raw.isEmpty ? nil : raw
    }

    static func groupID(from message: [String: Any]) -> String? {
        guard let info = message["groupInfo"] as? [String: Any] else {
            return nil
        }
        return string(info["groupId"]) ?? string(info["groupID"])
    }

    static func attachments(
        from message: [String: Any],
        directory: URL,
        fileManager: FileManager
    ) -> [SignalAttachment] {
        guard let entries = message["attachments"] as? [[String: Any]] else {
            return []
        }
        return entries.compactMap { entry in
            guard let id = string(entry["id"]) else {
                return nil
            }
            let contentType = string(entry["contentType"])
            let filename = string(entry["filename"]) ?? string(entry["fileName"])
            return SignalAttachment(
                id: id,
                contentType: contentType,
                filename: filename,
                size: int64(entry["size"]),
                caption: string(entry["caption"]),
                localURL: SignalAttachmentLocator.locate(
                    id: id,
                    filename: filename,
                    contentType: contentType,
                    in: directory,
                    fileManager: fileManager
                )
            )
        }
    }

    // MARK: Loose JSON helpers

    static func string(_ value: Any?) -> String? {
        if let value = value as? String {
            return value
        }
        return nil
    }

    static func int(_ value: Any?) -> Int? {
        if let value = value as? Int {
            return value
        }
        if let value = value as? Double {
            return Int(value)
        }
        if let value = value as? NSNumber {
            return value.intValue
        }
        if let value = value as? String {
            return Int(value)
        }
        return nil
    }

    static func int64(_ value: Any?) -> Int64? {
        if let value = value as? Int64 {
            return value
        }
        if let value = value as? Int {
            return Int64(value)
        }
        if let value = value as? NSNumber {
            return value.int64Value
        }
        if let value = value as? Double {
            return Int64(value)
        }
        if let value = value as? String {
            return Int64(value)
        }
        return nil
    }
}
