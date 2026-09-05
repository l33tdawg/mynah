"""Render monochrome store previews, not photographs or hardware captures."""
from pathlib import Path
from PIL import Image, ImageDraw, ImageFont
import textwrap
ROOT = Path(__file__).resolve().parent
# Adapt the existing Mynah bird outline from scripts/make-icon.sh to a 24px mark.
points = [(516,248)]
def curve(end,a,b):
    start=points[-1]
    for i in range(1,25):
        t=i/24; u=1-t
        points.append(tuple(u*u*u*start[j]+3*u*u*t*a[j]+3*u*t*t*b[j]+t*t*t*end[j] for j in (0,1)))
curve((652,330),(592,248),(628,286)); curve((686,386),(670,348),(682,370))
curve((846,446),(762,388),(816,414)); curve((688,484),(818,478),(756,490))
curve((652,570),(672,514),(658,542)); curve((776,786),(646,660),(716,722))
points.extend([(880,960),(150,960)])
curve((256,776),(160,902),(194,828)); curve((346,600),(296,730),(336,668))
curve((322,430),(350,540),(322,486)); curve((516,248),(322,336),(404,248))
icon=Image.new('RGBA',(240,240),(0,0,0,0)); draw=ImageDraw.Draw(icon)
def p(x,y): return ((x-120)*.27+12,(y-230)*.27+12)
draw.polygon([p(x,y) for x,y in points],fill='white')
x,y=p(649,401); draw.ellipse((x-7,y-7,x+7,y+7),fill=(0,0,0,0))
icon.resize((24,24),Image.Resampling.LANCZOS).save(ROOT/'icon-24.png')
font=ImageFont.truetype('/System/Library/Fonts/Monaco.ttf',21)
screens=[('01-ready','MYNAH\n\nTap to talk.'),('02-working','MYNAH · Working\n\nYou can carry on.\nThe answer will appear here and in your notes-to-self chat.'),('03-answer','MYNAH\n\nAdded to your tasks:\nSend the venue shortlist tomorrow.\n\nThe details are in your notes-to-self chat.')]
for name,content in screens:
    im=Image.new('RGB',(576,288),'black'); d=ImageDraw.Draw(im)
    lines=[]
    for line in content.split('\n'): lines.extend(textwrap.wrap(line,width=42) or [''])
    d.multiline_text((8,8),'\n'.join(lines),font=font,fill='white',spacing=7)
    im.save(ROOT/(name+'.png'))
(ROOT/'ASSETS.md').write_text('''# Store assets\n\nicon-24.png is a monochrome adaptation of the existing Mynah bird mark.\nThe three 576 × 288 PNGs are rendered UI previews with sample content, not\nphysical glasses captures or proof that a task was executed. The sample answer\nis illustrative. Verify font wrapping and replace with simulator/device captures\nbefore final submission if the review requirements demand captures.\n\nRegenerate: python3 g2/store/make-assets.py\n''')
