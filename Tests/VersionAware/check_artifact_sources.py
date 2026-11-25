from pathlib import Path
import json,plistlib
# Pillow is not preinstalled on GitHub runners, use PNG headers instead.
base=Path(__file__).resolve().parents[2]
plist=plistlib.loads((base/'Resources/Info.plist').read_bytes())
assert plist['CFBundleDisplayName']=='启动器'
assert plist['CFBundleShortVersionString']=='1.0'
assert plist['CFBundleVersion']=='152'
assert plist['NSAppTransportSecurity']['NSAllowsArbitraryLoads'] is True
ui=(base/'Sources/ShiguangLauncherApp.swift').read_text()
assert 'Text("启动器")' in ui
for unwanted in ('轻装启程 · 重返星际', '对应游戏登录服务器，例如', '参考 Windows 2.3.0 安装程序'):
 assert unwanted not in ui, f'Old UI copy still present: {unwanted}'
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
runtime=(base/'Sources/RuntimeServerSettings.swift').read_text()
assert '202.189.' not in runtime
assert 'isLoginConfigured' in runtime and 'testResourceConnection' in runtime
assert '测试连接' in ui and 'configuredGameServer = ""' in ui
assert 'RuntimeServerSettings.isLoginConfigured' in (base/'Sources/LauncherModel.swift').read_text()
project=(base/'ShiguangLauncher.xcodeproj/project.pbxproj').read_text()
assert project.count('PRODUCT_BUNDLE_IDENTIFIER = cn.qimeng321.independentlauncher;') == 2
assert 'cn.shiguanghao.launcher.m22908' not in project
print('PASS: independent B152 ID, empty server defaults, connectivity probe and engine backup')
