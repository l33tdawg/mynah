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
    <!-- Mynah's own icon, inlined.
         The page is served under a policy that permits no external fetches at
         all, and must render on a phone with no internet beyond the call
         itself, so the alternative to a data URI is no mark. Embedded at 128px
         and drawn at 44: retina phones are the only device this is opened on. -->
    <img class="mark" width="44" height="44" alt=""
         src="data:image/png;base64,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">
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
