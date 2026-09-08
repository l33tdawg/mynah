"""Render monochrome store previews, not photographs or hardware captures."""
from pathlib import Path
from PIL import Image, ImageDraw, ImageFont
import textwrap
import sys
ROOT = Path(__file__).resolve().parent
# Optical pixel adaptation of MynahMark/EyePatch in scripts/make-icon.sh.
# Keep the right-facing profile, broad bust and distinctive tapered eye flash.
# G2 uses white ink on transparent, so the yellow eye patch becomes a cutout.
# Each tuple is a native 2x2-brush stroke: row, start column, end column.
ICON_STROKES = [(2,9,12),(4,7,14),(6,6,15),(8,6,19),(10,6,17),
                (12,7,14),(14,7,15),(16,6,16),(18,4,18),(20,2,20)]
icon=Image.new('RGBA',(24,24),(0,0,0,0)); draw=ImageDraw.Draw(icon)
for row,start,end in ICON_STROKES:
    draw.rectangle((start,row,end+1,row+1),fill='white')
draw.rectangle((12,8,15,9),fill=(0,0,0,0))
icon.save(ROOT/'icon-24.png')
if '--icon-only' in sys.argv:
    sys.exit(0)
font=ImageFont.truetype('/System/Library/Fonts/Monaco.ttf',21)
screens=[('01-ready','MYNAH\n\nTap to talk.'),('02-working','MYNAH · Working\n\nYou can carry on.\nThe answer will appear here and in your notes-to-self chat.'),('03-answer','MYNAH\n\nAdded to your tasks:\nSend the venue shortlist tomorrow.\n\nThe details are in your notes-to-self chat.')]
for name,content in screens:
    im=Image.new('RGB',(576,288),'black'); d=ImageDraw.Draw(im)
    lines=[]
    for line in content.split('\n'): lines.extend(textwrap.wrap(line,width=42) or [''])
    d.multiline_text((8,8),'\n'.join(lines),font=font,fill='white',spacing=7)
    im.save(ROOT/(name+'.png'))
# ASSETS.md contains hand-maintained capture provenance; never overwrite it.
