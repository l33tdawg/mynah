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

Your personal Mac assistant, a glance away.

Mynah G2 connects Even G2 glasses to Mynah on a Mac you own. Install and set up the Mac app first; this companion is not a standalone assistant.

A home dashboard keeps the dot-matrix clock, date, glasses battery and optional local weather beside your messages. Clear selection borders and status icons make questions easy to browse.

Tap to speak, then tap to send. Each new ask has its own question-and-answer card. Queue up to five requests while Mynah works, browse recent answers, or follow up in the selected conversation. Your Mac processes requests in order. Answers also appear in your linked Signal or WhatsApp self-chat. The phone companion has a scrollable message window for full answer previews.

Ask about tasks, capture ideas, save notes or look things up. Actions and processing depend on the tools and local or cloud model configured in Mynah. There is no spoken playback on G2.

GET STARTED
1. Install Mynah 2.5.1 or later: https://github.com/l33tdawg/mynah
2. Keep your Mac online with phone answering enabled and Signal or WhatsApp self-chat linked.
3. Pair G2 with the Even app and install this companion.
4. In Mynah on your Mac, open Settings → General → Your phone → Pair G2. Paste the private pairing link into the phone companion.

Pair once and reconnect automatically. Recent cards survive companion reconnects while Mynah stays running; restarting the Mac daemon clears the in-memory queue. Completed self-chat replies remain available. Check chat before repeating an interrupted request.

Weather is optional and uses phone location. Permission help is available in the companion. Background behavior depends on the phone and Even app. Mynah cannot read other apps’ inboxes or reply to mirrored notifications.

Created by Dhillon Kannabhiran (l33tdawg).

## Release notes — 0.2.1

Wider, centered dot-matrix clock with tighter spacing between digits.
Requires Mynah 2.5.1 or later on your Mac.

## Release notes — 0.2.0

A dashboard with a dot-matrix clock, live battery icon, and optional local weather.
Queue separate questions, browse their answers, and follow up within the selected conversation.
Quiet waiting and improved pairing, reconnection, and microphone recovery.

## Release notes — 0.1.3

A home view with time and date beside a framed Mynah conversation card.
The waiting explanation appears once; the card goes quiet after 10 seconds and returns with the answer.
Improved pairing, reconnection, and microphone recovery.

## Release notes — 0.1.2

- Pair from Mynah's Mac settings and reconnect automatically.
- Forget and revoked pairings stay forgotten; interrupted recordings recover cleanly.
- Improved microphone shutdown and reopening after a connection interruption.

## Release notes — 0.1.1

- Pair once and reconnect automatically; pairing survives Mac restarts.
- G2 pairing is separate from temporary voice-call links.
- Handle glasses and R1 gestures delivered as system, text, or list events.
- Add About, author, support, project, privacy, and terms links.
- Add an input-status readout to help verify hardware controls.

## Review status

### Listing refresh — September 8, 2026

Saved the 0.2.0 dashboard/queue description (1829/2000 characters), including Mac Settings pairing and the 2.5.1 minimum. Replaced the old task-list screenshot with the two actual dashboard simulator captures and selected the dashboard as cover. The portal displays microphone, network and opt-in location permissions. Public review approval is still pending; selecting a build is not submission.

### Short portal release notes

Speak to Mynah and read answers on your G2 glasses, using your existing Mac assistant and self-chat.
Pair once and reconnect automatically, with updated glasses and ring controls.

### Submission check — September 5, 2026

- Latest beta check: the live Builds page now shows 0.1.1 as the active Beta
  and 0.1.0 under Private builds. Promotion dialog identified the existing
  one-person beta group. Verified the resulting status in both accessibility
  text and screenshot. The user is handling the Mac backend installation;
  physical validation and public review remain outstanding.

- Follow-up revision: the About copy above now explains Mynah itself, everyday
  uses, and Mac-first installation with four setup steps (1776/2000 characters).
  Verified saved on the refreshed portal. `simulator-tasks.png` was uploaded,
  selected and saved as the Home-background cover, replacing the first-run
  screenshot. The task data is illustrative; rendering is an actual simulator
  capture. Both the new cover and description were visually verified together.
  The refreshed portal shows Select build again; the earlier 0.1.1 selection
  did not persist. Select the tested build at submission time. No review was
  submitted. The observations below describe the earlier listing state.

- Live portal re-read: description, Productivity category, assistant tag and
  microphone/network permissions are present. All six listing checklist items
  are complete. The default question-mark icon was replaced with a monochrome
  Mynah bird drawn in the portal's 24×24 editor; the final tagline was saved.
- The public privacy and terms URLs both returned HTTP 200. The five companion
  tests passed. The local package manifest is 0.1.1.
- The user explicitly approved Dhillon Kannabhiran and dhillon@levelupctf.com
  as public developer details. The approved fields were entered; the portal
  now displays Dhillon Kannabhiran as developer and marks Personal Information
  complete. Privacy and terms is also complete and shows the portal-generated
  "Privacy Policy and Terms & Conditions.pdf". Reviewed the generated document
  and corrected AI Used to Yes, replaced the GitHub service reference with the
  hosted privacy policy and self-chat service policies, disclosed voice/text,
  pairing, connection metadata and configurable provider retention, and matched
  permissions to microphone and Internet access. Verified the regenerated PDF.
  The portal's fixed legal boilerplate remains generic (including AI described
  as summarization/rewriting); the linked hosted policy supplies app-specific
  details. This is a factual disclosure check, not legal approval.
- Version 0.1.1 (45.3 KB) was uploaded with the short changelog, saved as a
  Private build, and selected for the listing. Version 0.1.0 remains the beta.
  No public review submission was made.
- SSH to sage-mini still returned `No route to host` outside the sandbox.
  This does not establish whether the Mac or Mynah is offline.
- Actual simulator 0.9.3 framebuffer capture `simulator-first-run.png` was
  verified to show "MYNAH / Connect on your phone to begin." It is uploaded
  with the portal's Home backdrop as the cover. The three hand-rendered
  previews were not uploaded. Connected/answer screenshots remain desirable
  after pairing; this capture does not establish working hardware controls.
- Before public review: install 0.1.1 as a beta build; verify gestures,
  reconnect and revocation; run the five-minute locked-phone test; verify root
  double-tap shows the system exit dialog, closes the phone WebView, and permits
  launching Conversate without restarting the glasses.

Reference: https://hub.evenrealities.com/docs/ship/app-submission

The 0.1.0 voice-to-answer path was successfully tested by the owner on G2.
Both glasses and ring controls were reported unresponsive in that version.
The 0.1.1 input routing fix passes automated tests but still needs physical verification.
The 0.1.1 backend and companion are built; installation on sage-mini was interrupted by loss of SSH reachability.
Do not submit until the updated backend is installed and taps, swipes, reconnect,
revocation, and a five-minute phone-lock test have been verified.

See ASSETS.md for the distinction between the original sample previews and the
actual first-run simulator capture now used by the listing.
