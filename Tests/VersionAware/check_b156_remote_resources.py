from pathlib import Path
import plistlib
base=Path(__file__).resolve().parents[2]
tin=(base/"Sources/TinplateClient.swift").read_text()
model=(base/"Sources/LauncherModel.swift").read_text()
app=(base/"Sources/ShiguangLauncherApp.swift").read_text()
gs=(base/"Sources/GameServer.swift").read_text()
rt=(base/"Sources/RuntimeServerSettings.swift").read_text()
wf=(base/".github/workflows/ruffle-b142-gpu-memory-fix.yml").read_text()
proj=(base/"ShiguangLauncher.xcodeproj/project.pbxproj").read_text()
plist=plistlib.loads((base/"Resources/Info.plist").read_bytes())
assert 'connectionParameters["resourceBaseURL"]' in tin and 'connectionParameters["builtinDoorConfig"]' in tin
assert "resourceBaseURL: normalizedResourceBaseURL" in tin
assert "let resourceBaseURL: String?" in model and "let builtinDoorConfig: Bool?" in model
assert "resourceBaseURL: receipt?.resourceBaseURL" in app
assert "remoteResourceBaseURL" in gs and "URLSessionConfiguration.ephemeral" in gs
assert "80 * 1024 * 1024" in gs and "config/serverofficial.xml" in gs
assert "isAllowedRemoteResourcePath" in rt and "rewriteServerEndpointXML" in rt
assert "103.236.79.37" not in tin+gs+rt
assert plist["CFBundleVersion"]=="157" and "CURRENT_PROJECT_VERSION = 157;" in proj
assert 'static let launcherVersion = "1.0.157"' in tin
assert "tinplate-b156-newera-runtime" in wf
print("PASS: B156 optional resource origin, safe path validation, server endpoint rewrite and build metadata")
