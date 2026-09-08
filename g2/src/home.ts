// Packed 4-bit grayscale for the SDK, two pixels per byte, high nibble first.
// Drawing primitives keep the clock independent of installed fonts.
export function clockPixels(now: Date): number[] {
  const width = 156, height = 144, pixels = new Uint8Array(width * height / 2);
  const rect = (x: number, y: number, w: number, h: number) => {
    for (let yy=y; yy<y+h; yy++) for (let xx=x; xx<x+w; xx++) {
      if (xx<0 || yy<0 || xx>=width || yy>=height) continue;
      // Two-pixel LEDs on a three-pixel grid reproduce the dashboard dot matrix.
      if (xx % 3 === 2 || yy % 3 === 2) continue;
      const p=yy*width+xx; pixels[p >> 1] |= p % 2 ? 15 : 240;
    }
  };
  const segments = ['abcdef','bc','abdeg','abcdg','bcfg','acdfg','acdefg','abc','abcdefg','abcdfg'];
  const digits = now.getHours().toString().padStart(2,'0') + now.getMinutes().toString().padStart(2,'0');
  Array.from(digits).forEach((digit,i) => {
    const x = 18 + (i % 2) * 66, y = 4 + Math.floor(i / 2) * 72;
    const pieces: Record<string, number[]> = {a:[5,0,39,5],b:[44,5,5,24],c:[44,34,5,24],d:[5,59,39,5],e:[0,34,5,24],f:[0,5,5,24],g:[5,29,39,5]};
    for (const part of segments[Number(digit)]) { const [dx,dy,w,h]=pieces[part]; rect(x+dx,y+dy,w,h); }
  });
  return Array.from(pixels);
}
export function batteryLabel(level?: number, charging?: boolean): string {
  if (typeof level !== 'number' || !Number.isFinite(level) || level < 0 || level > 100) return '[--]';
  const bars = Math.round(level / 25);
  return `[${'|'.repeat(bars)}${' '.repeat(4-bars)}] ${Math.round(level)}%${charging ? '+' : ''}`;
}
export function weatherLabel(code: number, temperature: number): string {
  const condition = code === 0 ? '☀ Clear' : code <= 3 ? '☁ Cloudy' : code <= 48 ? '≋ Fog' : code <= 67 ? '☂ Rain' : code <= 77 ? '❄ Snow' : code <= 82 ? '☂ Showers' : code <= 86 ? '❄ Snow' : 'ϟ Storm';
  return `${Math.round(temperature)}°C\n${condition}`;
}

export function statusPixels(kinds: string[], focused = -1, height = 144): number[] {
  const pixels = new Uint8Array(20 * height / 2);
  const dot = (x:number,y:number) => { if(x<0||x>=20||y<0||y>=height)return; const p=y*20+x; pixels[p>>1]|=p%2?15:240; };
  const line = (x1:number,y1:number,x2:number,y2:number) => { const n=Math.max(Math.abs(x2-x1),Math.abs(y2-y1)); for(let i=0;i<=n;i++) dot(Math.round(x1+(x2-x1)*i/(n||1)),Math.round(y1+(y2-y1)*i/(n||1))); };
  kinds.forEach((kind,i) => {
    const y=i*90;
    if (i === focused) {line(0,y,19,y);line(0,y,0,y+13);line(19,y,19,y+13);line(0,y+13,19,y+13);}
    if(kind==='new'){ line(3,y+8,15,y+8);line(9,y+2,9,y+14); }
    else if(kind==='ready'){line(3,y+8,7,y+12);line(7,y+12,16,y+3);}
    else if(kind==='failed'){line(9,y+2,9,y+10);dot(9,y+14);}
    else {
      for(let a=0;a<360;a+=8){const r=a*Math.PI/180;dot(Math.round(9+7*Math.cos(r)),y+8+Math.round(7*Math.sin(r)));}
      if(kind==='queued'){line(9,y+3,9,y+8);line(9,y+8,13,y+10);}
      else {dot(6,y+8);dot(9,y+8);dot(12,y+8);}
    }
  });
  return Array.from(pixels);
}

