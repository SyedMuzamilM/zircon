#!/usr/bin/env python3
"""Package the already-built native editor and extension host for local testing."""
import argparse,hashlib,json,plistlib,shutil,subprocess,tempfile
from pathlib import Path
p=argparse.ArgumentParser();p.add_argument('--input',type=Path,default=Path('zig-out'));p.add_argument('--output',type=Path,default=Path('artifacts'));args=p.parse_args()
args.output.mkdir(parents=True,exist_ok=True)
for name in ('zircon','zircon-extension-host'):
    if not (args.input/'bin'/name).is_file():raise SystemExit(f'Missing built executable: {name}')
with tempfile.TemporaryDirectory(prefix='zircon-package-',dir=args.output) as temp:
    app=Path(temp)/'Zircon.app';mac=app/'Contents/MacOS';resources=app/'Contents/Resources';mac.mkdir(parents=True);resources.mkdir()
    for name in ('zircon','zircon-extension-host'):shutil.copy2(args.input/'bin'/name,mac/name)
    info={'CFBundleDevelopmentRegion':'en','CFBundleExecutable':'zircon','CFBundleIdentifier':'dev.zircon.editor','CFBundleInfoDictionaryVersion':'6.0','CFBundleName':'Zircon','CFBundleDisplayName':'Zircon','CFBundlePackageType':'APPL','CFBundleShortVersionString':'0.1.0','CFBundleVersion':'1','LSMinimumSystemVersion':'13.0','NSHighResolutionCapable':True,'NSSupportsAutomaticGraphicsSwitching':True,'NSPrincipalClass':'NSApplication'}
    with (app/'Contents/Info.plist').open('wb') as f:plistlib.dump(info,f)
    for source,name in [('assets/icons/LICENSES','icons-LICENSES'),('assets/icons/SOURCE.md','icons-SOURCE.md'),('docs/zed-extensions.md','zed-extensions.md'),('docs/agent-mode.md','agent-mode.md')]:
        if Path(source).is_file():shutil.copy2(source,resources/name)
    source=subprocess.check_output(['git','rev-parse','HEAD'],text=True).strip()
    dirty=bool(subprocess.check_output(['git','status','--porcelain'],text=True).strip())
    (resources/'build.json').write_text(json.dumps({'source':source,'uncommitted_changes':dirty,'architecture':subprocess.check_output(['uname','-m'],text=True).strip(),'executables':{name:hashlib.sha256((mac/name).read_bytes()).hexdigest() for name in ('zircon','zircon-extension-host')}},indent=2)+'\n')
    subprocess.run(['/usr/bin/codesign','--force','--sign','-',str(app)],check=True)
    subprocess.run(['/usr/bin/codesign','--verify','--deep','--strict',str(app)],check=True)
    target=args.output/'Zircon.app'
    if target.exists():shutil.rmtree(target)
    shutil.move(app,target)
archive=args.output/'Zircon-macos-arm64.zip'
if archive.exists():archive.unlink()
subprocess.run(['/usr/bin/ditto','-c','-k','--sequesterRsrc','--keepParent',str(target),str(archive)],check=True)
(args.output/'Zircon-macos-arm64.sha256').write_text(hashlib.sha256(archive.read_bytes()).hexdigest()+'  '+archive.name+'\n')
print(target.resolve());print(archive.resolve())
