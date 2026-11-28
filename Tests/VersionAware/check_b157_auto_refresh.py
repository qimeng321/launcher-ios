from pathlib import Path
root=Path(__file__).resolve().parents[2]
m=(root/"Sources/LauncherModel.swift").read_text()
u=(root/"Sources/ShiguangLauncherApp.swift").read_text().split("struct GameLaunchCenterView: View {",1)[1].split("struct GameView: View {",1)[0]
assert "func refreshAdapterBeforeLaunch" in m
assert "client.recognizeResource(root: root, entries: [previous.entry], game: game)" in m
assert "refreshed.gameID == game.id" in m and "client.isAuthenticated" in m
assert "JSONEncoder().encode(refreshed).write" in m and "options: .atomic" in m
assert "try await launcher.refreshAdapterBeforeLaunch" in u
assert u.index("try await launcher.refreshAdapterBeforeLaunch") < u.index("onLaunch()")
assert "refreshTask?.cancel()" in u
print("PASS B157 launch-time adapter refresh, atomic receipt replacement and error path wiring")
