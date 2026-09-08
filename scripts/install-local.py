#!/usr/bin/env python3
"""Install this app and its exact-extension Native Messaging registration locally."""
import datetime
import hashlib
import base64
import json
import pathlib
import shutil

repo = pathlib.Path(__file__).resolve().parent.parent
source = repo / "dist/Native Browser Lens.app"
if not source.is_dir():
    raise SystemExit("Run bash scripts/build-app.sh first.")
extension = json.loads((repo / "extension/dist/manifest.json").read_text())
if not extension.get("key"):
    raise SystemExit("Extension must have its stable public manifest key before installation.")
digest = hashlib.sha256(base64.b64decode(extension["key"])).hexdigest()[:32]
extension_id = "".join(chr(ord("a") + int(n, 16)) for n in digest)
installed = pathlib.Path.home() / "Applications/Native Browser Lens.app"
installed.parent.mkdir(parents=True, exist_ok=True)
if installed.exists():
    stamp = datetime.datetime.now().strftime("%Y%m%d-%H%M%S")
    backup = installed.with_name("Native Browser Lens.backup-" + stamp + ".app")
    installed.rename(backup)
shutil.copytree(source, installed)
hosts = pathlib.Path.home() / "Library/Application Support/Google/Chrome/NativeMessagingHosts"
hosts.mkdir(parents=True, exist_ok=True)
manifest_path = hosts / "studio.sirv.native_browser_lens.json"
manifest = {"name": "studio.sirv.native_browser_lens", "description": "Private local evidence bridge for Native Browser Lens", "path": str(installed / "Contents/MacOS/lens-host"), "type": "stdio", "allowed_origins": ["chrome-extension://" + extension_id + "/"]}
if manifest_path.exists() and json.loads(manifest_path.read_text()) != manifest:
    backup = manifest_path.with_suffix(".json.backup-" + datetime.datetime.now().strftime("%Y%m%d-%H%M%S"))
    shutil.copy2(manifest_path, backup)
temporary = manifest_path.with_suffix(".json.tmp")
temporary.write_text(json.dumps(manifest, indent=2) + "\n")
temporary.chmod(0o600)
temporary.replace(manifest_path)
print("Installed:", installed)
print("Chrome extension ID:", extension_id)
print("Load unpacked extension:", repo / "extension/dist")
print("Open the app, add project origins, and grant those origins in extension Options.")
