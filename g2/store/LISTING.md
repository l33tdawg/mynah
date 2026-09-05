# Mynah — Even Hub listing

Author: Dhillon Kannabhiran (l33tdawg)
Support: dhillon@levelupctf.com
Website: https://github.com/l33tdawg/mynah
Category: Productivity
Tag: assistant
Tagline: Speak to Mynah. Read the answer on your glasses.
Privacy: https://call.sage.delivery/g2/privacy.html
Terms: https://call.sage.delivery/g2/terms.html

## About

Speak to Mynah. Read the answer on your Even G2 glasses.

Mynah connects your glasses to the Mynah assistant running on your Mac. Ask a question, capture a task, or look something up through the same assistant you already use in Signal or WhatsApp Notes to Self. Your question and answer stay in that conversation, with your existing SAGE context and tools.

A quiet status shows when Mynah is listening or working. The answer appears as readable text, without spoken playback. Submitted requests continue on your Mac if you leave the companion; reopen it to retrieve the result.

Pair once with your Mac; Mynah reconnects automatically afterward. Setup requires Even G2 paired with the Even app, an online Mac running Mynah with its G2 bridge, and a configured Signal or WhatsApp self-chat. Send //g2 in that chat and paste the private pairing link into the companion. Mynah G2 is a companion, not a standalone assistant.

Created by Dhillon Kannabhiran (l33tdawg).

Mynah G2 cannot read other apps’ inboxes or reply to mirrored phone notifications. Background connection behavior depends on your phone and the Even app.

## Release notes — 0.1.1

- Pair once and reconnect automatically; pairing survives Mac restarts.
- G2 pairing is separate from temporary voice-call links.
- Handle glasses and R1 gestures delivered as system, text, or list events.
- Add About, author, support, project, privacy, and terms links.
- Add an input-status readout to help verify hardware controls.

## Review status

The 0.1.0 voice-to-answer path was successfully tested by the owner on G2.
Both glasses and ring controls were reported unresponsive in that version.
The 0.1.1 input routing fix passes automated tests but still needs physical verification.
The 0.1.1 backend and companion are built; installation on sage-mini was interrupted by loss of SSH reachability.
Do not submit until the updated backend is installed and taps, swipes, reconnect,
revocation, and a five-minute phone-lock test have been verified.

The three PNG screens are rendered previews using sample text, not hardware captures.
See ASSETS.md. The portal's About/category/tag were saved. Author profile,
icon, screen uploads, legal URLs, and build selection still need verification in the portal.
