#!/usr/bin/env python3
"""Bake shared SVG icon assets into renderer-neutral strokes and fills.

Sources live in assets/icons. Regeneration is offline and preserves SVG fills.
Curves flatten to <=0.08 SVG units before scaling to the native icon size.
"""
import argparse, math, pathlib, re, subprocess, xml.etree.ElementTree as ET
ROOT = pathlib.Path(__file__).resolve().parents[1]
ASSETS = ROOT / 'assets/icons'
ICONS = {'folder': 'folder', 'folder_open': 'folder_open', 'file': 'file', 'code': 'file_code', 'zig': 'file_code', 'markdown': 'file_markdown', 'image': 'image', 'chevron_down': 'chevron_down', 'chevron_right': 'chevron_right', 'chevron_left': 'chevron_left', 'plus': 'plus', 'close': 'close', 'search': 'magnifying_glass', 'split': 'split', 'sidebar': 'file_tree', 'branch': 'git_branch', 'history': 'rotate_ccw', 'settings': 'settings', 'commands': 'command', 'more': 'ellipsis', 'check': 'check', 'extension': 'box', 'refresh': 'refresh_title', 'arrow_up': 'arrow_up', 'arrow_down': 'arrow_down', 'square': 'square', 'square_checked': 'square-check', 'square_mixed': 'square_minus', 'commit': 'git_commit', 'user': 'person', 'diff': 'diff', 'minus': 'dash', 'copy': 'copy', 'stash': 'archive'}
def curve(a,b,c,d):
    distance = lambda p: abs((d[0]-a[0])*(a[1]-p[1])-(a[0]-p[0])*(d[1]-a[1])) / max(math.dist(a,d), 1e-9)
    if max(distance(b),distance(c)) < .08 and math.dist(a,b)+math.dist(b,c)+math.dist(c,d)-math.dist(a,d)<.08:
        return [d]
    mid = lambda x,y: ((x[0]+y[0])/2,(x[1]+y[1])/2)
    ab,bc,cd=mid(a,b),mid(b,c),mid(c,d); abc,bcd=mid(ab,bc),mid(bc,cd); center=mid(abc,bcd)
    return curve(a,ab,abc,center)+curve(center,bcd,cd,d)
def arc(p, rx, ry, rotation, large, sweep, end):
    rx,ry=abs(rx),abs(ry)
    if not rx or not ry or p==end: return [end]
    angle=math.radians(rotation); co,si=math.cos(angle),math.sin(angle)
    x=co*(p[0]-end[0])/2+si*(p[1]-end[1])/2; y=-si*(p[0]-end[0])/2+co*(p[1]-end[1])/2
    factor=max(1,math.sqrt(x*x/(rx*rx)+y*y/(ry*ry))); rx*=factor; ry*=factor
    k=math.sqrt(max(0,(rx*rx*ry*ry-rx*rx*y*y-ry*ry*x*x)/(rx*rx*y*y+ry*ry*x*x))) * (-1 if bool(large)==bool(sweep) else 1)
    cx,cy=k*rx*y/ry,-k*ry*x/rx
    start=math.atan2((y-cy)/ry,(x-cx)/rx); stop=math.atan2((-y-cy)/ry,(-x-cx)/rx); delta=stop-start
    if sweep and delta<0: delta+=math.tau
    if not sweep and delta>0: delta-=math.tau
    center=(co*cx-si*cy+(p[0]+end[0])/2, si*cx+co*cy+(p[1]+end[1])/2)
    count=max(1,math.ceil(abs(delta)/max(.05,2*math.acos(max(-1,1-.08/max(rx,ry))))))
    out=[]
    for n in range(1,count+1):
        t=start+delta*n/count; u,v=rx*math.cos(t),ry*math.sin(t)
        out.append((center[0]+co*u-si*v,center[1]+si*u+co*v))
    out[-1]=end
    return out

