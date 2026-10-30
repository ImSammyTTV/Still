"""Generate Still's original README motion illustration. Requires Pillow; no app dependencies."""
from pathlib import Path
from PIL import Image, ImageDraw, ImageFont
import math
ROOT=Path(__file__).resolve().parents[1]
OUT=ROOT/'assets/readme'; OUT.mkdir(exist_ok=True)
FONT=Path('/System/Library/Fonts/Avenir Next.ttc')
MONO=Path('/System/Library/Fonts/Menlo.ttc')
def font(size, mono=False):
    candidates=[MONO if mono else FONT,Path('/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf')]
    return next((ImageFont.truetype(str(p),size) for p in candidates if p.exists()),ImageFont.load_default())
W,H=1200,480
bg='#17191e'; ink='#f4f5f7'; muted='#a9b0bd'; accent='#8fd4cc'
def frame(t):
    im=Image.new('RGB',(W,H),bg);d=ImageDraw.Draw(im)
    for x in range(0,W,28):
        for y in range(0,H,28):d.point((x,y),fill='#25282e')
    d.text((58,45),'STILL',font=font(16,True),fill=accent)
    d.text((53,89),'Keep the moment.',font=font(58),fill=ink)
    d.text((56,166),'Make your point.',font=font(58),fill=ink)
    d.text((59,263),'Capture. Annotate. Share.',font=font(23),fill=muted)
    for i,label in enumerate(['macOS','Windows','Linux']):
        x=59+i*112;d.rounded_rectangle((x,326,x+99,363),radius=9,fill='#25292f',outline='#393f47');d.text((x+15,333),label,font=font(15),fill=ink)
    d.text((59,416),'A SCREENSHOT STUDIO FOR YOUR DESKTOP',font=font(11,True),fill='#798391')
    d.rounded_rectangle((617,47,1145,425),radius=22,fill='#22262c',outline='#42474f',width=1)
    for x in [641,658,675]:d.ellipse((x,65,x+6,71),fill='#65717d')
    d.text((704,57),'A little clarity goes a long way',font=font(12),fill=muted)
    d.rounded_rectangle((645,94,1117,344),radius=12,fill='#eef1ef')
    d.text((672,123),'GOOD IDEAS',font=font(13,True),fill='#65746f')
    d.text((671,157),'Worth keeping.',font=font(34),fill='#253b34')
    d.text((673,214),'Bring the important part into focus.',font=font(16),fill='#58675e')
    d.rounded_rectangle((672,261,1084,315),radius=8,fill='#dbe6df')
    d.text((688,277),'A clear screenshot says it better.',font=font(15),fill='#334c40')
    # Motion is limited to one short capture -> mark -> copy sequence.
    progress=max(0,min(1,t/.30)); x2=665+(1097-665)*progress; y2=112+(326-112)*progress
    d.rounded_rectangle((665,112,x2,y2),radius=4,outline='#388c81',width=2)
    if t>=.32:
        p=min(1,(t-.32)/.24); ex=1020-(1020-936)*p;ey=139+(194-139)*p
        d.line((1020,139,ex,ey),fill='#d06748',width=5)
        if p>.9:d.polygon([(936,194),(941,174),(953,192)],fill='#d06748')
    cx,cy=(int(x2),int(y2)) if t<.32 else (1038,311)
    d.polygon([(cx,cy),(cx+3,23+cy),(cx+9,cy+17),(cx+14,cy+28),(cx+21,cy+24),(cx+16,cy+14),(cx+25,cy+12)],fill='#1b2422',outline='white')
    active=0 if t<.32 else 1 if t<.70 else 2
    for i,label in enumerate(['01  Capture','02  Annotate','03  Share']):
        x=645+i*157;d.rounded_rectangle((x,366,x+146,402),radius=8,fill=accent if i==active else '#30353c')
        d.text((x+13,376),label,font=font(12,True),fill='#172a25' if i==active else '#bac3cd')
    if t>.70:
        d.rounded_rectangle((914,292,1126,332),radius=10,fill='#283d36',outline=accent)
        d.text((930,302),'Copied. Ready to paste.',font=font(14),fill='#e8faf4')
    return im
frames=[frame(i/49) for i in range(50)]
frames[-1].save(OUT/'capture-workflow.png',optimize=True)
# No loop extension: play once, then rest on the finished composition.
frames[0].save(OUT/'capture-workflow.gif',save_all=True,append_images=frames[1:],duration=[65]*49+[1600],optimize=True,disposal=2)
print('Wrote',OUT/'capture-workflow.gif')
