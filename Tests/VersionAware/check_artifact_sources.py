from pathlib import Path
import json,plistlib
# Pillow is not preinstalled on GitHub runners, use PNG headers instead.
base=Path(__file__).resolve().parents[2]
plist=plistlib.loads((base/'Resources/Info.plist').read_bytes())
assert plist['CFBundleDisplayName']=='启动器'
assert plist['CFBundleShortVersionString']=='1.11.1'
assert plist['CFBundleVersion']=='148'
assert plist['NSAppTransportSecurity']['NSAllowsArbitraryLoads'] is True
ui=(base/'Sources/ShiguangLauncherApp.swift').read_text()
assert 'Text("启动器")' in ui and 'Text("正式版 1.11")' not in ui
assert 'ResourceVersionUpdater' in (base/'Sources/LauncherModel.swift').read_text()
server=(base/'Sources/GameServer.swift').read_text()
assert 'activeOverlayRoot(for: relative)' in server and 'preferVerifiedBaseline' in server
for f in ('ResourceVersionManifest.swift','ResourceVersionUpdater.swift','ResourceHotUpdater.swift','RuntimeServerSettings.swift'):
 assert (base/'Sources'/f).is_file()
 assert f in (base/'ShiguangLauncher.xcodeproj/project.pbxproj').read_text()
for icon in (base/'Resources/Assets.xcassets/AppIcon.appiconset/AppIcon.png',base/'Resources/Assets.xcassets/LauncherArt.imageset/LauncherArt.png'):
 b=icon.read_bytes(); assert b[:8]==b'\x89PNG\r\n\x1a\n';assert int.from_bytes(b[16:20],'big')==1024
assert len(list((base/'ThirdParty/EngineParts').glob('part_*.bin'))) == 19
assert sum(x.stat().st_size for x in (base/'ThirdParty/EngineParts').glob('part_*.bin')) == 9719985
print('PASS: iOS label/icon, build IDs, updater, and offline engine backup')