def path_data(data):
    tokens=re.findall(r'[A-Za-z]|[-+]?(?:\d*\.\d+|\d+\.?\d*)(?:[eE][-+]?\d+)?',data)
    paths=[]; points=[]; p=(0.,0.); previous=''; control=None; command=''; i=0
    def point(values,relative): return (values[0]+(p[0] if relative else 0), values[1]+(p[1] if relative else 0))
    while i<len(tokens):
        if tokens[i].isalpha(): command=tokens[i];i+=1
        op=command.upper(); relative=command.islower()
        if op=='Z':
            if points: points.append(points[0]);p=points[0];paths.append(points);points=[]
            command='';previous='Z';continue
        lengths={'M':2,'L':2,'H':1,'V':1,'C':6,'S':4,'Q':4,'T':2,'A':7}
        if op not in lengths: raise ValueError(f'Unsupported SVG command {command}')
        n=lengths[op];values=list(map(float,tokens[i:i+n]));i+=n; old=p
        if op=='M':
            if points: paths.append(points)
            p=point(values,relative);points=[p];command='l' if relative else 'L'
        elif op=='L': p=point(values,relative);points.append(p)
        elif op=='H': p=(values[0]+(p[0] if relative else 0),p[1]);points.append(p)
        elif op=='V': p=(p[0],values[0]+(p[1] if relative else 0));points.append(p)
        elif op in ('C','S'):
            if op=='C': b,c,end=point(values[:2],relative),point(values[2:4],relative),point(values[4:],relative)
            else: b=(2*p[0]-control[0],2*p[1]-control[1]) if previous in ('C','S') else p;c,end=point(values[:2],relative),point(values[2:],relative)
            points.extend(curve(p,b,c,end));p=end;control=c
        elif op in ('Q','T'):
            if op=='Q': c,end=point(values[:2],relative),point(values[2:],relative)
            else: c=(2*p[0]-control[0],2*p[1]-control[1]) if previous in ('Q','T') else p;end=point(values,relative)
            b=(p[0]+(c[0]-p[0])*2/3,p[1]+(c[1]-p[1])*2/3);d=(end[0]+(c[0]-end[0])*2/3,end[1]+(c[1]-end[1])*2/3)
            points.extend(curve(p,b,d,end));p=end;control=c
        elif op=='A': end=point(values[5:],relative);points.extend(arc(p,*values[:5],end));p=end
        previous=op
    if points: paths.append(points)
    return paths


