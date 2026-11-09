#!/usr/bin/env python3
"""Render recorded foundation tiles through native capture crops; no game, OBS or live service access.

python3 tools/stream/render_platform_fit.py --output /absolute/artifact/directory
These are geometric framing reconstructions, not game screenshots. The fixture records historical
acknowledged before commands and a private-copy tile survey; after commands use current platform_shot.
"""
import argparse, json
from pathlib import Path
from PIL import Image, ImageDraw, ImageFont
import cuts
from model import platform_shot

HERE=Path(__file__).resolve().parent


def render(output):
    data=json.loads((HERE/'fixtures/d30-platform-framing.json').read_text())
    layouts=[json.loads((HERE/'static'/n).read_text()) for n in ('layout.json','layout-portrait.json')]
    frac=cuts.platform_view_frac(layouts,data['capture'])
    cw,ch=data['capture']; output.mkdir(parents=True,exist_ok=True)
    font=ImageFont.truetype('/System/Library/Fonts/Supplemental/Arial.ttf',22)
    small=ImageFont.truetype('/System/Library/Fonts/Supplemental/Arial.ttf',17)
    summary=[]
    for row in data['ships']:
        after=platform_shot(dict(row['before_view'],hull=row['hull'],bounds_source='foundation'),frac=frac,overview=True)
        poses=[('before',row['ack']['row']['cmd']),('after-centre',after)]
        if after.get('pan'):
            poses.extend((('after-'+key,dict(after,position=dict(after['position'],y=after['pan'][end])))
                          for key,end in (('bow','y0'),('stern','y1'))))
        for lname,lay in zip(('landscape','portrait'),layouts):
            _,_,w,h=lay['cams']['main'];crop=cuts.crop_for(cw,ch,w,h)
            for phase,shot in poses:
                native=Image.new('RGB',(cw,ch),'#121923');d=ImageDraw.Draw(native)
                z=32*shot['zoom']*ch/1080;cx,cy=shot['position']['x'],shot['position']['y']
                def point(x,y):return (cw/2+(x-cx)*z,ch/2+(y-cy)*z)
                for y,spans in row['foundation_rows']:
                    for left,right in spans:
                        d.rectangle((*point(left,y),*point(right,y+1)),fill='#6ea18f')
                b=row['hull'];d.rectangle((*point(b['left'],b['top']),*point(b['right'],b['bottom'])),outline='#c1f5df',width=3)
                tile=native.crop((crop['cropLeft'],crop['cropTop'],cw-crop['cropRight'],ch-crop['cropBottom']))
                scale=min(w/tile.width,h/tile.height);tile=tile.resize((round(tile.width*scale),round(tile.height*scale)))
                pane=Image.new('RGB',(w,h),'#121923');pane.paste(tile,((w-tile.width)//2,(h-tile.height)//2))
                pd=ImageDraw.Draw(pane);pd.line((w/2-12,h/2,w/2+12,h/2),fill='#ffffff',width=2);pd.line((w/2,h/2-12,w/2,h/2+12),fill='#ffffff',width=2)
                frame=Image.new('RGB',(w+48,h+128),'#202936');frame.paste(pane,(24,85));fd=ImageDraw.Draw(frame)
                fd.text((24,12),f'{row["name"]} / {phase} / {lname} {w} x {h}',font=font,fill='white')
                fd.text((24,43),f'Centre ({cx:g}, {cy:g}); zoom {shot["zoom"]:g}; capture {cw} x {ch}; crop {crop["cropLeft"]} px each side',font=small,fill='#d2dde8')
                fd.rectangle((23,84,24+w,85+h),outline='#ffffff',width=1)
                fd.text((24,91+h),'Foundation-tile reconstruction; white cross = visible pane centre. Not a game screenshot.',font=small,fill='#d2dde8')
                filename=f'{row["name"]}-{lname}-{phase}.png';frame.save(output/filename)
                summary.append(dict(name=row['name'],layout=lname,phase=phase,position=shot['position'],zoom=shot['zoom'],crop=crop,file=filename))
    (output/'frames.json').write_text(json.dumps(summary,indent=2))
    thumbs=[]
    for row in summary:
        if row['layout']=='landscape' and row['phase'] in ('before','after-centre'):
            im=Image.open(output/row['file']);im.thumbnail((628,580));thumbs.append(im)
    sheet=Image.new('RGB',(1256,1740),'#202936')
    for i,im in enumerate(thumbs):sheet.paste(im,((i%2)*628,(i//2)*580))
    sheet.save(output/'contact-sheet.png')
    print(json.dumps(summary,indent=2))


if __name__=='__main__':
    ap=argparse.ArgumentParser(description=__doc__);ap.add_argument('--output',type=Path,required=True)
    render(ap.parse_args().output)
