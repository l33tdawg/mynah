// Package callpage holds the page a caller opens.
//
// It lives apart from either binary because both need it and neither owns it:
// the appliance serves it on a local call, the relay serves it on a remote one,
// and a copy in each is a copy that drifts. The page is the product surface —
// the only thing the owner ever sees of this system — so there is exactly one.
package callpage

import "strings"

// pageTemplate is the whole client: one link, one button, no install.
//
// The three getUserMedia constraints are the reason this is a browser page at
// all. Echo cancellation is what makes full duplex possible — without it the
// microphone hears the speaker and the assistant talks over itself the moment it
// starts. Getting that from a constraint rather than writing it is most of the
// argument for WebRTC over a hand-rolled audio socket.
//
// It explains itself because there is nowhere else to. A caller arrives from a
// line in a Signal thread with no manual behind it, and the three things worth
// knowing — that interrupting is allowed, that the phone is about to ask for a
// microphone, and that the audio is not going through anyone — are all things
// nobody discovers by tapping the button. They are kept to a line each: this is
// read for three seconds on the way to a call, not studied.
const pageTemplate = `
<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1, viewport-fit=cover">
<!-- The phone paints its own chrome around the page. Matching it is the
     difference between a call screen and a web page about a call. -->
<meta name="theme-color" content="#f7f7f9" media="(prefers-color-scheme: light)">
<meta name="theme-color" content="#0c0e14" media="(prefers-color-scheme: dark)">
<title>Talk to Mynah</title>
<style>
  :root {
    color-scheme: light dark;
    --bg: #f7f7f9; --surface: #fff;
    --ink: #10121a; --dim: #6b7280; --line: #e5e7eb; --accent: #2f6bff;
  }
  @media (prefers-color-scheme: dark) {
    :root {
      --bg: #0c0e14; --surface: #12151d;
      --ink: #f4f5f7; --dim: #9aa1ab; --line: #2a2f3a; --accent: #6f9bff;
    }
  }
  * { box-sizing: border-box; }
  body {
    margin: 0; min-height: 100dvh;
    background: var(--bg); color: var(--ink);
    font: 17px/1.5 -apple-system, BlinkMacSystemFont, "Segoe UI", system-ui, sans-serif;
    /* iOS otherwise inflates the text when the phone is turned sideways. */
    -webkit-text-size-adjust: 100%;
    /* The insets keep the button off the home indicator and off the curve of
       the glass; the floors keep it off the edge on everything without either. */
    padding: max(20px, env(safe-area-inset-top)) max(20px, env(safe-area-inset-right))
             max(20px, env(safe-area-inset-bottom)) max(20px, env(safe-area-inset-left));
    /* Centred by a spare track above and below rather than by place-items, so
       that content taller than a small phone simply scrolls instead of
       overflowing off the top where nobody can reach it. */
    display: grid; grid-template-rows: minmax(1rem, 1fr) auto minmax(1rem, 1fr); justify-items: center;
  }
  main { grid-row: 2; width: 100%; max-width: 24rem; }
  .hero { text-align: center; margin-bottom: 1.5rem; }
  .mark { color: var(--accent); display: block; margin: 0 auto .75rem; }
  h1 { font-size: 1.625rem; margin: 0; letter-spacing: -.02em; }
  p { margin: 0; }
  .lede { color: var(--dim); margin-top: .375rem; }

  button {
    font: inherit; font-weight: 600; color: #fff; background: var(--accent);
    border: 0; border-radius: 999px; padding: 1rem 1.5rem; cursor: pointer;
    /* 44pt is the smallest reliable touch target on iOS; full width because the
       thumb of the hand holding the phone is the least accurate part of it. */
    min-height: 56px; width: 100%;
    -webkit-tap-highlight-color: transparent; touch-action: manipulation;
    transition: transform .12s ease, background-color .2s ease;
  }
  button:active { transform: scale(.985); }
  button:focus-visible { outline: 2px solid var(--accent); outline-offset: 3px; }
  button[disabled] { opacity: .5; cursor: default; transform: none; }
  button.hangup { background: #c0392b; }
  /* Height is held whether or not there is anything to say, so that a status
     arriving does not shove the page under a thumb already on its way down. */
  #state { margin-top: .5rem; color: var(--dim); font-size: .9375rem; text-align: center; min-height: 1.5em; }
  .level {
    height: 5px; background: var(--line); border-radius: 999px; margin-top: .625rem; overflow: hidden;
    /* An idle meter is a piece of instrumentation on a page that should look
       like an appliance. It appears when there is something to measure. */
    opacity: 0; transition: opacity .25s ease;
  }
  body.live .level { opacity: 1; }
  .level > i { display: block; height: 100%; width: 0; background: var(--accent); transition: width .1s linear; }

  #trouble {
    margin-top: 1rem; padding: .875rem 1rem; background: var(--surface);
    border: 1px solid var(--line); border-left: 3px solid #c0392b;
    border-radius: .75rem; text-align: left; color: var(--ink);
    font-size: .9375rem; display: none;
    /* An error carries a browser error name, and a long one must wrap rather
       than push the page sideways. */
    overflow-wrap: break-word;
  }

  .notes { list-style: none; margin: 1.25rem 0 0; padding: 0; display: grid; gap: .875rem; }
  .notes li { display: grid; grid-template-columns: 1.25rem 1fr; gap: .75rem; align-items: start;
              color: var(--dim); font-size: .9375rem; line-height: 1.45; }
  .notes strong { color: var(--ink); font-weight: 600; }
  .notes svg { width: 1.25rem; height: 1.25rem; margin-top: .1rem; }

  details { margin-top: 1.25rem; border-top: 1px solid var(--line); }
  summary {
    /* Its own touch target, because it sits close to nothing else that is one. */
    display: flex; align-items: center; gap: .5rem; min-height: 44px;
    color: var(--dim); font-size: .9375rem; cursor: pointer; list-style: none;
  }
  summary::-webkit-details-marker { display: none; }
  summary svg { width: 1rem; height: 1rem; transition: transform .2s ease; }
  details[open] summary svg { transform: rotate(90deg); }
  details ul { margin: 0 0 1rem; padding-left: 1.125rem; color: var(--dim); font-size: .9375rem; }
  details li { margin-bottom: .5rem; }

  /* While the call is up, the attention belongs on it. */
  .notes, details { transition: opacity .3s ease; }
  body.live .notes, body.live details { opacity: .5; }

  @media (prefers-reduced-motion: reduce) {
    * { transition-duration: .01ms !important; }
    button:active { transform: none; }
  }
</style>
</head>
<body>
<main>
  <div class="hero">
    <svg class="mark" width="30" height="30" viewBox="0 0 24 24" fill="none" stroke="currentColor"
         stroke-width="1.6" stroke-linecap="round" aria-hidden="true">
      <circle cx="12" cy="12" r="9.25" stroke-opacity=".3"></circle>
      <path d="M8 10.25v3.5M12 7.5v9M16 10.25v3.5"></path>
    </svg>
    <h1>Talk to Mynah</h1>
    <p class="lede">A call with the agent on your Mac. It answers already knowing where things stand.</p>
  </div>

  <button id="call">Start talking</button>
  <div class="level" aria-hidden="true"><i id="level"></i></div>
  <div id="state" role="status" aria-live="polite"></div>

  <div id="trouble" role="alert"></div>

  <ul class="notes">
    <li>
      <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.6" stroke-linecap="round" aria-hidden="true">
        <path d="M5 10v4M9.5 7v10M14 9v6M18.5 11v2"></path>
      </svg>
      <span><strong>Just talk.</strong> Interrupt whenever you like — it stops to listen.</span>
    </li>
    <li>
      <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.6" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true">
        <path d="M12 4.5a2.5 2.5 0 0 1 2.5 2.5v4a2.5 2.5 0 0 1-5 0V7a2.5 2.5 0 0 1 2.5-2.5Z"></path>
        <path d="M6.5 11a5.5 5.5 0 0 0 11 0M12 16.5V20"></path>
      </svg>
      <span><strong>Your phone will ask for the microphone.</strong> It is open only while the call is.</span>
    </li>
    <li>
      <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.6" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true">
        <rect x="5" y="10.5" width="14" height="9" rx="2.5"></rect>
        <path d="M8.5 10.5V8a3.5 3.5 0 0 1 7 0v2.5"></path>
      </svg>
      <span><strong>Only your Mac can hear it.</strong> The audio is sealed end to end — straight there when the network allows, through a relay that cannot open it when it does not.</span>
    </li>
  </ul>

  <details>
    <summary>
      <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true">
        <path d="M9 6l6 6-6 6"></path>
      </svg>
      If the call will not connect
    </summary>
    <ul>
      <li>Wi-Fi first. On mobile data the call has to be relayed, which does not always work.</li>
      <li>The Mac has to be awake, with Mynah running on it.</li>
      <li>Only the newest link works, and an unused one closes after fifteen minutes. Text yourself //call again for another.</li>
    </ul>
  </details>
</main>
<script>
const callButton = document.getElementById('call');
const stateText  = document.getElementById('state');
const trouble    = document.getElementById('trouble');
const levelBar   = document.getElementById('level');

let peer = null;
let microphone = null;
let meter = null;

function say(text) { stateText.textContent = text; }

// Tell the Mac what this page sees.
//
// Every way a call fails is visible here and invisible there: a refused
// microphone, an ICE state that stalls at 'checking', a connection that reports
// itself healthy while sending nothing. Without this the owner is the only
// instrument, and "it doesn't connect" has to cover all of them.
//
// Fire-and-forget by design — a diagnostic that can break the call it is
// diagnosing is worse than no diagnostic.
function report(event, detail) {
  try {
    fetch('REPORT_PATH', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ event: event, detail: String(detail || '') }),
      keepalive: true
    }).catch(() => {});
  } catch (ignored) {}
}

function explain(html) {
  trouble.innerHTML = html;
  trouble.style.display = 'block';
}

// getUserMedia is refused outside a secure context, and the failure is silent
// unless someone says so: the button appears to work and no microphone ever
// starts. Checked before the click rather than after, because the browser's own
// error names none of this.
if (!window.isSecureContext) {
  callButton.disabled = true;
  explain('<strong>This page needs a secure connection.</strong><br>' +
          'Phones refuse microphone access over plain http. Open this over https, ' +
          'or from the Mac itself at localhost.');
}
if (!navigator.mediaDevices?.getUserMedia) {
  callButton.disabled = true;
  explain('<strong>This browser cannot open a microphone.</strong>');
}

async function startCall() {
  callButton.disabled = true;
  say('Asking for your microphone…');
  try {
    microphone = await navigator.mediaDevices.getUserMedia({
      audio: {
        // The reason this is a browser at all. Without echo cancellation the
        // microphone hears the speaker and Mynah interrupts itself the moment
        // it starts talking, which makes full duplex unusable.
        echoCancellation: true,
        noiseSuppression: true,
        autoGainControl: true
      },
      video: false
    });
  } catch (error) {
    callButton.disabled = false;
    say('');
    report('microphone-refused', error.name + ': ' + error.message);
    explain('<strong>No microphone.</strong><br>' +
            'Allow microphone access for this page and try again. (' + error.name + ')');
    return;
  }

  meterFrom(microphone);
  // From here the page is a call rather than an invitation to one: the meter has
  // something to show and the help around it steps back. Set on the microphone
  // rather than on 'connected' because connecting is when the reassurance that
  // something is happening is worth most.
  document.body.classList.add('live');
  say('Connecting…');

  peer = new RTCPeerConnection({
    // Handed down from the server so the owner's own TURN credentials are not
    // baked into a page.
    iceServers: ICE_SERVERS
  });

  microphone.getTracks().forEach(track => peer.addTrack(track, microphone));

  // Autoplay policies allow audio that follows a user gesture, which the button
  // provides. Attached to a hidden element rather than a visible player: this is
  // a call, not a media file.
  peer.ontrack = event => {
    const audio = new Audio();
    audio.srcObject = event.streams[0];
    audio.autoplay = true;
    audio.play().catch(() => say('Tap once more to let sound through.'));
  };

  // Reported rather than only shown. 'checking' that never advances and
  // 'connected' that carries nothing look identical to someone holding a phone.
  peer.oniceconnectionstatechange = () => report('ice', peer.iceConnectionState);

  // Which routes this phone offered as a way back to itself. On a browser that
  // will not persist permission for this origin these come back as random
  // '.local' names instead of addresses, which is the difference between being
  // on the same Wi-Fi and being reachable on it.
  peer.onicecandidate = event => {
    if (event.candidate && event.candidate.candidate) {
      const parts = event.candidate.candidate.split(' ');
      report('candidate', parts[7] + ' ' + parts[4]);
    }
  };

  peer.onconnectionstatechange = () => {
    report('state', peer.connectionState);
    switch (peer.connectionState) {
      case 'connected':
        say('Connected — go ahead.');
        // Whether this phone is actually sending. A microphone can be granted,
        // a track can be live, and the outbound packet count can still be zero.
        setTimeout(async () => {
          try {
            let sent = 'no outbound audio stat';
            (await peer.getStats()).forEach(stat => {
              if (stat.type === 'outbound-rtp' && stat.kind === 'audio') {
                sent = stat.packetsSent + ' packets, ' + stat.bytesSent + ' bytes';
              }
            });
            report('sending', sent);
          } catch (error) { report('sending', 'stats failed: ' + error.message); }
        }, 3000);
        callButton.disabled = false;
        callButton.textContent = 'Hang up';
        callButton.classList.add('hangup');
        break;
      case 'failed':
        say('');
        explain('<strong>Could not connect.</strong><br>' +
                'This usually means the network needs a relay. If you are on ' +
                'mobile data, try Wi-Fi — or configure a TURN server.');
        endCall();
        break;
      case 'disconnected':
      case 'closed':
        endCall();
        break;
    }
  };

  try {
    const offer = await peer.createOffer();
    await peer.setLocalDescription(offer);
    // Waiting for gathering to finish means every candidate travels in the SDP,
    // so there is no second channel to drop a message on.
    await new Promise(resolve => {
      if (peer.iceGatheringState === 'complete') return resolve();
      const check = () => {
        if (peer.iceGatheringState === 'complete') {
          peer.removeEventListener('icegatheringstatechange', check);
          resolve();
        }
      };
      peer.addEventListener('icegatheringstatechange', check);
      setTimeout(resolve, 5000);
    });

    const response = await fetch('OFFER_PATH', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ sdp: peer.localDescription.sdp })
    });
    if (!response.ok) throw new Error('the Mac refused the call');
    const answer = await response.json();
    await peer.setRemoteDescription({ type: 'answer', sdp: answer.sdp });
  } catch (error) {
    say('');
    explain('<strong>Could not reach Mynah.</strong><br>' + error.message);
    endCall();
  }
}

function endCall() {
  if (peer) { peer.close(); peer = null; }
  if (microphone) { microphone.getTracks().forEach(t => t.stop()); microphone = null; }
  if (meter) { cancelAnimationFrame(meter); meter = null; }
  document.body.classList.remove('live');
  levelBar.style.width = '0';
  callButton.disabled = false;
  callButton.textContent = 'Start talking';
  callButton.classList.remove('hangup');
  if (!trouble.style.display || trouble.style.display === 'none') say('');
}

// Something that moves while the owner speaks. A call with no feedback at all
// looks broken in exactly the way silence does in the Signal thread.
function meterFrom(stream) {
  const context = new (window.AudioContext || window.webkitAudioContext)();
  const analyser = context.createAnalyser();
  analyser.fftSize = 512;
  context.createMediaStreamSource(stream).connect(analyser);
  const samples = new Uint8Array(analyser.frequencyBinCount);
  const tick = () => {
    analyser.getByteTimeDomainData(samples);
    let peak = 0;
    for (const sample of samples) peak = Math.max(peak, Math.abs(sample - 128));
    levelBar.style.width = Math.min(100, (peak / 40) * 100) + '%';
    meter = requestAnimationFrame(tick);
  };
  tick();
}

callButton.addEventListener('click', () => (peer ? endCall() : startCall()));
</script>
</body>
</html>
`

// Render fills in the three values that differ per call.
//
// Substitution rather than html/template: the page is a constant this repository
// controls, the values are a JSON array and two paths built from a hex token,
// and a template engine here would add escaping semantics to reason about
// without removing any.
func Render(iceServersJSON, offerPath, reportPath string) string {
	page := strings.TrimSpace(pageTemplate)
	page = strings.Replace(page, "ICE_SERVERS", iceServersJSON, 1)
	page = strings.Replace(page, "OFFER_PATH", offerPath, 1)
	page = strings.Replace(page, "REPORT_PATH", reportPath, 1)
	return page
}
