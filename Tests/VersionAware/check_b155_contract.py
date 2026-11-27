from pathlib import Path
base = Path(__file__).resolve().parents[2]
client = (base / "Sources/TinplateClient.swift").read_text()
ui = (base / "Sources/ShiguangLauncherApp.swift").read_text()
model = (base / "Sources/LauncherModel.swift").read_text()
composer = client.split("struct TinplateTicketComposer: View {", 1)[1]
detail = client.split("struct TinplateTicketDetailView: View {", 1)[1].split("struct TinplateDiagnosticTextView", 1)[0]

assert 'request("resources/recognize")' not in client
assert 'request("resources/recognize", method: "POST"' in client
assert "struct TinplateResourceProbe" not in client
assert "static func collect(root: URL, entries: [String], inventory: [String])" in client
assert "actionScriptVersion" in client
assert "struct ResourceImportCenterView: View" in ui
assert "struct GameLaunchCenterView: View" in ui
assert "showingImportCenter = true" in ui
assert "showingLaunchCenter = true" in ui
assert 'PhotosPicker(selection: $photoItems' in composer
assert "添加相册图片" in composer
assert ".fileImporter" not in composer and "添加文件" not in composer
assert "authorizeDiagnostics = false" in composer
assert "try model.makeDiagnosticFile()" in composer
assert "确认并提交" in composer and 'add(diagnostic, field: "diagnostic")' in client
assert "reply.attachments" in detail and "attachmentButton" in detail
assert "GameLibrary" in model and "TinplateGameStorage.support" in model
game_view = ui.split("struct GameView: View {", 1)[1]
assert "GameWebView(url: url" in game_view
print("PASS: B155 POST-only recognition, local feature fingerprint, per-game import, image-only tickets, explicit full diagnostics and redesigned import/launch screens")
