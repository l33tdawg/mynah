import {
  AudioInputSource, AppLocationAccuracy, CreateStartUpPageContainer, OsEventTypeList,
  StartUpPageCreateResult, TextContainerProperty, TextContainerUpgrade, RebuildPageContainer, ImageContainerProperty, ImageRawDataUpdate, ImageRawDataUpdateResult,
  waitForEvenAppBridge, type EvenAppBridge
} from '@evenrealities/even_hub_sdk';
import { MynahConnection } from './connection.ts';
import { connectionURL, cardPages, type ReplyEvent } from './protocol.ts';
import { clockPixels, batteryLabel, weatherLabel, statusPixels, batteryPixels, weatherPixels, titlePixels } from './home.ts';
import { Cards, cardIcon } from './cards.ts';
import { inputType } from './input.ts';

const el = <T extends HTMLElement>(id: string) => document.getElementById(id) as T;
const talk = el<HTMLButtonElement>('talk');
const connect = el<HTMLButtonElement>('connect');
const disconnect = el<HTMLButtonElement>('disconnect');
const previous = el<HTMLButtonElement>('previous');
const next = el<HTMLButtonElement>('next');
let bridge: EvenAppBridge | undefined;
let connection: MynahConnection | undefined;
const cards = new Cards();
let queueEnabled = false;
let requestID: string | undefined;
let parentID: string | undefined;
let phase: 'offline' | 'connecting' | 'ready' | 'listening' | 'thinking' = 'offline';
let answer = '';
let reading = ['Connect on your phone to begin.'];
let page = 0;
let recorded = 0;
let recordingTimer: ReturnType<typeof setTimeout> | undefined;
let operation = Promise.resolve();
let desiredDisplay = '';
let drawing = false;
let desiredClock = '';
let desiredWeather = '--°C';
let sentWeather = '';
let iconKinds: string[] = [];
let iconFocus = -1;
let sentIconKey = '';
let desiredPixels: number[] = [];
let sentClockMinute = '';
let clockMinute = '';
let battery = '[--]';
let batteryLevel: number | undefined;
let glassesSN: string | undefined;
let weatherCode: number | undefined;
let sentIndicators = '';
let weatherTimer: ReturnType<typeof setTimeout> | undefined;
let weatherRevision = 0;
let weatherEnabled = false;
let sentLayoutKey = '';
let sentTitle = false;
let sentRows: string[] = [];
let clockTimer: ReturnType<typeof setTimeout> | undefined;
let sentClock = '';
let sentDisplay = '';
function updateClock() {
  clearTimeout(clockTimer);
  if (exiting) return;
  const now = new Date();
  const day = `${now.toLocaleDateString([], { weekday: 'short' })} ${now.getDate()}/${now.getMonth()+1}`;
  clockMinute = `${now.getHours().toString().padStart(2,'0')}:${now.getMinutes().toString().padStart(2,'0')}`;
  desiredPixels = clockPixels(now);
  const context = el<HTMLCanvasElement>('clock-led').getContext?.('2d');
  if (context) {
    const image = context.createImageData(156, 144);
    for (let i=0;i<156*144;i++) {
      const on = (desiredPixels[i >> 1] >> (i % 2 ? 0 : 4)) & 15;
      image.data.set([184,238,145,on ? 255 : 0], i*4);
    }
    context.putImageData(image,0,0);
  }
  desiredClock = day;
  el('clock').textContent = clockMinute.replace(':', '\n');
  el('home-date').textContent = day;
  el('home-battery').textContent = battery;
  el('home-weather').textContent = desiredWeather;
  paintIndicator('title-led',144,24,titlePixels());
  paintIndicator('battery-led',28,20,batteryPixels(batteryLevel));
  paintIndicator('weather-led',24,24,weatherPixels(weatherCode));
  void draw();
  clockTimer = setTimeout(updateClock, 60000 - now.getSeconds() * 1000 - now.getMilliseconds());
}
let turnError = false;
let savedPairing: string | undefined;
let reconnectTimer: ReturnType<typeof setTimeout> | undefined;
let reconnectAttempt = 0;
let exiting = false;
let pairingRevision = 0;
let waitingHintSeen = false;
let waitingTimer: ReturnType<typeof setTimeout> | undefined;
let waitingHidden = false;
let waitingActive = false;
function stopWaitingDisplay() {
  clearTimeout(waitingTimer); waitingTimer = undefined; waitingHidden = false; waitingActive = false;
  el('display').classList.remove('waiting-quiet');
}
function showWaiting() {
  const alreadyWaiting = phase === 'thinking' && (waitingTimer !== undefined || waitingHidden);
  phase = 'thinking'; status('Working…');
  if (alreadyWaiting) return;
  waitingActive = true;
  if (!waitingHintSeen) {
    waitingHintSeen = true;
    void bridge?.setLocalStorage('mynah.waitingHintSeen', '1').catch(() => {});
    show('You can carry on.\nThe answer will appear here and in your notes-to-self chat.');
  } else { show('Working…'); }
  waitingTimer = setTimeout(() => {
    waitingTimer = undefined;
    if (phase !== 'thinking') return;
    waitingHidden = true;
    el('display').classList.add('waiting-quiet');
    render();
  }, 10000);
}
let storageWrites = Promise.resolve();
function savePairing(link: string) {
  // Serialize writes so a delayed save cannot overwrite a later Forget.
  storageWrites = storageWrites.catch(() => {}).then(async () => {
    await bridge?.setLocalStorage('mynah.connection', link);
  });
  return storageWrites;
}
function forgetPairing(reason: string) {
  pairingRevision++;
  cards.items = []; cards.home(); queueEnabled = false;
  savedPairing = undefined; clearTimeout(reconnectTimer); reconnectAttempt = 0;
  connection?.close(); connection = undefined; phase = 'offline';
  void stopMicrophone();
  stopWaitingDisplay();
  answer = ''; turnError = false; el('heard').textContent = '';
  el<HTMLInputElement>('link').value = '';
  void savePairing('').catch(() => status('Could not clear the saved link. Unpair in Mynah settings to revoke access.'));
  status(reason); show('Pair on your phone to begin.');
}

