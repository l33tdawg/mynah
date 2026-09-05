import {
  AudioInputSource, CreateStartUpPageContainer, OsEventTypeList,
  StartUpPageCreateResult, TextContainerProperty, TextContainerUpgrade,
  waitForEvenAppBridge, type EvenAppBridge
} from '@evenrealities/even_hub_sdk';
import { MynahConnection } from './connection.ts';
import { connectionURL, pages, type ReplyEvent } from './protocol.ts';
import { inputType } from './input.ts';

const el = <T extends HTMLElement>(id: string) => document.getElementById(id) as T;
const talk = el<HTMLButtonElement>('talk');
const connect = el<HTMLButtonElement>('connect');
const disconnect = el<HTMLButtonElement>('disconnect');
const previous = el<HTMLButtonElement>('previous');
const next = el<HTMLButtonElement>('next');
let bridge: EvenAppBridge | undefined;
let connection: MynahConnection | undefined;
let phase: 'offline' | 'connecting' | 'ready' | 'listening' | 'thinking' = 'offline';
let answer = '';
let reading = ['Connect on your phone to begin.'];
let page = 0;
let recorded = 0;
let recordingTimer: ReturnType<typeof setTimeout> | undefined;
let operation = Promise.resolve();
let desiredDisplay = '';
let drawing = false;
let turnError = false;
let savedPairing: string | undefined;
let reconnectTimer: ReturnType<typeof setTimeout> | undefined;
let reconnectAttempt = 0;
let exiting = false;

