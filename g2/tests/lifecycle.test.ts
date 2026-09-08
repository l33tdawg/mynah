import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { runInNewContext } from 'node:vm';
import ts from 'typescript';
import {randomUUID} from 'node:crypto';
import { connectionURL, cardPages } from '../src/protocol.ts';
import { clockPixels, batteryLabel, weatherLabel, statusPixels, batteryPixels, weatherPixels, titlePixels } from '../src/home.ts';
import { Cards, cardIcon } from '../src/cards.ts';
import { inputType } from '../src/input.ts';

const link = 'https://call.sage.delivery/' + 'a'.repeat(32);
function deferred() {
  let resolve!: (value?: any) => void;
  const promise = new Promise<any>(r => { resolve = r; });
  return { promise, resolve };
}
async function harness(options: { connect?: Promise<any>; saved?: Promise<any>; location?: Promise<any> } = {}) {
  const elements = new Map<string, any>();
  const listeners: Record<string, Function> = {};
  const storage = new Map<string, string>();
  const writes: string[] = [];
  const peers: any[] = [];
  const displays: any[] = [];
  const layouts: any[] = [];
  const weatherURLs: string[] = [];
  let layout: any;
  const microphones: boolean[] = [];
  let onEvent: Function = () => {};
  let stop: Promise<any> | undefined;
  const bridge = {
    createStartUpPageContainer: async (value: any) => { layout = value; return 0; },
    textContainerUpgrade: async (value: any) => { displays.push(value); return true; },
    rebuildPageContainer: async (value: any) => { layouts.push(value); return true; },
    getAppLocation: async () => options.location ?? null,
    getDeviceInfo: async () => null, onDeviceStatusChanged() {}, updateImageRawData: async () => 0,
    audioControl: async (enabled: boolean) => { microphones.push(enabled); return !enabled && stop ? stop : true; },
    shutDownPageContainer: async () => true,
    onEvenHubEvent: (cb: Function) => { onEvent = cb; },
    getLocalStorage: async (key: string) => key === 'mynah.connection' && options.saved ? options.saved : '',
    setLocalStorage: async (key: string, value: string) => { writes.push(value); storage.set(key, value); },
  };
  class Connection {
    closed = false;
    commands: string[] = [];
    event: Function;
    ended: Function;
    constructor(event: Function, ended: Function) { this.event = event; this.ended = ended; peers.push(this); }
    async connect() { await options.connect; }
    startRequest(id: string, parentId?: string) { this.commands.push(JSON.stringify({id,parentId})); }
    control(command: string) { if (this.closed) throw Error('disconnected'); this.commands.push(command); }
    audio() {}
    close() { if (!this.closed) { this.closed = true; this.ended(); } }
  }
  const get = (id: string) => {
    if (!elements.has(id)) elements.set(id, { value: '', textContent: '', disabled: false, hidden: false, classList: { add() {}, remove() {} },
      addEventListener(name: string, callback: Function) { this[name] = callback; },
      click() { this.onclick?.(); }
    });
    return elements.get(id);
  };
  let timer = 0;
  const timers = new Map<number, {fn: Function; delay: number}>();
  const source = readFileSync(new URL('../src/main.ts', import.meta.url), 'utf8').replace(/^import[\s\S]*?from ['"][^'"]+['"];\n/gm, '');
  const code = ts.transpileModule(source, { compilerOptions: { target: ts.ScriptTarget.ES2022, module: ts.ModuleKind.None } }).outputText;
  runInNewContext(code, {
    fetch: async (url: string) => { weatherURLs.push(url); return {ok:true,json:async()=>({current:{weather_code:61,temperature_2m:24.4}})}; }, AbortSignal,
    crypto: {randomUUID}, document: { getElementById: get }, window: { addEventListener: (name: string, cb: Function) => { listeners[name] = cb; } },
    setTimeout: (fn: Function, delay: number) => { timers.set(++timer, {fn, delay}); return timer; }, clearTimeout: (id: number) => timers.delete(id),
    waitForEvenAppBridge: async () => bridge, MynahConnection: Connection, connectionURL, cardPages, inputType, Cards, cardIcon, clockPixels, batteryLabel, weatherLabel, statusPixels, batteryPixels, weatherPixels, titlePixels,
    CreateStartUpPageContainer: class { constructor(value: any) { Object.assign(this, value); } }, TextContainerProperty: class { constructor(value: any) { Object.assign(this, value); } }, TextContainerUpgrade: class { constructor(value: any) { Object.assign(this, value); } },
    AppLocationAccuracy:{Low:'low'},
    RebuildPageContainer: class { constructor(value: any) { Object.assign(this, value); } },
    ImageContainerProperty: class { constructor(value: any) { Object.assign(this, value); } }, ImageRawDataUpdate: class {}, ImageRawDataUpdateResult: {success:0},
    StartUpPageCreateResult: { success: 0 }, AudioInputSource: { Glasses: 1 },
    OsEventTypeList: { CLICK_EVENT: 0, SCROLL_TOP_EVENT: 1, SCROLL_BOTTOM_EVENT: 2, DOUBLE_CLICK_EVENT: 3, SYSTEM_EXIT_EVENT: 4, ABNORMAL_EXIT_EVENT: 5 },
  });
  const flush = async () => { for (let i = 0; i < 40; i++) await Promise.resolve(); };
  await flush();
  return { get, flush, peers, displays, layouts, weatherURLs, layout, storage, writes, microphones, listeners,
    expireWaiting: () => { for (const [id, t] of timers) if (t.delay === 10000) { timers.delete(id); t.fn(); } },
    event: (event: any) => onEvent(event), blockStop: (value: Promise<any>) => { stop = value; },
    pair: async () => { get('link').value = link; get('connect-form').submit({ preventDefault() {} }); await flush(); },
    ready: async () => { peers.at(-1).event({ type: 'state', text: JSON.stringify({status:'ready',text:''}) }); await flush(); }
  };
}