function status(text: string) { el('status').textContent = text; }
function controls() {
  talk.disabled = !bridge || !(['ready','listening'].includes(phase) || queueEnabled && phase === 'thinking') || queueEnabled && phase !== 'listening' && cards.pending >= 5;
  talk.textContent = phase === 'listening' ? 'Tap to send' : phase === 'thinking' && !queueEnabled ? 'Thinking…' : 'Tap to talk';
  disconnect.disabled = !savedPairing;
  el('connect-form').hidden = !!savedPairing;
  connect.disabled = !bridge || phase !== 'offline';
  previous.disabled = queueEnabled && !cards.detail ? cards.selected === -1 : page === 0;
  next.disabled = queueEnabled && !cards.detail ? cards.selected >= cards.items.length - 1 : page >= reading.length - 1;
  el<HTMLButtonElement>('follow-up').disabled = !queueEnabled || cards.current?.status !== 'ready' || phase === 'listening' || !connection;
  el('queue-count').textContent = queueEnabled ? `${cards.pending} queued / working · ${cards.items.filter(c => c.unread).length} unread` : '';
}
function show(text: string) {
  reading = cardPages(text); page = 0; render();
}
function render() {
  iconKinds = []; iconFocus = -1;
  if (queueEnabled && !['listening','offline','connecting'].includes(phase) && !waitingActive && !waitingHidden) {
    if (cards.detail && cards.current) {
      const c = cards.current;
      reading = cardPages(`? ${c.question}\n\n${c.status === 'ready' ? '✓ ' + c.answer : cardIcon(c) + ' ' + c.status + (c.status === 'failed' ? '\n'+c.answer : '')}`);
      page = Math.min(page, reading.length - 1);
    } else {
      const first = Math.max(0, cards.selected - 1);
      iconFocus = cards.selected === -1 ? 0 : cards.selected - first + 1;
      iconKinds = ['new', ...cards.items.slice(first, first + 2).map(c => c.status)];
      reading = [`${cards.selected === -1 ? '›' : ' '}      New ask\n` + cards.items.slice(first, first + 2).map((c, i) => `${cards.selected === first + i ? '›' : ' '}      ${c.question.slice(0,22)}\n       ${c.unread ? '● ' : ''}${c.status}`).join('\n')];
      page = 0;
    }
  }
  // Only the card goes quiet; the home clock remains visible.
  const cardText = `\n\n${reading[page]}${reading.length > 1 ? `\n${page + 1} / ${reading.length}` : ''}`;
  desiredDisplay = waitingHidden || iconKinds.length ? ' ' : cardText;
  // Keep the old phone text through its CSS fade; glasses clear immediately.
  if (!waitingHidden) {
    const phoneDisplay = iconKinds.length
      ? [`${cards.selected === -1 ? '›' : ' '} + New ask`, ...cards.items.map((c,i) => `${cards.selected === i ? '›' : ' '} ${{queued:'◷',working:'◌',ready:'✓',failed:'!'}[c.status]} ${c.question}\n    ${c.unread ? '● ' : ''}${c.status}`)].join('\n\n')
      : reading.join('\n');
    const display = el('display');
    if (display.textContent !== phoneDisplay) display.textContent = phoneDisplay;
    el<HTMLButtonElement>('open-message').disabled = !iconKinds.length || cards.selected < 0;

  }
  controls();
  void draw();
}
async function draw() {
  if (!bridge || drawing || exiting) return;
  drawing = true;
  try {
    do {
      const layout = layoutKey();
      if (sentLayoutKey !== layout) {
        if (!await bridge.rebuildPageContainer(new RebuildPageContainer(pageLayout()))) throw Error('Could not move the selection on the glasses.');
        sentLayoutKey = layout; sentTitle = false; sentRows = []; sentIconKey = ''; sentClockMinute = ''; sentIndicators = '';
      }
      if (!sentTitle) { await bridge.updateImageRawData(new ImageRawDataUpdate({containerID:8,containerName:'title',imageData:titlePixels()})); sentTitle = true; }
      const rowText = homeRows();
      for (let i=0;i<4;i++) if (sentRows[i] !== rowText[i]) {
        const id = i === 0 ? 12 : 8+i;
        await bridge.textContainerUpgrade(new TextContainerUpgrade({containerID:id,containerName:`row-${id}`,contentOffset:0,contentLength:0,content:rowText[i]}));
        sentRows[i] = rowText[i];
      }
      const clock = desiredClock, card = desiredDisplay;
      for (const [containerID, containerName, content, previous] of [
        [2, 'clock', clock, sentClock], [3, 'weather', desiredWeather, sentWeather], [1, 'mynah', card, sentDisplay]
      ] as const) {
        if (content === previous) continue;
        const ok = await bridge.textContainerUpgrade(new TextContainerUpgrade({
          containerID, containerName, contentOffset: 0,
          contentLength: 0, content
        }));
        if (!ok) throw new Error('Could not update the glasses. Check their connection.');
        if (containerID === 2) sentClock = content; else if (containerID === 3) sentWeather = content; else sentDisplay = content;
      }
      const indicators = JSON.stringify([batteryLevel, weatherCode]);
      if (sentIndicators !== indicators) {
        await bridge.updateImageRawData(new ImageRawDataUpdate({containerID:6,containerName:'battery',imageData:batteryPixels(batteryLevel)}));
        await bridge.updateImageRawData(new ImageRawDataUpdate({containerID:7,containerName:'weather-icon',imageData:weatherPixels(weatherCode)}));
        sentIndicators = indicators;
      }
      const iconKey = JSON.stringify([iconKinds,iconFocus]);
      if (sentIconKey !== iconKey) {
        await bridge.updateImageRawData(new ImageRawDataUpdate({containerID:5,containerName:'icons',imageData:statusPixels(iconKinds.slice(1,2), -1, 20)}));
        await bridge.updateImageRawData(new ImageRawDataUpdate({containerID:13,containerName:'icon-second',imageData:statusPixels(iconKinds.slice(2,3), -1, 20)}));
        sentIconKey = iconKey;
      }
      if (sentClockMinute !== clockMinute) {
        const minute = clockMinute;
        const result = await bridge.updateImageRawData(new ImageRawDataUpdate({containerID:4,containerName:'digits',imageData:desiredPixels}));
        if (result !== ImageRawDataUpdateResult.success) {
          // Keep a truthful text clock if the host cannot update the bitmap.
          await bridge.textContainerUpgrade(new TextContainerUpgrade({containerID:2,containerName:'clock',contentOffset:0,contentLength:0,content:desiredClock+'\n'+minute}));
        }
        sentClockMinute = minute;
      }
    } while (sentClock !== desiredClock || sentDisplay !== desiredDisplay || sentWeather !== desiredWeather || sentClockMinute !== clockMinute || sentLayoutKey !== layoutKey() || sentRows.join('\n') !== homeRows().join('\n') || sentIconKey !== JSON.stringify([iconKinds,iconFocus]) || sentIndicators !== JSON.stringify([batteryLevel,weatherCode]));
  } catch (error) { status(message(error)); }
  finally { drawing = false; }
}
function message(error: unknown) { return error instanceof Error ? error.message : 'Something went wrong. Try again.'; }
function queue(action: () => Promise<void>) {
  operation = operation.then(action).catch(async error => {
    await stopMicrophone();
    try { connection?.control('cancel'); } catch { /* disconnected */ }
    if (phase === 'listening') phase = 'ready';
    status(message(error)); show(message(error)); controls();
  });
}
async function stopMicrophone() {
  clearTimeout(recordingTimer);
  // Change the phase before awaiting the bridge, so late audio is discarded.
  if (phase === 'listening') phase = 'ready';
  try {
    if (bridge && !await bridge.audioControl(false)) status('Check the glasses connection; microphone stop could not be confirmed.');
  } catch { status('Check the glasses connection; microphone stop could not be confirmed.'); }
}
function receive(event: ReplyEvent) {
  switch (event.type) {
    case 'ready': reconnectAttempt = 0; status('Connected · checking for an answer…'); break;
    case 'thinking': showWaiting(); break;
    case 'heard': el('heard').textContent = `You: ${event.text}`; break;
    case 'reply':
      if (answer.length + event.text.length > 100000) { connection?.close(); return; }
      answer += event.text; break;
    case 'error':
      turnError = true; stopWaitingDisplay();
      void stopMicrophone();
      status(event.text); show(event.text); break;
    case 'done':
      stopWaitingDisplay();
      phase = 'ready';
      if (!turnError) { status('Answer ready · tap to ask a follow-up'); show(answer || 'No answer received. Tap to try again.'); }
      break;
    case 'state': {
      const snapshot = JSON.parse(event.text);
      if (snapshot.queueVersion === 1 && snapshot.status !== 'unpaired') {
        queueEnabled = true;
        const speaking = phase === 'listening';
        cards.merge(snapshot.cards, speaking);
        if (!speaking) {
          if (cards.detail && cards.current?.status === 'ready') stopWaitingDisplay();
          if (phase !== 'thinking' || cards.pending === 0) { phase = 'ready'; stopWaitingDisplay(); }
          render();
        }
        controls(); return;
      }
      if (typeof snapshot.rejected === 'string') {
        const card = cards.items.find(c => c.id === snapshot.rejected);
        if (card) { card.status = 'failed'; card.answer = snapshot.reason || 'Request rejected'; }
        if (phase !== 'listening') { phase = 'ready'; stopWaitingDisplay(); status(snapshot.reason); render(); }
        return;
      }
      let state: { status?: string; text?: string };
      try { state = JSON.parse(event.text); } catch { break; }
      if (state.status === 'unpaired') {
        forgetPairing('G2 access was revoked. Create a new pairing in Mynah settings.');
        break;
      }
      if (phase === 'listening') break;
      if (state.status === 'working') {
        showWaiting();
      } else if (state.status === 'ready') {
        stopWaitingDisplay();
        phase = 'ready';
        if (state.text && state.text !== answer) {
          answer = state.text; status('Answer ready'); show(answer);
        } else if (!answer && !turnError) { status('Connected to Mynah'); show('Tap to talk.'); }
        else render();
      }
      break;
    }
  }
  controls();
}
async function toggleRecording() {
  if (!bridge || !connection || exiting) return;
  const current = connection;
  if (queueEnabled && phase !== 'listening' && cards.pending >= 5) { status('Queue full · wait for an answer'); return; }
  if (phase === 'listening') {
    phase = 'thinking';
    await stopMicrophone();
    if (connection !== current || exiting) return;
    if (recorded < 12800) {
      current.control('cancel'); phase = 'ready'; status('Recording too short · tap to try again'); show('I need a little more audio. Tap and try again.'); return;
    }
    phase = 'ready';
    if (queueEnabled && requestID) cards.add(requestID, parentID);
    current.control('stop'); phase = 'thinking'; status('Sending your question…');
    if (queueEnabled) { showWaiting(); cards.reveal(); if (cards.detail && cards.current?.status === 'ready') { stopWaitingDisplay(); phase = 'ready'; render(); } } else show('Sending your question…');
  } else if (phase === 'ready' || queueEnabled && phase === 'thinking') {
    stopWaitingDisplay();
    answer = ''; turnError = false; recorded = 0;
    el('heard').textContent = '';
    if (queueEnabled) { requestID = 'g2-' + crypto.randomUUID(); connection.startRequest(requestID, parentID); }
    else connection.control('start');
    phase = 'listening'; controls();
    if (!await bridge.audioControl(true, AudioInputSource.Glasses)) { showPermissionHelp('Microphone unavailable. Review Mynah permissions in Even Hub, then check microphone access below.'); throw new Error('Microphone unavailable. Open Permissions & help on your phone.'); }
    // A disconnect or background event may have happened during audioControl.
    if (phase !== 'listening') { await stopMicrophone(); return; }
    status('Listening · tap again to send'); show('Listening…\nTap again to send.');
    recordingTimer = setTimeout(() => queue(async () => { if (phase === 'listening') await toggleRecording(); }), 59000);
  }
  controls();
}

