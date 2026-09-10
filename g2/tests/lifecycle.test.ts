import { MenuContainerProperty, MenuItemProperty, OsEventTypeList } from '@evenrealities/even_hub_sdk';
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
  const hardware: string[] = [];
  const shutdowns: number[] = [];
  let micResult = true;
  let onEvent: Function = () => {};
  let stop: Promise<any> | undefined;
  const validateLayout = (value: any) => {
    const text = value.textObject ?? [], images = value.imageObject ?? [];
    assert.ok(text.length <= 8, 'hardware supports at most eight text containers');
    assert.ok(images.length <= 4, 'hardware supports at most four image containers');
    const all = [...text, ...images];
    assert.equal(value.containerTotalNum, all.length);
    assert.ok(all.length <= 12);
    assert.equal(new Set(all.map(c => c.containerID)).size, all.length);
    for (const image of images) {
      assert.ok(image.width >= 20 && image.width <= 288);
      assert.ok(image.height >= 20 && image.height <= 144);
    }
    layout = value;
  };
  const bridge = {
    createStartUpPageContainer: async (value: any) => { validateLayout(value); return 0; },
    textContainerUpgrade: async (value: any) => { assert.ok(layout.textObject.some((c: any) => c.containerID === value.containerID && c.containerName === value.containerName), 'text updates must target an existing container'); assert.equal(typeof value.content, 'string'); displays.push(value); return true; },
    rebuildPageContainer: async (value: any) => { hardware.push('rebuild'); validateLayout(value); layouts.push(value); return true; },
    getAppLocation: async () => options.location ?? null,
    getDeviceInfo: async () => null, onDeviceStatusChanged() {}, updateImageRawData: async () => 0,
    audioControl: async (enabled: boolean) => { hardware.push(enabled ? 'mic-start' : 'mic-stop'); microphones.push(enabled); return !enabled && stop ? stop : micResult; },
    shutDownPageContainer: async (mode: number) => { shutdowns.push(mode); return true; },
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
    OsEventTypeList, MenuContainerProperty, MenuItemProperty,
  });
  const flush = async () => { for (let i = 0; i < 100; i++) await Promise.resolve(); };
  await flush();
  return { hardware, shutdowns, failMic: () => { micResult = false; }, get, flush, peers, displays, layouts, weatherURLs, layout, storage, writes, microphones, listeners,
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
  assert.equal(h.layout.containerTotalNum, 10);
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


test('follow-up display rebuild finishes before the microphone opens', async () => {
  const h = await harness(); await h.pair();
  h.peers[0].event({type:'state',text:JSON.stringify({queueVersion:1,status:'ready',cards:[{id:'one',threadId:'one',question:'First',answer:'Answer',status:'ready'}]})});
  await h.flush(); h.get('home').click(); await h.flush(); h.hardware.length = 0;
  h.get('talk').click(); await h.flush();
  assert.ok(h.hardware.indexOf('rebuild') >= 0);
  assert.ok(h.hardware.indexOf('mic-start') > h.hardware.indexOf('rebuild'));
  assert.equal(h.hardware.at(-1), 'mic-start');
});

test('double tap cancels recording and returns home without ending the feature', async () => {
  const h = await harness(); await h.pair(); await h.ready();
  h.get('talk').click(); await h.flush();
  h.event({sysEvent:{eventType:3}}); await h.flush();
  assert.equal(h.microphones.at(-1), false);
  assert.ok(h.peers[0].commands.includes('cancel'));
  assert.equal(h.shutdowns.length, 0);
  h.event({sysEvent:{eventType:3}}); await h.flush();
  assert.deepEqual(h.shutdowns, [1]);
});

test('menu Home survives overlay events and returns to the message list', async () => {
  const h = await harness(); await h.pair();
  h.peers[0].event({type:'state',text:JSON.stringify({queueVersion:1,status:'ready',cards:[{id:'one',threadId:'one',question:'First',answer:'Answer',status:'ready'}]})}); await h.flush();
  h.event({textEvent:{eventType:2}}); await h.flush(); h.event({textEvent:{eventType:0}}); await h.flush();
  h.event({sysEvent:{eventType:4}});
  h.event({menuItemClickEvent:{itemID:1}});
  h.event({sysEvent:{eventType:5}}); await h.flush();
  assert.ok(h.get('display').textContent.includes('New ask'));
  assert.equal(h.peers[0].closed, false);
  assert.equal(h.layouts.at(-1).menuObject.menuItems[0].itemName, 'Mynah Home');
});

test('failed mic start is recoverable and does not assert permission denial', async () => {
  const h = await harness(); await h.pair(); await h.ready(); h.failMic();
  h.get('talk').click(); await h.flush();
  assert.match(h.get('status').textContent, /Check the glasses connection/);
  assert.equal(h.get('permissions').open, undefined);
  assert.equal(h.get('talk').disabled, false);
  assert.ok(h.peers[0].commands.includes('cancel'));
});

test('a pending microphone stop completes before a subsequent start', async () => {
  const h = await harness(); await h.pair(); await h.ready();
  h.get('talk').click(); await h.flush();
  const stopped = deferred(); h.blockStop(stopped.promise);
  h.peers[0].event({type:'error',text:'First request failed'}); await h.flush();
  h.get('talk').click(); await h.flush();
  assert.equal(h.microphones.filter(Boolean).length, 1);
  stopped.resolve(true); await h.flush();
  assert.equal(h.microphones.filter(Boolean).length, 2);
});


test('system double tap with an empty text envelope goes back one level, then exits from Home', async () => {
  const h = await harness(); await h.pair();
  h.peers[0].event({type:'state',text:JSON.stringify({queueVersion:1,status:'ready',cards:[{id:'one',threadId:'one',question:'First',answer:'Answer',status:'ready'}]})}); await h.flush();
  h.get('home').click(); await h.flush();
  h.event({textEvent:{eventType:2}}); await h.flush();
  h.event({sysEvent:{eventSource:1}}); await h.flush();
  assert.ok(h.get('display').textContent.includes('? First'));
  h.event({textEvent:{},sysEvent:{eventType:3,eventSource:1}}); await h.flush();
  assert.ok(h.get('display').textContent.includes('New ask'));
  assert.equal(h.shutdowns.length, 0);
  h.event({textEvent:{},sysEvent:{eventType:3,eventSource:1}}); await h.flush();
  assert.deepEqual(h.shutdowns, [1]);
});


test('older Mac still shows the Home menu and explains missing shared chat support', async () => {
  const h = await harness(); await h.pair(); await h.ready();
  assert.ok(h.get('display').textContent.includes('New ask'));
  assert.match(h.get('backend-status').textContent, /has not reported chat-list support/);
  h.get('talk').click(); await h.flush();
  h.event({sysEvent:{eventType:3}}); await h.flush();
  assert.ok(h.get('display').textContent.includes('New ask'));
  assert.equal(h.shutdowns.length, 0);
});

test('idle disconnect does not ask Even to stop a microphone that was never opened', async () => {
  const h = await harness(); await h.pair(); await h.ready();
  h.peers[0].close(); await h.flush();
  assert.equal(h.microphones.length, 0);
  assert.match(h.get('status').textContent, /offline/);
});


test('connecting to a Mac with saved answers starts on the chat list', async () => {
  const h = await harness(); await h.pair();
  h.peers[0].event({type:'state',text:JSON.stringify({queueVersion:1,status:'ready',cards:[{id:'saved',threadId:'saved',question:'Saved question',answer:'Saved answer',status:'ready'}]})}); await h.flush();
  assert.match(h.get('backend-status').textContent, /Mac chat list connected/);
  assert.ok(h.get('display').textContent.includes('New ask'));
  assert.ok(h.get('display').textContent.includes('Saved question'));
  assert.ok(!h.get('display').textContent.includes('Saved answer'));
  h.event({textEvent:{eventType:2}}); await h.flush();
  h.event({sysEvent:{eventType:0}}); await h.flush();
  assert.ok(h.get('display').textContent.includes('Saved answer'));
  h.event({sysEvent:{eventType:3}}); await h.flush();
  assert.ok(h.get('display').textContent.includes('New ask'));
});
