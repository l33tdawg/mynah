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
const pageTemplate = `
<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1, viewport-fit=cover">
<title>Talk to Mynah</title>
<style>
  :root { color-scheme: light dark; --ink: #10121a; --dim: #6b7280; --line: #e5e7eb; --accent: #2f6bff; }
  @media (prefers-color-scheme: dark) {
    :root { --ink: #f4f5f7; --dim: #9aa1ab; --line: #2a2f3a; --accent: #6f9bff; }
    body { background: #0c0e14; }
  }
  * { box-sizing: border-box; }
  body {
    margin: 0; min-height: 100dvh; display: grid; place-items: center;
    font: 17px/1.5 -apple-system, BlinkMacSystemFont, "Segoe UI", system-ui, sans-serif;
    color: var(--ink); padding: max(24px, env(safe-area-inset-top)) 24px;
  }
  main { width: 100%; max-width: 26rem; text-align: center; }
  h1 { font-size: 1.5rem; margin: 0 0 .25rem; letter-spacing: -.02em; }
  p  { color: var(--dim); margin: 0 0 2rem; }
  button {
    font: inherit; font-weight: 600; color: #fff; background: var(--accent);
    border: 0; border-radius: 999px; padding: 1rem 2rem; cursor: pointer;
    /* 44pt is the smallest reliable touch target on iOS. */
    min-height: 56px; min-width: 12rem;
  }
  button[disabled] { opacity: .5; cursor: default; }
  button.hangup { background: #c0392b; }
  #state { margin-top: 1.25rem; color: var(--dim); min-height: 1.5em; }
  #trouble {
    margin-top: 1.25rem; padding: .875rem 1rem; border: 1px solid var(--line);
    border-radius: .75rem; text-align: left; color: var(--ink); display: none;
  }
  .level { height: 4px; background: var(--line); border-radius: 2px; margin-top: 1.5rem; overflow: hidden; }
  .level > i { display: block; height: 100%; width: 0; background: var(--accent); transition: width .1s linear; }
</style>
</head>
<body>
<main>
  <h1>Talk to Mynah</h1>
  <p>Speak normally. You can interrupt at any time.</p>
  <button id="call">Start talking</button>
  <div class="level"><i id="level"></i></div>
  <div id="state"></div>
  <div id="trouble"></div>
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