function scheduleReconnect() {
  clearTimeout(reconnectTimer);
  if (!savedPairing || exiting) return;
  const delay = Math.min(30000, 1000 * 2 ** Math.min(reconnectAttempt++, 5));
  reconnectTimer = setTimeout(() => queue(connectPaired), delay);
}
async function connectPaired() {
    if (!savedPairing || exiting) return;
    if (!bridge || phase !== 'offline') return;
    phase = 'connecting'; status('Connecting to Mynah…'); controls();
    const current = new MynahConnection(event => { if (connection === current && !exiting) receive(event); }, () => {
      if (connection !== current) return;
      stopWaitingDisplay();
      phase = 'offline'; connection = undefined; queueEnabled = false; cards.disconnected();
      void stopMicrophone();
      status(savedPairing ? 'Mynah is offline · reconnecting automatically' : 'Pair your Mynah to begin.');
      show(savedPairing ? 'Reconnecting to Mynah…\nYour submitted question stays on your Mac.' : 'Pair on your phone to begin.');
      scheduleReconnect();
    });
    connection = current;
    try {
      const link = savedPairing;
      await current.connect(link);
    }
    catch (error) {
      if (connection === current) { current.close(); status(message(error)); }
    }
}
el<HTMLFormElement>('connect-form').addEventListener('submit', event => {
  event.preventDefault();
  queue(async () => {
    pairingRevision++;
    savedPairing = connectionURL(el<HTMLInputElement>('link').value).toString();
    // Persist the owner's explicit pairing even if the Mac is temporarily offline.
    await savePairing(savedPairing);
    await connectPaired();
  });
});
talk.onclick = () => { if (phase !== 'listening') parentID = undefined; queue(toggleRecording); };
el('open-message').onclick = () => { if (phase === 'listening' || cards.selected < 0) return; cards.open(); stopWaitingDisplay(); render(); };
el('home').onclick = () => { if (phase === 'listening') return; cards.home(); stopWaitingDisplay(); render(); };
el('follow-up').onclick = () => { if (cards.current?.status !== 'ready' || phase === 'listening') return; parentID = cards.current.id; queue(toggleRecording); };
disconnect.onclick = () => forgetPairing('Pairing forgotten on this phone. Choose Unpair under Even G2 glasses in Mynah Settings on your Mac to revoke access.');
previous.onclick = () => { if (queueEnabled && !cards.detail) { cards.select(-1); stopWaitingDisplay(); render(); return; } page = Math.max(0, page - 1); render(); };
next.onclick = () => { if (queueEnabled && !cards.detail) { cards.select(1); stopWaitingDisplay(); render(); return; } page = Math.min(reading.length - 1, page + 1); render(); };
// A hidden WebView is normal when the paired phone is locked. Do not gate
// glasses input on document.visibilityState. Page teardown still stops capture.
window.addEventListener('pagehide', () => { exiting = true; clearTimeout(reconnectTimer); clearTimeout(clockTimer); clearTimeout(weatherTimer); void stopMicrophone(); connection?.close(); });
window.addEventListener('pageshow', event => {
  if (event.persisted) { exiting = false; updateClock(); if (weatherEnabled) void refreshWeather(); queue(connectPaired); }
});
window.addEventListener('online', () => { if (savedPairing && phase === 'offline') { clearTimeout(reconnectTimer); queue(connectPaired); } });