function tinyBitmap(width: number, height: number, paint: (line: (x1:number,y1:number,x2:number,y2:number)=>void, dot:(x:number,y:number)=>void)=>void): number[] {
  const pixels = new Uint8Array(width*height/2);
  const dot = (x:number,y:number) => { if(x<0||x>=width||y<0||y>=height)return;const p=y*width+x;pixels[p>>1]|=p%2?15:240; };
  const line = (x1:number,y1:number,x2:number,y2:number) => {const n=Math.max(Math.abs(x2-x1),Math.abs(y2-y1));for(let i=0;i<=n;i++)dot(Math.round(x1+(x2-x1)*i/(n||1)),Math.round(y1+(y2-y1)*i/(n||1)));};
  paint(line,dot);return Array.from(pixels);
}
export function batteryPixels(level?: number): number[] {
  return tinyBitmap(28,20,(line)=>{
    line(1,4,23,4);line(1,4,1,15);line(1,15,23,15);line(23,4,23,15);
    line(25,7,26,7);line(26,7,26,12);line(25,12,26,12);
    if (typeof level !== 'number' || !Number.isFinite(level)) {line(9,9,14,9);return;}
    const bars=Math.round(Math.max(0,Math.min(100,level))/25);
    for(let i=0;i<bars;i++)for(let x=4+i*5;x<7+i*5;x++)line(x,7,x,12);
  });
}
export function weatherPixels(code?: number): number[] {
  return tinyBitmap(24,24,(line,dot)=>{
    if (code === undefined) {
      // Neutral unknown-weather symbol, never a fabricated condition.
      line(7,7,9,4);line(9,4,14,4);line(14,4,17,7);line(17,7,17,10);line(17,10,12,14);line(12,14,12,16);dot(12,20);
      return;
    }
    const circle=(cx:number,cy:number,r:number)=>{for(let a=0;a<360;a+=8){const n=a*Math.PI/180;dot(Math.round(cx+r*Math.cos(n)),Math.round(cy+r*Math.sin(n)));}};
    if(code===0){
      circle(12,12,5);for(let a=0;a<360;a+=45){const n=a*Math.PI/180;line(Math.round(12+8*Math.cos(n)),Math.round(12+8*Math.sin(n)),Math.round(12+10*Math.cos(n)),Math.round(12+10*Math.sin(n)));}
    } else if (code<=3 || code>=51) {
      // Cloud silhouette, with precipitation beneath when appropriate.
      line(3,15,20,15);line(2,14,2,11);line(2,11,5,9);line(5,9,7,9);line(7,9,8,5);line(8,5,12,4);line(12,4,16,7);line(16,7,17,10);line(17,10,20,10);line(20,10,22,12);line(22,12,22,14);line(22,14,20,15);
      if(code>=95){line(12,17,9,20);line(9,20,13,20);line(13,20,11,23);}
      else if(code>=71&&code<=77||code>=85&&code<=86){for(const x of [6,16]){line(x,18,x,22);line(x-2,20,x+2,20);}}
      else if(code>=51){for(const x of [5,12,19])line(x,18,x-2,22);}
    } else {for(const y of [7,12,17])line(3,y,21,y);}
  });
}

export function titlePixels(): number[] {
  const glyphs: Record<string,string[]> = {
    M:['10001','11011','10101','10101','10001','10001','10001'],
    Y:['10001','10001','01010','00100','00100','00100','00100'],
    N:['10001','11001','11001','10101','10011','10011','10001'],
    A:['01110','10001','10001','11111','10001','10001','10001'],
    H:['10001','10001','10001','11111','10001','10001','10001'],
    G:['01110','10001','10000','10111','10001','10001','01110'],
    '2':['01110','10001','00001','00010','00100','01000','11111'],
    ' ':['00000','00000','00000','00000','00000','00000','00000']
  };
  return tinyBitmap(144,24,(line,dot)=>{
    line(0,12,17,12);line(126,12,143,12);
    Array.from('MYNAH G2').forEach((c,i)=>glyphs[c].forEach((row,y)=>Array.from(row).forEach((pixel,x)=>{
      if(pixel==='1')for(let dx=0;dx<2;dx++)for(let dy=0;dy<2;dy++)dot(25+i*12+x*2+dx,5+y*2+dy);
    })));
  });
}
