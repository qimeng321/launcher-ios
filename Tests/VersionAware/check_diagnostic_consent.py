from pathlib import Path
base = Path(__file__).resolve().parents[2]
client = (base/"Sources/TinplateClient.swift").read_text()
model = (base/"Sources/LauncherModel.swift").read_text()
runtime = (base/"Sources/GameServer.swift").read_text()
increment = (base/"Sources/GameIncrementalUpdater.swift").read_text()
composer = client.split("struct TinplateTicketComposer: View {",1)[1]
assert "@State private var authorizeDiagnostics = false" in composer
assert "try model.makeDiagnosticFile()" in composer
assert "submit(diagnostic: nil)" in composer
assert "submit(diagnostic: approved)" in composer
assert "authorizeDiagnostics = false" in composer and "diagnosticPreview = nil" in composer
assert 'add(diagnostic, field: "diagnostic")' in client
assert "diagnosticConsent" in client and "fullLogSnapshot()" in model
assert "finalDescription" not in client and "makeDiagnosticPreview" not in client
assert 'request("resources/recognize")' in client and 'request("resources/recognize", method: "POST"' in client
assert 'winner.gameId == game.id' in client and 'activateGame(id: game.id)' in client
assert 'TinplateGameStorage.root' in model and 'GameLibrary' in model
assert 'TinplateGameStorage.support.appendingPathComponent("GameIncremental"' in increment
assert 'TinplateGameStorage.support.appendingPathComponent("MobilePatch"' in model
assert 'try await recognize(staging, scannedEntries)' in model
assert 'skipCRC32: false' in model and 'entry.type == .symlink' in model
validate = model.split("static func validateInstalledPackage",1)[1].split("static func coreRevision",1)[0]
assert 'assets/index.js' not in validate and 'doorConfig.xml' not in validate
assert 'func ticketDetail' in client and 'func replyTicket' in client
assert 'PhotosPicker' in client and '.fileImporter' in composer
assert 'entryPath: String' in runtime and 'page(swfURL: "/" + encoded' in runtime
print("PASS: B154 source checks for scoped imports, backend rules, ticket details, consent and full-file multipart")