controls(); render(); updateClock();
const bridgeTimer = setTimeout(() => status('Open this companion inside Even Hub to connect your G2. This browser shows the display preview only.'), 8000);
void (async () => {
  const available = await waitForEvenAppBridge();
  const result = await available.createStartUpPageContainer(new CreateStartUpPageContainer(pageLayout()));
  if (result !== StartUpPageCreateResult.success) throw new Error('Could not open the glasses display. Reopen the companion in Even Hub.');
  bridge = available; sentLayoutKey = layoutKey();
  void bridge.getDeviceInfo().then(info => { glassesSN = info?.sn; batteryLevel = info?.status.batteryLevel; battery = batteryLabel(batteryLevel, info?.status.isCharging); updateClock(); }).catch(() => {});
  bridge.onDeviceStatusChanged(device => { if (!glassesSN || device.sn !== glassesSN) return; batteryLevel = device.batteryLevel; battery = batteryLabel(batteryLevel, device.isCharging); updateClock(); });
  void draw();
  clearTimeout(bridgeTimer);
  bridge.onEvenHubEvent(event => {
    if (event.sysEvent?.eventType === OsEventTypeList.SYSTEM_EXIT_EVENT || event.sysEvent?.eventType === OsEventTypeList.ABNORMAL_EXIT_EVENT) {
      exiting = true; clearTimeout(reconnectTimer); clearTimeout(clockTimer);
      void stopMicrophone(); connection?.close(); return;
    }
    if (event.audioEvent && phase === 'listening') {
      const audio = event.audioEvent;
      if (audio.source !== undefined && audio.source !== AudioInputSource.Glasses) return;
      try {
        const pcm = audio.audioPcm;
        if (recorded + pcm.byteLength > 60 * 32000) {
          queue(async () => { if (phase === 'listening') await toggleRecording(); }); return;
        }
        connection?.audio(pcm); recorded += pcm.byteLength;
      } catch (error) {
        phase = 'ready';
        try { connection?.control('cancel'); } catch { /* disconnected */ }
        void stopMicrophone(); status(message(error)); show(message(error));
      }
    }
    const input = inputType(event);
    if (input === undefined) return;
    if (input <= OsEventTypeList.DOUBLE_CLICK_EVENT) {
      el('input-status').textContent = `Last glasses / ring input: ${['tap', 'swipe up', 'swipe down', 'double tap'][input]}`;
    }
    switch (input) {
      case OsEventTypeList.CLICK_EVENT:
        if (queueEnabled && phase !== 'listening' && cards.current) {
          if (!cards.detail) { cards.open(); stopWaitingDisplay(); render(); }
          else if (cards.current.status === 'ready') { parentID = cards.current.id; queue(toggleRecording); }
        } else { if (phase !== 'listening') parentID = undefined; queue(toggleRecording); }
        break;
      case OsEventTypeList.DOUBLE_CLICK_EVENT:
        if (queueEnabled && cards.detail && phase !== 'listening') { cards.home(); stopWaitingDisplay(); render(); break; }
        queue(async () => {
          const wasRecording = phase === 'listening';
          await stopMicrophone();
          if (wasRecording) { connection?.control('cancel'); show('Recording cancelled. Tap to talk.'); }
          await bridge?.shutDownPageContainer(1);
        });
        break;
      case OsEventTypeList.SCROLL_TOP_EVENT: previous.click(); break;
      case OsEventTypeList.SCROLL_BOTTOM_EVENT: next.click(); break;
    }
  });
  status('Paste your Mynah connection link to begin.'); controls();
  weatherEnabled = await bridge.getLocalStorage('mynah.weatherEnabled').catch(() => '') === '1';
  if (weatherEnabled) void refreshWeather();
  waitingHintSeen = await bridge.getLocalStorage('mynah.waitingHintSeen').catch(() => '') === '1';
  const revision = pairingRevision;
  const saved = await bridge.getLocalStorage('mynah.connection');
  if (saved && revision === pairingRevision && !exiting) {
    try {
      el<HTMLInputElement>('link').value = connectionURL(saved).toString();
      savedPairing = connectionURL(saved).toString();
      await connectPaired();
    } catch { await savePairing(''); }
  }
})().catch(error => { clearTimeout(bridgeTimer); status(message(error)); });