test('Forget pairing wins over a connection that completes later', async () => {
  const connecting = deferred();
  const h = await harness({connect:connecting.promise});
  await h.pair(); h.get('disconnect').click(); await h.flush();
  connecting.resolve(); await h.flush();
  assert.equal(h.storage.get('mynah.connection'), '');
  assert.equal(h.get('connect-form').hidden, false);
});

test('Forget pairing wins over delayed startup storage read', async () => {
  const saved = deferred(); const h = await harness({saved:saved.promise});
  h.get('disconnect').click(); await h.flush(); saved.resolve(link); await h.flush();
  assert.equal(h.peers.length, 0);
});

test('disconnect during microphone stop cannot submit or leave Thinking stuck', async () => {
  const h = await harness(); await h.pair(); await h.ready();
  h.get('talk').click(); await h.flush();
  h.event({ audioEvent: {source:1,audioPcm:new Uint8Array(16000)} });
  const stopped = deferred(); h.blockStop(stopped.promise);
  h.get('talk').click(); await h.flush(); h.peers[0].close(); stopped.resolve(true); await h.flush();
  assert.equal(h.peers[0].commands.includes('stop'), false);
  assert.equal(h.get('talk').textContent, 'Tap to talk');
  assert.equal(h.get('talk').disabled, true);
});

test('server error while recording stops the microphone and allows retry', async () => {
  const h = await harness(); await h.pair(); await h.ready(); h.get('talk').click(); await h.flush();
  h.peers[0].event({type:'error',text:'Recording rejected'});
  h.peers[0].event({type:'done',text:''}); await h.flush();
  assert.equal(h.microphones.at(-1), false);
  assert.equal(h.get('talk').disabled, false);
});

test('revoked authorization clears saved pairing and offers setup', async () => {
  const h = await harness(); await h.pair(); await h.ready();
  h.peers[0].event({type:'state',text:'{"status":"unpaired"}'}); await h.flush();
  assert.equal(h.storage.get('mynah.connection'), '');
  assert.equal(h.peers[0].closed, true);
  assert.equal(h.get('connect-form').hidden, false);
});

test('restoring the page reconnects without recording or replaying a question', async () => {
  const h = await harness(); await h.pair(); await h.ready();
  h.listeners.pagehide(); await h.flush();
  h.listeners.pageshow?.({persisted:true}); await h.flush();
  assert.equal(h.peers.length, 2);
  assert.equal(h.microphones.includes(true), false);
  assert.equal(h.peers[1].commands.length, 0);
});

test('events from a forgotten connection cannot show an old answer', async () => {
  const h = await harness(); await h.pair(); await h.ready();
  h.get('disconnect').click(); await h.flush();
  h.peers[0].event({type:'reply',text:'Old private answer'});
  h.peers[0].event({type:'done',text:''}); await h.flush();
  assert.equal(h.get('display').textContent.includes('Old private answer'), false);
  assert.equal(h.get('talk').disabled, true);
});

test('normal recording sends audio once, displays the reply, and can take a follow-up', async () => {
  const h = await harness(); await h.pair(); await h.ready();
  h.get('talk').click(); await h.flush();
  h.event({audioEvent:{source:1,audioPcm:new Uint8Array(16000)}});
  h.get('talk').click(); await h.flush();
  assert.deepEqual(h.peers[0].commands, ['start','stop']);
  h.peers[0].event({type:'reply',text:'The answer'});
  h.peers[0].event({type:'done',text:''}); await h.flush();
  assert.ok(h.get('display').textContent.includes('The answer'));
  assert.equal(h.get('talk').disabled, false);
  h.get('talk').click(); await h.flush();
  assert.deepEqual(h.peers[0].commands, ['start','stop','start']);
});