function status(text: string) { el('status').textContent = text; }
function controls() {
  talk.disabled = !bridge || !['ready','listening'].includes(phase);
  talk.textContent = phase === 'listening' ? 'Tap to send' : phase === 'thinking' ? 'Thinking…' : 'Tap to talk';
  disconnect.disabled = !savedPairing;
  el('connect-form').hidden = !!savedPairing;
  connect.disabled = !bridge || phase !== 'offline';
  previous.disabled = page === 0;
  next.disabled = page >= reading.length - 1;
}
function show(text: string) {
  reading = pages(text); page = 0; render();
}
function render() {
  const activity = phase === 'thinking' ? ' · Working' : phase === 'listening' ? ' · Listening' : '';
  const header = `MYNAH${activity}${reading.length > 1 ? `  ${page + 1}/${reading.length}` : ''}`;
  desiredDisplay = `${header}\n\n${reading[page]}`;
  el('display').textContent = desiredDisplay;
  controls();
  void draw();
}
async function draw() {
  if (!bridge || drawing) return;
  drawing = true;
  try {
    let sent: string;
    do {
      sent = desiredDisplay;
      const ok = await bridge.textContainerUpgrade(new TextContainerUpgrade({
        containerID: 1, containerName: 'mynah', contentOffset: 0,
        contentLength: sent.length, content: sent
      }));
      if (!ok) throw new Error('Could not update the glasses. Check their connection.');
    } while (sent !== desiredDisplay);
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
    case 'thinking':
      phase = 'thinking'; status('Working · you can carry on');
      show('You can carry on.\nThe answer will appear here and in your notes-to-self chat.'); break;
    case 'heard': el('heard').textContent = `You: ${event.text}`; break;
    case 'reply':
      if (answer.length + event.text.length > 100000) { connection?.close(); return; }
      answer += event.text; break;
    case 'error': turnError = true; status(event.text); show(event.text); break;
    case 'done':
      phase = 'ready';
      if (!turnError) { status('Answer ready · tap to ask a follow-up'); show(answer || 'No answer received. Tap to try again.'); }
      break;
    case 'state': {
      if (phase === 'listening') break;
      let state: { status?: string; text?: string };
      try { state = JSON.parse(event.text); } catch { break; }
      if (state.status === 'working') {
        phase = 'thinking'; status('Working · you can carry on');
        show('Your question is still being handled.\nThe answer will appear here and in your chat.');
      } else if (state.status === 'ready') {
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
  if (!bridge || !connection) return;
  if (phase === 'listening') {
    phase = 'thinking';
    await stopMicrophone();
    if (recorded < 12800) {
      connection.control('cancel'); phase = 'ready'; show('I need a little more audio. Tap and try again.'); return;
    }
    connection.control('stop'); phase = 'thinking'; status('Sending your question…');
    show('Sending your question…');
  } else if (phase === 'ready') {
    answer = ''; turnError = false; recorded = 0;
    el('heard').textContent = '';
    connection.control('start'); phase = 'listening'; controls();
    if (!await bridge.audioControl(true, AudioInputSource.Glasses)) throw new Error('Microphone unavailable. Allow G2 microphone access in Even Hub.');
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
    const current = new MynahConnection(receive, () => {
      if (connection !== current) return;
      phase = 'offline'; connection = undefined;
      void stopMicrophone();
      status(savedPairing ? 'Mynah is offline · reconnecting automatically' : 'Pair your Mynah to begin.');
      show(savedPairing ? 'Reconnecting to Mynah…\nYour submitted question stays on your Mac.' : 'Pair on your phone to begin.');
      scheduleReconnect();
    });
    connection = current;
    try {
      const link = savedPairing;
      await current.connect(link);
      await bridge.setLocalStorage('mynah.connection', link);
    }
    catch (error) { current.close(); status(message(error)); }
}
el<HTMLFormElement>('connect-form').addEventListener('submit', event => {
  event.preventDefault();
  queue(async () => {
    savedPairing = connectionURL(el<HTMLInputElement>('link').value).toString();
    // Persist the owner's explicit pairing even if the Mac is temporarily offline.
    await bridge?.setLocalStorage('mynah.connection', savedPairing);
    await connectPaired();
  });
});
talk.onclick = () => queue(toggleRecording);
disconnect.onclick = () => {
  savedPairing = undefined; clearTimeout(reconnectTimer); reconnectAttempt = 0;
  connection?.close(); el<HTMLInputElement>('link').value = '';
  void bridge?.setLocalStorage('mynah.connection', '');
  status('Pairing forgotten on this phone. Send //g2 unpair in Notes to Self to revoke it on your Mac.');
  controls();
};
previous.onclick = () => { page = Math.max(0, page - 1); render(); };
next.onclick = () => { page = Math.min(reading.length - 1, page + 1); render(); };
// A hidden WebView is normal when the paired phone is locked. Do not gate
// glasses input on document.visibilityState. Page teardown still stops capture.
window.addEventListener('pagehide', () => { exiting = true; clearTimeout(reconnectTimer); void stopMicrophone(); connection?.close(); });
window.addEventListener('online', () => { if (savedPairing && phase === 'offline') { clearTimeout(reconnectTimer); queue(connectPaired); } });

controls(); render();
const bridgeTimer = setTimeout(() => status('Open this companion inside Even Hub to connect your G2. This browser shows the display preview only.'), 8000);
void (async () => {
  const available = await waitForEvenAppBridge();
  const result = await available.createStartUpPageContainer(new CreateStartUpPageContainer({
    containerTotalNum: 1,
    textObject: [new TextContainerProperty({
      containerID: 1, containerName: 'mynah', xPosition: 0, yPosition: 0,
      width: 576, height: 288, paddingLength: 8, isEventCapture: 1,
      content: desiredDisplay
    })]
  }));
  if (result !== StartUpPageCreateResult.success) throw new Error('Could not open the glasses display. Reopen the companion in Even Hub.');
  bridge = available;
  clearTimeout(bridgeTimer);
  bridge.onEvenHubEvent(event => {
    if (event.sysEvent?.eventType === OsEventTypeList.SYSTEM_EXIT_EVENT || event.sysEvent?.eventType === OsEventTypeList.ABNORMAL_EXIT_EVENT) {
      exiting = true; clearTimeout(reconnectTimer);
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
      case OsEventTypeList.CLICK_EVENT: queue(toggleRecording); break;
      case OsEventTypeList.DOUBLE_CLICK_EVENT:
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
  const saved = await bridge.getLocalStorage('mynah.connection');
  if (saved) {
    try {
      el<HTMLInputElement>('link').value = connectionURL(saved).toString();
      savedPairing = connectionURL(saved).toString();
      await connectPaired();
    } catch { await bridge.setLocalStorage('mynah.connection', ''); }
  }
})().catch(error => { clearTimeout(bridgeTimer); status(message(error)); });
