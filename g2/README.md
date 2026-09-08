# Mynah for Even G2

An Even Hub companion for the existing Mynah notes-to-self conversation.
Tap the glasses or R1 to record, tap again to submit, and swipe through the
answer. Recording is limited to one minute. Double-tap opens the exit flow.

The phone runs the SDK companion; the Mac transcribes the G2 microphone audio.
The recording enters the **same serial voice-note inbox** as Signal and
WhatsApp, using the linked self-chat selected in Mynah Settings. There is no second brain,
prompt, tool catalogue, or glasses history. SAGE context, task handling, search,
attachments, chat history, and turn housekeeping follow the existing daemon.
The spoken question is labelled “From G2” in chat; the normal answer appears
there and on the glasses. No speech synthesis is needed for a glasses reply.

Once the Mac has submitted a recording to the message inbox, leaving
the companion does not cancel that request. “Working” is a quiet status, with
no audio, haptics, repeated notifications, or artificial progress percentage.
The final answer appears as a complete response. Reconnecting checks the Mac's
pending/latest-answer state rather than replaying the question or its tools.
Answers are not injected over another glasses app; return to Mynah to see them,
or read the ordinary notes-to-self reply.

## Quick hardware test

1. Install the updated Mynah daemon and `sage-voice-webrtc` on the Mac, and the
   updated `sage-call-relay` on the relay host. The new relay endpoints are
   `GET /{token}/connect` and a CORS-enabled `POST /{token}/offer`.
2. Use Even app **2.2.9 or newer**, paired G2 glasses, and the same Even account
   in the [developer portal](https://hub.evenrealities.com/login). Reopen the
   phone app after signing into the portal to expose developer features.
3. On the development Mac:

   ```sh
   cd g2
   npm ci
   npm run dev -- --port 5173 --strictPort
   npx evenhub qr --url http://YOUR_MAC_LAN_IP:5173/
   ```

4. Put the phone on the same Wi-Fi. In Even Hub choose **Scan QR** and scan the
   development QR. Keep Even foregrounded and the phone unlocked for QR tests.
5. On your Mac, open **Mynah Settings → General → Your phone → Pair G2**.
   Link Signal or WhatsApp first; if both are linked, choose where G2 conversations appear.
   Copy the private pairing link and paste it into Mynah G2 in the Even app. The companion saves the pairing and reconnects automatically, including after restarting Mynah. Allow G2 microphone access.
6. Tap, speak, tap again. Check the listening/sending/working states, the
   recognized question in chat, and matching text replies in both places.
7. Ask a follow-up and verify context. Ask for a task or lookup, leave the
   companion after it says Working, then reopen and check the result without
   resubmitting. Files are delivered to chat, not rendered on the glasses.

The input accepts only `https://call.sage.delivery/<32-hex-token>`. For another
relay, change `relayOrigin` in `src/protocol.ts` and the manifest's network
whitelist together. The relay's caller endpoints use capability tokens, not
cookies. CORS is confined to caller configuration/offers, never appliance
enrollment or credential endpoints. Audio and replies use encrypted WebRTC
data channels with the existing ICE/TURN setup.

## Packaging and distribution

```sh
npm test
npm run pack
```

This creates `mynah-g2.ehpk` with SDK **0.0.14**, an explicit minimum Even app
version of **2.2.9**, and the manifest's English language declaration. Packages
contain code and no Mynah credentials. Built files and dependencies are ignored
by Git; the dependency lock is committed.

- **Private install:** portal → project → Private builds → upload `.ehpk`.
  Phone: Even Hub → Me → Apps → Private builds → Install.
- **Pocket/locked-phone test:** create a Beta group, add your Even account,
  upload the build and assign it to the group. Phone: Me → Beta tester → Install.
  QR/private lifecycle behavior is not proof of released background behavior.
- **Public release:** Draft → Test → Submitted → Released, via manual review.
  Prepare actual device/simulator screenshots, monochrome icon assets, a hosted
  privacy policy, English release notes, and a successful five-minute lock test.
  Released packages are immutable; publish changes under a higher version.

Official references: [local testing](https://hub.evenrealities.com/docs/test/local-testing),
[private builds](https://hub.evenrealities.com/docs/test/private-testing),
[beta groups](https://hub.evenrealities.com/docs/test/beta-testing),
[packaging](https://hub.evenrealities.com/docs/ship/packaging),
[submission](https://hub.evenrealities.com/docs/ship/app-submission).

## Current limits to verify on hardware

- The public SDK does not expose Signal/WhatsApp inboxes or mirrored phone
  notifications. This companion addresses only Mynah's authorized self-chat.
  Replying to third-party contacts is not implemented.
- The companion stores the validated connection link in Even SDK local storage
  for reopening, and clears it on Forget pairing. That storage has no documented
  encryption guarantee. It stores no microphone recordings, model credentials,
  or chat transcript. The link is a bearer capability; keep it private.
- G2 has a persistent data-only pairing, separate from temporary spoken calls.
  The Mac stores its token and self-chat recipient privately and restores the
  endpoint on startup. Choose **Unpair** under Even G2 glasses in Mynah Settings to revoke it; Forget pairing
  clears only the phone copy. Requests are never replayed by automatic reconnect.
- Status/latest answer survives companion reconnection while the daemon runs.
  It is not a durable glasses-job database: a Mac daemon restart loses the
  in-memory waiting request and latest-display state. Completed chat replies
  and existing chat persistence remain available as usual.
- iOS beta/released WebViews can continue while locked; Android may suspend or
  reclaim them. **Our WebRTC path has to be tested on the actual phone**. It does
  not rely on `document.hidden` to decide whether glasses input is allowed.
- Recording that has not been submitted is discarded on exit. Once submitted,
  transcription and work continue in the serial chat inbox. Repeating a task
  request is a new request, so check chat before retrying an uncertain delivery.

See [background lifecycle](https://hub.evenrealities.com/docs/build/background-lifecycle)
and [device APIs](https://hub.evenrealities.com/docs/build/device-apis).