def svg_geometry(name):
    root = ET.parse(ASSETS/(name+'.svg')).getroot()
    view = list(map(float, root.attrib.get('viewBox', '0 0 '+root.attrib.get('width','24')+' '+root.attrib.get('height','24')).split()))
    if view[:2] != [0, 0] or view[2] != view[3]: raise ValueError('Icons require a square origin viewBox')
    scale = 24 / view[2]
    strokes, fills = [], []
    def visit(node, inherited):
        attrs = dict(inherited); attrs.update(node.attrib)
        attrs['opacity'] = float(inherited.get('opacity',1))*float(node.attrib.get('opacity',1))
        kind = node.tag.split('}')[-1]
        if kind == 'defs': return # The selected Markdown SVG clips to its full viewBox.
        if kind in ('svg', 'g'):
            for child in node: visit(child, attrs)
            return
        number = lambda key, default=0: float(attrs.get(key, default))
        if kind == 'path': paths = path_data(attrs['d'])
        elif kind == 'line': paths = [[(number('x1'), number('y1')), (number('x2'), number('y2'))]]
        elif kind in ('polyline', 'polygon'):
            values = list(map(float, re.findall(r'[-+]?\d*\.?\d+', attrs['points'])))
            points = list(zip(values[::2], values[1::2])); paths = [points + points[:1] if kind == 'polygon' else points]
        elif kind in ('circle', 'ellipse'):
            cx, cy = number('cx'), number('cy')
            rx, ry = (number('r'), number('r')) if kind == 'circle' else (number('rx'), number('ry'))
            paths = [[(cx+rx*math.cos(n*math.tau/64), cy+ry*math.sin(n*math.tau/64)) for n in range(65)]]
        elif kind == 'rect':
            x,y,w,h = number('x'),number('y'),number('width'),number('height'); r=min(number('rx'),w/2,h/2)
            paths = path_data(f'M{x+r} {y} H{x+w-r} A{r} {r} 0 0 1 {x+w} {y+r} V{y+h-r} A{r} {r} 0 0 1 {x+w-r} {y+h} H{x+r} A{r} {r} 0 0 1 {x} {y+h-r} V{y+r} A{r} {r} 0 0 1 {x+r} {y} Z')
        else: raise ValueError(f'Unsupported SVG element {kind}')
        paths = [[(x*scale,y*scale) for x,y in points] for points in paths]
        if attrs.get('stroke', 'none') != 'none':
            strokes.extend((points, number('stroke-width',1)*scale, number('opacity',1)*number('stroke-opacity',1)) for points in paths)
        if kind != 'line' and attrs.get('fill', 'black') != 'none':
            # Nonzero/even-odd scan conversion preserves path holes. Quarter-unit
            # strips are generated once, not parsed or rasterized during frames.
            for row in range(96):
                y=(row+.5)*.25; crossings=[]
                for points in paths:
                    for (x1,y1),(x2,y2) in zip(points, points[1:]+points[:1]):
                        if min(y1,y2) <= y < max(y1,y2): crossings.append((x1+(y-y1)*(x2-x1)/(y2-y1),1 if y2>y1 else -1))
                crossings.sort(); winding=0; begin=None
                for x,delta in crossings:
                    before=winding; winding = (winding+1)%2 if attrs.get('fill-rule')=='evenodd' else winding+delta
                    if before==0 and winding!=0: begin=x
                    if before!=0 and winding==0 and x>begin: fills.append((begin,row*.25,x-begin,.25,number('opacity',1)*number('fill-opacity',1)))
    visit(root,{})
    return strokes,fills

def main():
    parser=argparse.ArgumentParser();parser.add_argument('--check',action='store_true');args=parser.parse_args()
    geometry={name:svg_geometry(asset) for name,asset in ICONS.items()}
    out=['//! Generated from assets/icons by tools/generate_icons.py. Do not edit.',
         '//! Source SVGs and licenses: assets/icons/SOURCE.md and LICENSES.',
         'pub const Name = enum { '+', '.join(ICONS)+' };',
         'pub const Stroke = struct { points: []const [2]f32, width: f32, opacity: f32 };',
         'pub fn strokes(name: Name) []const Stroke { return switch (name) {']
    for name,(strokes,_) in geometry.items():
        out.append('.'+name+' => &.{')
        for points,width,opacity in strokes:
            out.append('.{ .width = '+f'{width:.4f}'+', .opacity = '+f'{opacity:.4f}'+', .points = &.{'+', '.join('.{'+f'{x:.4f}, {y:.4f}'+'}' for x,y in points)+'} },')
        out.append('},')
    out.extend(['}; }','pub fn fills(name: Name) []const [5]f32 { return switch (name) {'])
    for name,(_,fills) in geometry.items():
        out.append('.'+name+' => &.{'+', '.join('.{'+', '.join(f'{v:.4f}' for v in rect)+'}' for rect in fills)+'},')
    out.extend(['}; }'])
    formatted=subprocess.run([str(ROOT/'tools/zig'),'fmt','--stdin'],input='\n'.join(out)+'\n',text=True,capture_output=True,check=True).stdout
    destination=ROOT/'packages/zircon_ui/src/controls/icon_paths.zig'
    if args.check:
        if destination.read_text()!=formatted: raise SystemExit('Regenerate icons with python3 tools/generate_icons.py')
    else: destination.write_text(formatted)
if __name__=='__main__': main()