async function refreshWeather() {
  clearTimeout(weatherTimer);
  const revision = weatherRevision;
  if (!weatherEnabled || !bridge || exiting) return;
  try {
    const location = await bridge.getAppLocation({accuracy:AppLocationAccuracy.Low,timeoutMs:12000});
    if (revision !== weatherRevision || exiting) return;
    if (!location || !Number.isFinite(location.latitude) || !Number.isFinite(location.longitude)) { showPermissionHelp('Location unavailable. Allow location for Even in phone settings, then enable local weather again.'); throw Error('Location permission needed. Open Permissions & help below.'); }
    // Weather needs the surrounding area, not a precise device position.
    const latitude = Math.round(location.latitude*100)/100, longitude = Math.round(location.longitude*100)/100;
    const response = await fetch(`https://api.open-meteo.com/v1/forecast?latitude=${latitude}&longitude=${longitude}&current=temperature_2m,weather_code`, {signal:AbortSignal.timeout(12000),credentials:'omit',referrerPolicy:'no-referrer'});
    if (!response.ok) throw Error('Weather unavailable. Retrying in 15 minutes.');
    const data = await response.json();
    if (!Number.isFinite(data.current?.temperature_2m) || !Number.isFinite(data.current?.weather_code)) throw Error('Weather unavailable.');
    if (revision !== weatherRevision || exiting) return;
    weatherCode = data.current.weather_code; desiredWeather = `${Math.round(data.current.temperature_2m)}°C`;
    el('weather-status').textContent = `Current location · updated ${new Date().toLocaleTimeString([], {hour:'2-digit',minute:'2-digit'})}`;
  } catch (error) {
    if (revision !== weatherRevision || exiting) return;
    desiredWeather = '--°C'; weatherCode = undefined;
    el('weather-status').textContent = message(error);
  }
  updateClock();
  weatherTimer = setTimeout(() => void refreshWeather(), 15 * 60000);
}
el('weather-enable').onclick = () => {
  if (!bridge) { el('weather-status').textContent = 'Open Mynah inside Even Hub to use the phone location.'; return; }
  weatherRevision++; weatherEnabled = true;
  void bridge.setLocalStorage('mynah.weatherEnabled','1').catch(() => {});
  void refreshWeather();
};
el('weather-off').onclick = () => {
  weatherRevision++; weatherEnabled = false; clearTimeout(weatherTimer); desiredWeather = '--°C'; weatherCode = undefined;
  el('weather-status').textContent = 'Weather disabled.';
  void bridge?.setLocalStorage('mynah.weatherEnabled','').catch(() => {}); updateClock();
};
function paintIndicator(id: string, width: number, height: number, pixels: number[]) {
  const context = el<HTMLCanvasElement>(id).getContext?.('2d');
  if (!context) return;
  const image = context.createImageData(width,height);
  for(let i=0;i<width*height;i++) image.data.set([184,238,145,((pixels[i>>1]>>(i%2?0:4))&15)?255:0],i*4);
  context.putImageData(image,0,0);
}

