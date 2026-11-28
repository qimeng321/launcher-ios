from pathlib import Path
import plistlib

base = Path(__file__).resolve().parents[2]
plist = plistlib.loads((base / "Resources/Info.plist").read_bytes())
assert plist["CFBundleDisplayName"] == "启动器"
assert plist["CFBundleShortVersionString"] == "1.0"
assert plist["CFBundleVersion"] == "157"
assert plist["NSAppTransportSecurity"]["NSAllowsArbitraryLoads"] is True

ui = (base / "Sources/ShiguangLauncherApp.swift").read_text()
model = (base / "Sources/LauncherModel.swift").read_text()
server = (base / "Sources/GameServer.swift").read_text()
runtime = (base / "Sources/RuntimeServerSettings.swift").read_text()
client = (base / "Sources/TinplateClient.swift").read_text()
project = (base / "ShiguangLauncher.xcodeproj/project.pbxproj").read_text()

assert 'Text("启动器")' in ui
assert "TinplateHubView()" in ui
assert ".environmentObject(tinplate)" in ui
assert "TinplateClientModel" in ui
assert "ResourceVersionUpdater" not in model
assert "resourceUpdateBusy" not in model
assert "ResourceHotUpdater" not in server
assert "hotUpdater" not in server
assert "resourceBaseURL" not in runtime
assert "testResourceConnection" not in runtime
assert "configuredResourceServer" not in ui
assert "资源服务器（底包热更新）" not in ui
assert "ResourceHotUpdater.clearAllCachedResources" not in ui
assert "save(loginAddress: String, forGameSlug slug: String)" in runtime
assert "savedCustomAddress(forGameSlug" in runtime
assert "account/register" in client and "account/login" in client
assert "Authorization" in client and "TinplateTokenVault" in client
assert "games/" in client and "/connection" in client
assert "http://1.13.195.4" in client and "Bearer" in client
assert "static let defaultServerAddress = \"http://1.13.195.4\"" in client
assert "TextField(\"请输入 HTTPS 服务端地址\"" not in client
assert "TextField(\"https://你的服务端域名\"" not in client
assert "saveServerAddress()" in client
for removed in ("ResourceHotUpdater.swift", "ResourceVersionUpdater.swift", "ResourceVersionManifest.swift"):
    assert not (base / "Sources" / removed).exists(), f"{removed} should be removed"
    assert removed not in project, f"{removed} still referenced by Xcode project"
assert "TinplateClient.swift" in project
assert "IPHONEOS_DEPLOYMENT_TARGET = 16.0" in project
assert project.count("PRODUCT_BUNDLE_IDENTIFIER = cn.qimeng321.independentlauncher;") == 2
assert "cn.shiguanghao.launcher.m22908" not in project
for icon in (
    base / "Resources/Assets.xcassets/AppIcon.appiconset/AppIcon.png",
    base / "Resources/Assets.xcassets/LauncherArt.imageset/LauncherArt.png",
):
    data = icon.read_bytes()
    assert data[:8] == b"\x89PNG\r\n\x1a\n"
    assert int.from_bytes(data[16:20], "big") == 1024
parts = list((base / "ThirdParty/EngineParts").glob("part_*.bin"))
assert len(parts) == 19
assert sum(item.stat().st_size for item in parts) == 9719985
assert "RuntimeServerSettings.isLoginConfigured" in model
print("PASS: B150 identity/iOS 16, B156 optional resource fallback and Tinplate API wiring")