test('waiting explanation appears once, clears after ten seconds, and the answer returns', async () => {
  const h = await harness(); await h.pair(); await h.ready();
  h.peers[0].event({type:'thinking',text:''}); await h.flush();
  assert.ok(h.get('display').textContent.includes('You can carry on'));
  h.expireWaiting(); await h.flush();
  assert.equal(h.displays.filter(d => d.containerID === 1).at(-1).content.trim(), '');
  assert.match(h.get('clock').textContent, /\d{2}\n\d{2}/);
  h.peers[0].event({type:'state',text:'{"status":"working"}'}); await h.flush();
  assert.equal(h.displays.filter(d => d.containerID === 1).at(-1).content.trim(), '', 'status updates must not wake the display');
  h.peers[0].event({type:'reply',text:'Task saved'});
  h.peers[0].event({type:'done',text:''}); await h.flush();
  assert.ok(h.get('display').textContent.includes('Task saved'));
  h.peers[0].event({type:'thinking',text:''}); await h.flush();
  assert.ok(!h.get('display').textContent.includes('You can carry on'));
  assert.ok(h.get('display').textContent.includes('Working'));
  h.peers[0].event({type:'reply',text:'Another answer'});
  h.peers[0].event({type:'done',text:''}); await h.flush();
  h.expireWaiting(); await h.flush();
  assert.ok(h.get('display').textContent.includes('Another answer'), 'old waiting timeout cannot clear an answer');
});

test('home has a persistent clock and exactly one framed input panel', async () => {
  const h = await harness();
  assert.equal(h.layout.containerTotalNum, 12);
  const panels = h.layout.textObject;
  assert.equal(panels.filter((p: any) => p.isEventCapture === 1).length, 1);
  assert.equal(panels[0].borderWidth, 1);
  assert.ok(panels[1].xPosition + panels[1].width <= panels[0].xPosition);
  await h.pair(); await h.ready();
  h.event({textEvent:{eventType:0}}); await h.flush();
  assert.equal(h.microphones.at(-1), true);
  assert.match(h.get('clock').textContent, /\d{2}\n\d{2}/);
});

test('queue accepts another recording and defers an arriving answer until it is sent', async () => {
  const h = await harness(); await h.pair();
  const snapshot = (cards: any[]) => h.peers[0].event({type:'state',text:JSON.stringify({queueVersion:1,status:'ready',text:'',cards})});
  snapshot([]); await h.flush();
  h.get('talk').click(); await h.flush();
  const first = JSON.parse(h.peers[0].commands[0]).id;
  h.event({audioEvent:{source:1,audioPcm:new Uint8Array(16000)}});
  h.get('talk').click(); await h.flush();
  assert.equal(h.get('talk').disabled,false);
  assert.ok(h.get('display').textContent.includes('You can carry on'));
  h.get('talk').click(); await h.flush();
  snapshot([{id:first,threadId:first,question:'First question',answer:'First answer',status:'ready'}]); await h.flush();
  assert.ok(h.get('display').textContent.includes('Listening'));
  h.event({audioEvent:{source:1,audioPcm:new Uint8Array(16000)}});
  h.get('talk').click(); await h.flush();
  assert.ok(h.get('display').textContent.includes('First answer'));
  assert.equal(h.peers[0].commands.filter((c: string)=>c==='stop').length,2);
});

test('scroll moves the selector box, tap opens, and double tap returns Home', async () => {
  const h=await harness();await h.pair();
  h.peers[0].event({type:'state',text:JSON.stringify({queueVersion:1,status:'ready',text:'',cards:[{id:'one',threadId:'one',question:'First',answer:'',status:'queued'}]})});await h.flush();
  h.event({textEvent:{eventType:2}});await h.flush();
  const rows=h.layouts.at(-1).textObject;
  assert.equal(rows.find((r:any)=>r.containerID===9).borderColor,4);
  assert.equal(rows.find((r:any)=>r.containerID===12).borderColor,1);
  h.event({textEvent:{eventType:0}});await h.flush();
  assert.ok(h.get('display').textContent.includes('? First'));
  h.event({textEvent:{eventType:3}});await h.flush();
  assert.ok(h.get('display').textContent.includes('New ask'));
});
test('weather uses rounded SDK location and disabling cancels a pending location read', async () => {
  const location=deferred();const h=await harness({location:location.promise});
  h.get('weather-enable').click();await h.flush();h.get('weather-off').click();
  location.resolve({latitude:3.14159,longitude:101.68653});await h.flush();
  assert.equal(h.weatherURLs.length,0);
  h.get('weather-enable').click();await h.flush();
  assert.ok(h.weatherURLs[0].includes('latitude=3.14&longitude=101.69'));
  assert.equal(h.get('home-weather').textContent,'24°C');
});