function showPermissionHelp(text: string) {
  el<HTMLDetailsElement>('permissions').open = true;
  el('permission-status').textContent = text;
}
el('check-microphone').onclick = () => queue(async () => {
  if (!bridge || phase === 'listening') return;
  let allowed = false;
  try { allowed = await bridge.audioControl(true, AudioInputSource.Glasses); }
  finally { await bridge.audioControl(false); }
  showPermissionHelp(allowed ? 'Microphone access is ready. Tap to talk when connected.' : 'Microphone access is still unavailable. Review the permissions in Even, then retry.');
});

function layoutKey() { return iconKinds.length ? `home:${cards.selected}:${iconKinds.length}` : 'reading'; }
function homeRows(): string[] {
  if (!iconKinds.length) return [' ',' ',' '];
  const first = Math.max(0,cards.selected-1);
  return ['   + New ask', ...[0,1].map(i => {
    const c=cards.items[first+i];
    return c ? `       ${c.question.slice(0,22)}\n       ${c.unread ? '* ' : ''}${c.status}` : ' ';
  })];
}
function pageLayout() { return {
    containerTotalNum: 12,
    textObject: [new TextContainerProperty({
      containerID: 1, containerName: 'mynah', xPosition: 176, yPosition: 12,
      width: 392, height: 264, paddingLength: 12, borderWidth: 1, borderColor: 4, borderRadius: 8, isEventCapture: 1,
      content: desiredDisplay
    }), new TextContainerProperty({
      containerID: 2, containerName: 'clock', xPosition: 8, yPosition: 8,
      width: 120, height: 68, paddingLength: 8, isEventCapture: 0,
      content: desiredClock
    }), new TextContainerProperty({
      containerID: 3, containerName: 'weather', xPosition: 108, yPosition: 232, width:60, height:48, paddingLength: 8, isEventCapture:0, content:desiredWeather
    }), ...[40,90,180].map((y,i) => {
      const id=i===0?12:8+i, visible=iconKinds.length > 0 && (i===0 || !!cards.items[Math.max(0,cards.selected-1)+i-1]);
      return new TextContainerProperty({containerID:id,containerName:`row-${id}`,xPosition:188,yPosition:y,width:368,height:i===0?46:80,paddingLength:i===0?6:8,isEventCapture:0,borderWidth:visible?(iconFocus===i?2:1):0,borderColor:iconFocus===i?4:1,borderRadius:4,textColor:iconFocus===i?4:2,content:homeRows()[i]});
    })],
    imageObject: [new ImageContainerProperty({containerID:8,containerName:'title',xPosition:300,yPosition:0,width:144,height:24}), new ImageContainerProperty({containerID:4,containerName:'digits',xPosition:8,yPosition:78,width:156,height:144}), new ImageContainerProperty({containerID:5,containerName:'icons',xPosition:209,yPosition:106,width:20,height:20}), new ImageContainerProperty({containerID:13,containerName:'icon-second',xPosition:209,yPosition:196,width:20,height:20}), new ImageContainerProperty({containerID:6,containerName:'battery',xPosition:132,yPosition:18,width:28,height:20}), new ImageContainerProperty({containerID:7,containerName:'weather-icon',xPosition:12,yPosition:240,width:24,height:24})]
  }; }
