#!/usr/bin/env python3
"""Build a native application bundle, optionally with a signed release archive."""

import argparse
import hashlib
import json
import plistlib
import shutil
import subprocess
import tempfile
from pathlib import Path


def arguments():
    parser = argparse.ArgumentParser()
    parser.add_argument("--input", type=Path, default=Path("zig-out"))
    parser.add_argument("--output", type=Path, default=Path("artifacts"))
    parser.add_argument("--executable", type=Path)
    parser.add_argument("--extension-host", type=Path)
    parser.add_argument("--bundle-only", action="store_true")
    return parser.parse_args()


def build_bundle(args, executables):
    args.output.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix="zircon-package-", dir=args.output) as temp:
        app = Path(temp) / "Zircon.app"
        mac = app / "Contents/MacOS"
        resources = app / "Contents/Resources"
        mac.mkdir(parents=True)
        resources.mkdir()
        for name, source in executables.items():
            shutil.copy2(source, mac / name)

        info = {
            "CFBundleDevelopmentRegion": "en",
            "CFBundleExecutable": "zircon",
            "CFBundleIdentifier": "dev.zircon.editor",
            "CFBundleInfoDictionaryVersion": "6.0",
            "CFBundleName": "Zircon",
            "CFBundleDisplayName": "Zircon",
            "CFBundlePackageType": "APPL",
            "CFBundleIconFile": "Zircon.icns",
            "CFBundleShortVersionString": "0.1.0",
            "CFBundleVersion": "1",
            "LSMinimumSystemVersion": "13.0",
            "NSHighResolutionCapable": True,
            "NSSupportsAutomaticGraphicsSwitching": True,
            "NSPrincipalClass": "NSApplication",
        }
        with (app / "Contents/Info.plist").open("wb") as file:
            plistlib.dump(info, file)

        for source, name in [
            ("assets/icons/LICENSES", "icons-LICENSES"),
            ("assets/icons/SOURCE.md", "icons-SOURCE.md"),
            ("docs/zed-extensions.md", "zed-extensions.md"),
            ("docs/agent-mode.md", "agent-mode.md"),
        ]:
            if Path(source).is_file():
                shutil.copy2(source, resources / name)

        iconset = Path(temp) / "Zircon.iconset"
        iconset.mkdir()
        logo = Path("assets/branding/zircon-app-icon.png")
        shutil.copy2("assets/branding/zircon-logo.png", resources / "zircon-logo.png")
        shutil.copy2(logo, resources / logo.name)
        for size in (16, 32, 128, 256, 512):
            for scale in (1, 2):
                suffix = "@2x" if scale == 2 else ""
                target_icon = iconset / f"icon_{size}x{size}{suffix}.png"
                subprocess.run(
                    ["/usr/bin/sips", "-z", str(size * scale), str(size * scale), str(logo), "--out", str(target_icon)],
                    check=True,
                    stdout=subprocess.DEVNULL,
                )
        subprocess.run(
            ["/usr/bin/iconutil", "-c", "icns", str(iconset), "-o", str(resources / "Zircon.icns")],
            check=True,
        )
        source = subprocess.check_output(["git", "rev-parse", "HEAD"], text=True).strip()
        dirty = bool(subprocess.check_output(["git", "status", "--porcelain"], text=True).strip())
        (resources / "build.json").write_text(
            json.dumps({"source": source, "uncommitted_changes": dirty, "architecture": subprocess.check_output(["uname", "-m"], text=True).strip()}, indent=2) + "\n"
        )
        subprocess.run(["/usr/bin/codesign", "--force", "--sign", "-", str(app)], check=True)
        subprocess.run(["/usr/bin/codesign", "--verify", "--deep", "--strict", str(app)], check=True)
        target = args.output / "Zircon.app"
        if target.exists():
            shutil.rmtree(target)
        shutil.move(app, target)
    return target, source, dirty


def main():
    args = arguments()
    executables = {
        "zircon": args.executable or args.input / "bin/zircon",
        "zircon-extension-host": args.extension_host or args.input / "bin/zircon-extension-host",
    }
    for name, path in executables.items():
        if not path.is_file():
            raise SystemExit(f"Missing built executable: {name}")
    target, source, dirty = build_bundle(args, executables)
    print(target.resolve())
    if args.bundle_only:
        return
    archive = args.output / "Zircon-macos-arm64.zip"
    if archive.exists():
        archive.unlink()
    subprocess.run(["/usr/bin/ditto", "-c", "-k", "--sequesterRsrc", "--keepParent", str(target), str(archive)], check=True)
    archive_hash = hashlib.sha256(archive.read_bytes()).hexdigest()
    manifest = {
        "source": source,
        "uncommitted_changes": dirty,
        "executables": {name: hashlib.sha256((target / "Contents/MacOS" / name).read_bytes()).hexdigest() for name in executables},
        "archive_sha256": archive_hash,
    }
    (args.output / "Zircon-build.json").write_text(json.dumps(manifest, indent=2) + "\n")
    (args.output / "Zircon-macos-arm64.sha256").write_text(f"{archive_hash}  {archive.name}\n")
    print(archive.resolve())


if __name__ == "__main__":
    main()
