#!/usr/bin/env python3
"""Bake the pinned Lucide SVG subset into renderer-neutral polylines.

Run with --fetch to retrieve upstream sources. Normal regeneration is offline.
Curves flatten to <=0.08 SVG units before scaling to the native icon size.
"""
import argparse, concurrent.futures, math, pathlib, re, urllib.request, xml.etree.ElementTree as ET
ROOT = pathlib.Path(__file__).resolve().parents[1]
ASSETS = ROOT / 'packages/zircon_ui/src/controls/lucide'
REV = 'b826f0c527e1498f5e46f41ca0277ccab144bf31'
ICONS = dict(folder='folder', folder_open='folder-open', file='file', code='file-code-corner', zig='file-code-corner', markdown='file-text', image='file-image', chevron_down='chevron-down', chevron_right='chevron-right', chevron_left='chevron-left', plus='plus', close='x', search='search', split='columns-2', sidebar='panel-left', branch='git-branch', history='rotate-ccw', settings='settings', commands='square-terminal', more='ellipsis', check='check', extension='blocks', refresh='refresh-cw', arrow_up='arrow-up', arrow_down='arrow-down', square='square', square_checked='square-check', square_mixed='square-minus', commit='git-commit-horizontal', user='user-round', diff='diff', minus='minus')
def fetch(name):
    path = ASSETS / (name + '.svg')
    path.write_bytes(urllib.request.urlopen(f'https://raw.githubusercontent.com/lucide-icons/lucide/{REV}/icons/{name}.svg', timeout=30).read())
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

def svg_paths(name):
    result=[]
    for node in ET.parse(ASSETS/(name+'.svg')).getroot():
        kind=node.tag.split('}')[-1];a=node.attrib; number=lambda key,default=0:float(a.get(key,default))
        if kind=='path': result.extend(path_data(a['d']))
        elif kind=='line': result.append([(number('x1'),number('y1')),(number('x2'),number('y2'))])
        elif kind in ('polyline','polygon'):
            values=list(map(float,re.findall(r'[-+]?\d*\.?\d+',a['points'])));points=list(zip(values[::2],values[1::2]));result.append(points+points[:1] if kind=='polygon' else points)
        elif kind in ('circle','ellipse'):
            cx,cy=number('cx'),number('cy');rx,ry=(number('r'),number('r')) if kind=='circle' else (number('rx'),number('ry'))
            result.append([(cx+rx*math.cos(n*math.tau/32),cy+ry*math.sin(n*math.tau/32)) for n in range(33)])
        elif kind=='rect':
            x,y,w,h=number('x'),number('y'),number('width'),number('height');r=min(number('rx'),w/2,h/2)
            if not r: result.append([(x,y),(x+w,y),(x+w,y+h),(x,y+h),(x,y)])
            else: result.extend(path_data(f'M{x+r} {y} H{x+w-r} A{r} {r} 0 0 1 {x+w} {y+r} V{y+h-r} A{r} {r} 0 0 1 {x+w-r} {y+h} H{x+r} A{r} {r} 0 0 1 {x} {y+h-r} V{y+r} A{r} {r} 0 0 1 {x+r} {y} Z'))
        else: raise ValueError(f'Unsupported SVG element {kind}')
    return result

def main():
    parser=argparse.ArgumentParser();parser.add_argument('--fetch',action='store_true');args=parser.parse_args();ASSETS.mkdir(parents=True,exist_ok=True)
    if args.fetch:
        with concurrent.futures.ThreadPoolExecutor(max_workers=6) as pool: list(pool.map(fetch,sorted(set(ICONS.values()))))
        (ASSETS/'LICENSE').write_bytes(urllib.request.urlopen(f'https://raw.githubusercontent.com/lucide-icons/lucide/{REV}/LICENSE',timeout=30).read())
    out=['//! Generated by tools/generate_icons.py from the pinned Lucide SVG subset.','//! Do not edit coordinates by hand. See lucide/LICENSE and SOURCE.md.', 'pub const Name = enum { '+', '.join(ICONS)+' };','pub fn paths(name: Name) []const []const [2]f32 {','    return switch (name) {']
    for name,asset in ICONS.items():
        out.append('        .'+name+' => &.{')
        for points in svg_paths(asset):
            out.append('            &.{'+', '.join('.{'+f'{x:.4f}, {y:.4f}'+'}' for x,y in points)+'},')
        out.append('        },')
    out.extend(['    };','}'])
    (ROOT/'packages/zircon_ui/src/controls/icon_paths.zig').write_text('\n'.join(out)+'\n')
if __name__=='__main__': main()
